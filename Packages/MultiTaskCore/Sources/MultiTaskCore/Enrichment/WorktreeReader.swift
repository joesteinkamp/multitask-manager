import Foundation

/// Runs `git` as a child process.
///
/// Always an absolute executable path and an argument *array* — never a shell
/// string, never an interpolated path. Repository paths come from the filesystem
/// and from user settings, and a repo directory named with a quote or a semicolon
/// would be a command injection through a shell string.
public struct GitRunner: Sendable {
    public var executable: String
    /// Hard ceiling on any one invocation so a wedged git can't stall a refresh.
    public var timeout: TimeInterval

    public init(executable: String? = nil, timeout: TimeInterval = 10) {
        self.executable = executable ?? Self.resolveGit()
        self.timeout = timeout
    }

    /// Finds git on `PATH` first, then in the usual places.
    ///
    /// A hardcoded candidate list can't work on Windows, and even on macOS it
    /// misses a Homebrew-on-Intel or Nix install. `PATH` is what the user's shell
    /// would use, which is the answer they expect.
    static func resolveGit() -> String {
        let executable = FileSupport.isWindows ? "git.exe" : "git"
        let separator: Character = FileSupport.isWindows ? ";" : ":"

        // Same case-sensitivity trap as ShellEnvironment: Windows spells it
        // `Path`, so a literal "PATH" lookup would never find git there.
        if let path = ShellEnvironment.searchPath(in: ProcessInfo.processInfo.environment) {
            for directory in path.split(separator: separator) where !directory.isEmpty {
                let candidate = String(directory) + (FileSupport.isWindows ? "\\" : "/") + executable
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        let fallbacks = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git", "/bin/git",
                         "C:\\Program Files\\Git\\cmd\\git.exe"]
        return fallbacks.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"
    }

    public var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executable)
    }

    /// Runs git in `directory` and returns stdout, or `nil` on any failure. Errors
    /// are deliberately swallowed: a repo that has gone missing must degrade this
    /// one row, not break the refresh.
    public func run(_ arguments: [String], in directory: String) -> String? {
        guard isAvailable else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        // Keep git non-interactive: a credential or editor prompt would hang the
        // process forever behind a UI the user can't see.
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_PAGER"] = "cat"
        process.environment = env

        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()

        do { try process.run() } catch { return nil }

        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// One checkout of a repository — the main tree or an `ai/<agent>` worktree.
public struct WorktreeInfo: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    /// Short branch name, or `nil` when the worktree is detached.
    public var branch: String?
    public var isMain: Bool
    /// Commits this branch has that the integration branch doesn't.
    public var ahead: Int
    /// Commits the integration branch has that this branch doesn't.
    public var behind: Int

    public var id: String { path }

    public init(path: String, branch: String?, isMain: Bool, ahead: Int = 0, behind: Int = 0) {
        self.path = path
        self.branch = branch
        self.isMain = isMain
        self.ahead = ahead
        self.behind = behind
    }

    /// An agent worktree by the convention `../<repo>-<agent>` on `ai/<agent>`.
    public var agentName: String? {
        guard let branch, branch.hasPrefix("ai/") else { return nil }
        return String(branch.dropFirst(3))
    }
}

/// Parallel-agent state for one repository.
public struct RepositoryState: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    public var name: String
    /// Branch the agent branches fold into.
    public var integrationBranch: String?
    public var worktrees: [WorktreeInfo]
    /// `.converge-conflict-*` marker filenames found in the integration tree.
    /// `converge.sh` writes one when a fold fails, so a present marker means the
    /// convergence loop has stopped making progress and is waiting on a human.
    public var conflictMarkers: [String]
    public var scannedAt: Date

    public var id: String { path }

    public init(path: String, name: String, integrationBranch: String? = nil,
                worktrees: [WorktreeInfo] = [], conflictMarkers: [String] = [],
                scannedAt: Date) {
        self.path = path
        self.name = name
        self.integrationBranch = integrationBranch
        self.worktrees = worktrees
        self.conflictMarkers = conflictMarkers
        self.scannedAt = scannedAt
    }

    /// A stalled converge needs a human regardless of whether any session is live,
    /// so it is an attention condition in its own right.
    public var needsAttention: Bool { !conflictMarkers.isEmpty }

    public var agentWorktrees: [WorktreeInfo] { worktrees.filter { $0.agentName != nil } }
}

