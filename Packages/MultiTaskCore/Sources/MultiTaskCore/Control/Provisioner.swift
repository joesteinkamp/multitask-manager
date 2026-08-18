import Foundation

public enum ProvisionError: Error, Equatable, CustomStringConvertible {
    case notARepository(String)
    case dirtyTree(String)
    case detachedHead(String)
    case branchExists(String)
    case worktreeExists(String)
    case gitUnavailable
    case gitFailed(String)

    public var description: String {
        switch self {
        case .notARepository(let path): return "\(path) is not a git repository"
        case .dirtyTree(let path): return "\(path) has uncommitted changes — commit or stash first"
        case .detachedHead(let path): return "\(path) is on a detached HEAD"
        case .branchExists(let name): return "Branch \(name) already exists"
        case .worktreeExists(let path): return "\(path) already exists"
        case .gitUnavailable: return "git isn't available"
        case .gitFailed(let detail): return "git failed: \(detail)"
        }
    }
}

/// What a provisioning run produced.
public struct Isolation: Codable, Hashable, Sendable {
    public var worktreePath: String
    public var branch: String
    public var contextDirectory: String

    public init(worktreePath: String, branch: String, contextDirectory: String) {
        self.worktreePath = worktreePath
        self.branch = branch
        self.contextDirectory = contextDirectory
    }
}

/// Creates the isolation an editing delegate needs: its own worktree, and a
/// context directory to write its report into.
///
/// Follows the harness's parallel-agent conventions rather than inventing any —
/// `../<repo>-<agent>` on `ai/<agent>`, and `~/.ai-context/<repo>-<slug>/` with
/// `TASK.md` and an empty `STATE.md`. A delegate that has read the orchestration
/// playbook finds exactly what it expects.
public struct Provisioner: Sendable {
    /// Marks a context directory this app created.
    ///
    /// **One writer per file.** The app writes `TASK.md` and `STATE.md` only in
    /// directories carrying this marker, so it can never fight an orchestrating
    /// session for the same file. Without it, an app refresh and a live agent
    /// would both believe they own the rolling summary.
    public static let ownershipMarker = ".mtm-owned"

    private let git: GitRunner
    private let contextRoot: URL

    public init(git: GitRunner = GitRunner(), contextRoot: URL? = nil) {
        self.git = git
        self.contextRoot = contextRoot ?? FileSupport.homeDirectory
            .appendingPathComponent(".ai-context", isDirectory: true)
    }

    /// Checks everything that could go wrong *before* changing anything.
    ///
    /// Reporting and stopping beats forcing: every one of these is a state the
    /// user can fix in seconds and none of them is safe to paper over.
    public func preflight(repository: String, agent: String) throws {
        guard git.isAvailable else { throw ProvisionError.gitUnavailable }
        let repo = FileSupport.expandingTilde(repository)

        guard FileSupport.fileManager.fileExists(atPath: repo + "/.git") else {
            throw ProvisionError.notARepository(repo)
        }
        guard let head = git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo) else {
            throw ProvisionError.gitFailed("rev-parse")
        }
        guard head.trimmingCharacters(in: .whitespacesAndNewlines) != "HEAD" else {
            throw ProvisionError.detachedHead(repo)
        }
        if let status = git.run(["status", "--porcelain"], in: repo),
           !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProvisionError.dirtyTree(repo)
        }
        let branch = Self.branchName(for: agent)
        if let refs = git.run(["for-each-ref", "--format=%(refname:short)", "refs/heads/\(branch)"], in: repo),
           refs.split(separator: "\n").contains(Substring(branch)) {
            throw ProvisionError.branchExists(branch)
        }
        let worktree = Self.worktreePath(repository: repo, agent: agent)
        if FileSupport.fileManager.fileExists(atPath: worktree) {
            throw ProvisionError.worktreeExists(worktree)
        }
    }

    public static func branchName(for agent: String) -> String { "ai/\(agent)" }

    /// `../<repo>-<agent>`, a sibling of the repository.
    public static func worktreePath(repository: String, agent: String) -> String {
        let repo = FileSupport.normalise(repository)
        let name = FileSupport.lastComponent(of: repo)
        let parent = repo.hasSuffix("/\(name)") ? String(repo.dropLast(name.count + 1)) : repo
        return "\(parent)/\(name)-\(agent)"
    }

    /// Creates the worktree and seeds the context directory.
    ///
    /// - Parameter brief: written to `TASK.md` — the delegate's whole instruction.
    public func provision(repository: String, agent: String, slug: String,
                          brief: String) throws -> Isolation {
        try preflight(repository: repository, agent: agent)

        let repo = FileSupport.expandingTilde(repository)
        let branch = Self.branchName(for: agent)
        let worktree = Self.worktreePath(repository: repo, agent: agent)

        guard git.run(["worktree", "add", "-b", branch, worktree], in: repo) != nil else {
            throw ProvisionError.gitFailed("worktree add \(branch)")
        }

        let name = FileSupport.lastComponent(of: FileSupport.normalise(repo))
        let context = contextRoot.appendingPathComponent("\(name)-\(slug)", isDirectory: true)
        try? FileSupport.fileManager.createDirectory(
            at: context.appendingPathComponent("agents", isDirectory: true),
            withIntermediateDirectories: true)
        try? FileSupport.fileManager.createDirectory(
            at: context.appendingPathComponent("artifacts", isDirectory: true),
            withIntermediateDirectories: true)

        // The marker goes down first: if anything below fails, the directory is
        // still identifiable as ours rather than becoming an orphan nobody owns.
        try? FileSupport.write("created by mtm\n", to: context.appendingPathComponent(Self.ownershipMarker))
        try? FileSupport.write(brief, to: context.appendingPathComponent("TASK.md"))
        try? FileSupport.write("", to: context.appendingPathComponent("STATE.md"))

        return Isolation(worktreePath: worktree, branch: branch, contextDirectory: context.path)
    }

    /// Whether this app created a context directory, and may therefore write to it.
    public func owns(contextDirectory: String) -> Bool {
        FileSupport.fileManager.fileExists(
            atPath: contextDirectory + "/" + Self.ownershipMarker)
    }

    /// The brief a delegate is handed. Follows the playbook's opening and closing
    /// instructions verbatim, because a delegate that has read the playbook is
    /// looking for exactly those sentences.
    public static func brief(task: TaskRecord, agent: String, contextDirectory: String) -> String {
        var lines = ["# \(task.title)", ""]
        lines.append("Read `TASK.md` and `STATE.md` in `\(contextDirectory)` first.")
        lines.append("")
        if !task.body.isEmpty { lines.append(contentsOf: [task.body, ""]) }
        if let acceptance = task.acceptance {
            lines.append(contentsOf: ["## Done when", "", acceptance, ""])
        }
        lines.append("Write your full results to `agents/\(agent).md` in that directory.")
        return lines.joined(separator: "\n")
    }
}
