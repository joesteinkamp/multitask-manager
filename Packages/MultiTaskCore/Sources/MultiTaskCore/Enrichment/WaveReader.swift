import Foundation

/// What one delegate in a wave is doing.
///
/// The orchestration contract has each delegate write its full output to
/// `agents/<name>.md` when it finishes, so the file itself is the signal: absent
/// means not started, recently modified means still writing, stable means done.
/// No extra instrumentation is needed, which is why this stays read-only.
public enum DelegateState: String, Codable, Sendable {
    case active
    case done

    public var label: String {
        switch self {
        case .active: return "Writing"
        case .done: return "Done"
        }
    }
}

public struct WaveDelegate: Codable, Hashable, Sendable, Identifiable {
    /// Delegate name, from the filename stem — "codex", "agy", "claude", …
    public var name: String
    public var path: String
    public var updatedAt: Date
    public var state: DelegateState
    /// Size in bytes, shown so an empty placeholder file reads differently from a
    /// finished report.
    public var byteCount: UInt64

    public var id: String { path }

    public init(name: String, path: String, updatedAt: Date, state: DelegateState, byteCount: UInt64) {
        self.name = name
        self.path = path
        self.updatedAt = updatedAt
        self.state = state
        self.byteCount = byteCount
    }
}

/// One orchestration wave — a `~/.ai-context/<repo>-<task-slug>/` directory, which
/// the app renders as a single row with its delegates as children rather than as N
/// unrelated sessions.
public struct Wave: Codable, Hashable, Sendable, Identifiable {
    /// Directory name, e.g. "multitask-manager-audit-reader".
    public var id: String
    public var path: String
    /// First paragraph of `TASK.md`.
    public var title: String?
    /// Last meaningful line of `STATE.md` — the rolling progress summary.
    public var progress: String?
    public var delegates: [WaveDelegate]
    /// Files under `artifacts/`, by name.
    public var artifacts: [String]
    /// Newest modification time anywhere in the wave.
    public var updatedAt: Date
    /// Resolved project path, when the wave could be attributed to a known project.
    public var projectPath: String?
    public var projectName: String?
    /// True once nothing in the wave has been touched for `stalenessWindow`. These
    /// dirs are explicitly temporary, so old ones collapse into a disclosure rather
    /// than cluttering the list. The app never deletes them.
    public var isStale: Bool

    public init(id: String, path: String, title: String? = nil, progress: String? = nil,
                delegates: [WaveDelegate] = [], artifacts: [String] = [],
                updatedAt: Date, projectPath: String? = nil, projectName: String? = nil,
                isStale: Bool = false) {
        self.id = id
        self.path = path
        self.title = title
        self.progress = progress
        self.delegates = delegates
        self.artifacts = artifacts
        self.updatedAt = updatedAt
        self.projectPath = projectPath
        self.projectName = projectName
        self.isStale = isStale
    }

    /// How many delegates have finished, for a "3 of 4" summary.
    public var doneCount: Int { delegates.filter { $0.state == .done }.count }
    public var activeCount: Int { delegates.filter { $0.state == .active }.count }
}

/// Reads `~/.ai-context/` into `Wave` values.
///
/// Read-only by design: this is the app *observing* orchestration that a session
/// is driving, not participating in it. Writing into a context dir the app didn't
/// create would break the one-writer-per-file rule the whole contract rests on.
public struct WaveReader: Sendable {
    /// A delegate file touched within this window is treated as still being written.
    public static let activeWindow: TimeInterval = 120
    /// Waves untouched for this long collapse into "past waves".
    public static let stalenessWindow: TimeInterval = 7 * 24 * 60 * 60