/// Discovers parallel-agent worktrees and stalled converges across tracked repos.
///
/// Shelling out to `git` several times per repository is far too expensive for the
/// 5-second refresh, so this runs on its own slower cadence and additionally skips
/// any repository whose `.git` directory hasn't been touched since the last scan —
/// which is almost all of them, almost always.
public final class WorktreeReader: @unchecked Sendable {
    private struct CacheEntry {
        var gitMtime: Date
        var state: RepositoryState
    }

    private let git: GitRunner
    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]

    public init(git: GitRunner = GitRunner()) {
        self.git = git
    }

    public func read(repositories: [String], now: Date = Date()) -> [RepositoryState] {
        repositories.compactMap { read(repository: $0, now: now) }
    }

    public func read(repository path: String, now: Date = Date()) -> RepositoryState? {
        let repo = FileSupport.expandingTilde(path)
        let gitPath = repo + "/.git"
        guard FileSupport.fileManager.fileExists(atPath: gitPath) else { return nil }

        let gitMtime = FileSupport.modificationDate(ofPath: gitPath)
        lock.lock()
        if let cached = cache[repo], cached.gitMtime == gitMtime {
            lock.unlock()
            return cached.state
        }
        lock.unlock()

        guard let state = scan(repository: repo, now: now) else { return nil }

        lock.lock()
        cache[repo] = CacheEntry(gitMtime: gitMtime, state: state)
        lock.unlock()
        return state
    }

    private func scan(repository repo: String, now: Date) -> RepositoryState? {
        guard let porcelain = git.run(["worktree", "list", "--porcelain"], in: repo) else { return nil }
        var worktrees = Self.parseWorktreeList(porcelain)
        guard !worktrees.isEmpty else { return nil }

        let mainPath = worktrees.first(where: { $0.isMain })?.path ?? repo
        let integration = resolveIntegrationBranch(in: repo, mainWorktreePath: mainPath)

        if let integration {
            for i in worktrees.indices {
                guard let branch = worktrees[i].branch, branch != integration else { continue }
                let counts = git.run(
                    ["rev-list", "--left-right", "--count", "\(integration)...\(branch)"],
                    in: repo
                )
                if let (behind, ahead) = Self.parseLeftRightCount(counts) {
                    worktrees[i].behind = behind
                    worktrees[i].ahead = ahead
                }
            }
        }

        return RepositoryState(
            path: repo,
            name: FileSupport.lastComponent(of: repo),
            integrationBranch: integration,
            worktrees: worktrees,
            conflictMarkers: Self.conflictMarkers(in: mainPath),
            scannedAt: now
        )
    }

    /// A local branch literally named `integration` when one exists, otherwise the
    /// main worktree's current branch.
    private func resolveIntegrationBranch(in repo: String, mainWorktreePath: String) -> String? {
        if let refs = git.run(["for-each-ref", "--format=%(refname:short)", "refs/heads/integration"], in: repo),
           refs.split(separator: "\n").contains("integration") {
            return "integration"
        }
        guard let head = git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: mainWorktreePath) else { return nil }
        let branch = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty || branch == "HEAD" ? nil : branch
    }

    /// Parses `git worktree list --porcelain`. Records are newline-separated blocks;
    /// the first block is always the main worktree.
    static func parseWorktreeList(_ output: String) -> [WorktreeInfo] {
        var result: [WorktreeInfo] = []
        var path: String?
        var branch: String?

        func flush() {
            guard let path else { return }
            result.append(WorktreeInfo(path: path, branch: branch, isMain: result.isEmpty))
        }

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("worktree ") {
                flush()
                path = String(line.dropFirst("worktree ".count))
                branch = nil
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            } else if line == "detached" {
                branch = nil
            }
        }
        flush()
        return result
    }

    /// Parses `git rev-list --left-right --count A...B` → `(left, right)`, which
    /// with `A` = integration means `(behind, ahead)`.
    static func parseLeftRightCount(_ output: String?) -> (Int, Int)? {
        guard let output else { return nil }
        let parts = output.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" })
        guard parts.count >= 2, let left = Int(parts[0]), let right = Int(parts[1]) else { return nil }
        return (left, right)
    }

    /// Conflict markers `converge.sh` leaves in the integration tree root when a
    /// fold fails. Surfaced, never resolved — auto-resolving a merge conflict is
    /// exactly the kind of thing the harness rules forbid.
    static func conflictMarkers(in directory: String) -> [String] {
        guard let entries = try? FileSupport.fileManager.contentsOfDirectory(atPath: directory) else { return [] }
        return entries.filter { $0.hasPrefix(".converge-conflict-") }.sorted()
    }
}