    public var root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileSupport.homeDirectory
            .appendingPathComponent(".ai-context", isDirectory: true)
    }

    /// - Parameter knownProjects: absolute project paths the app already tracks,
    ///   used to attribute a wave to a project.
    public func read(knownProjects: [String] = [], now: Date = Date()) -> [Wave] {
        guard FileSupport.isDirectory(root) else { return [] }

        return FileSupport.contents(of: root)
            .filter { FileSupport.isDirectory($0) }
            .compactMap { dir in wave(at: dir, knownProjects: knownProjects, now: now) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func wave(at dir: URL, knownProjects: [String], now: Date) -> Wave? {
        let taskFile = dir.appendingPathComponent("TASK.md")
        let stateFile = dir.appendingPathComponent("STATE.md")
        let agentsDir = dir.appendingPathComponent("agents", isDirectory: true)
        let artifactsDir = dir.appendingPathComponent("artifacts", isDirectory: true)

        // A context dir without any of the contract's files is somebody else's
        // directory that happens to live here — don't claim it.
        guard FileSupport.exists(taskFile) || FileSupport.exists(stateFile)
                || FileSupport.isDirectory(agentsDir) else { return nil }

        let title = FileSupport.readHead(of: taskFile, limit: 64 * 1024)
            .flatMap(ProjectContextReader.extractGoal(from:))
        let progress = FileSupport.readTail(of: stateFile, limit: 16 * 1024)
            .flatMap(Self.lastMeaningfulLine)

        var delegates: [WaveDelegate] = []
        if FileSupport.isDirectory(agentsDir) {
            for file in FileSupport.contents(of: agentsDir) where file.pathExtension == "md" {
                let updated = FileSupport.modificationDate(of: file)
                delegates.append(WaveDelegate(
                    name: file.deletingPathExtension().lastPathComponent,
                    path: file.path,
                    updatedAt: updated,
                    state: now.timeIntervalSince(updated) <= Self.activeWindow ? .active : .done,
                    byteCount: FileSupport.fileSize(ofPath: file.path)
                ))
            }
        }
        delegates.sort { $0.name < $1.name }

        let artifacts = FileSupport.isDirectory(artifactsDir)
            ? FileSupport.contents(of: artifactsDir).map(\.lastPathComponent)
            : []

        let updatedAt = ([FileSupport.modificationDate(of: dir),
                          FileSupport.modificationDate(of: stateFile)]
                         + delegates.map(\.updatedAt)).max() ?? .distantPast

        let taskText = FileSupport.readHead(of: taskFile, limit: 64 * 1024)
        let resolved = Self.resolveProject(waveId: dir.lastPathComponent,
                                           taskText: taskText,
                                           knownProjects: knownProjects)

        return Wave(
            id: dir.lastPathComponent,
            path: dir.path,
            title: title,
            progress: progress,
            delegates: delegates,
            artifacts: artifacts,
            updatedAt: updatedAt,
            projectPath: resolved,
            projectName: resolved.map(FileSupport.lastComponent(of:)),
            isStale: now.timeIntervalSince(updatedAt) > Self.stalenessWindow
        )
    }

    /// Last line of `STATE.md` that carries actual progress, skipping headings and
    /// blank lines. `STATE.md` is a rolling summary, so its tail is the live status.
    static func lastMeaningfulLine(_ text: String) -> String? {
        for raw in text.components(separatedBy: .newlines).reversed() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("---") else { continue }
            let cleaned = ProjectContextReader.cleanMarkdown(line)
            guard !cleaned.isEmpty else { continue }
            return ProjectContextReader.truncate(cleaned, to: 200)
        }
        return nil
    }

    /// Attributes a wave directory to a project.
    ///
    /// The directory is named `<repo>-<task-slug>` and repo names contain dashes,
    /// so the split is genuinely ambiguous — `memory-os-verify` could be repo
    /// `memory` or `memory-os`. Resolved by longest-prefix match against the
    /// projects we already know about, then by any known project path mentioned in
    /// `TASK.md`, and otherwise left unattributed rather than guessed.
    static func resolveProject(waveId: String, taskText: String?, knownProjects: [String]) -> String? {
        let candidates = knownProjects.filter(isAttributable)

        var best: String?
        var bestLength = 0
        for project in candidates {
            let name = FileSupport.lastComponent(of: project)
            guard !name.isEmpty else { continue }
            guard waveId == name || waveId.hasPrefix(name + "-") else { continue }
            if name.count > bestLength {
                best = project
                bestLength = name.count
            }
        }
        if let best { return best }

        // Fall back to a repo path named inside the brief. This matches on whole
        // path tokens rather than on substrings: a plain `contains` check attributes
        // the wave to *any* ancestor directory that happens to be tracked, so a
        // brief mentioning `/home/me/projects/memory-os` would be claimed by
        // `/home/me` the moment a session had run there.
        guard let taskText else { return nil }
        var bestMention: String?
        var bestMentionLength = 0
        for token in pathTokens(in: taskText) {
            for project in candidates where token == project || token.hasPrefix(project + "/") {
                if project.count > bestMentionLength {
                    bestMention = project
                    bestMentionLength = project.count
                }
            }
        }
        return bestMention
    }

    /// Whether a path is specific enough to attribute a wave to.
    ///
    /// The home directory is tracked as a "project" as soon as a session runs
    /// there, but it isn't one, and neither is anything above it.
    static func isAttributable(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        return path != home && path.hasPrefix(home + "/")
    }

    /// Absolute-path-looking tokens in a block of prose, with surrounding markdown
    /// and sentence punctuation trimmed off.
    static func pathTokens(in text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .map { token in
                String(token).trimmingCharacters(in: CharacterSet(charactersIn: "`'\"(),;:*_[]<>"))
            }
            .filter { $0.hasPrefix("/") }
            .map { $0.hasSuffix("/") && $0.count > 1 ? String($0.dropLast()) : $0 }
    }
}
