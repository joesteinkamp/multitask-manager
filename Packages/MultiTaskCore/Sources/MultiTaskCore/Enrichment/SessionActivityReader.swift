import Foundation

/// A file a session created or changed.
public struct TouchedFile: Codable, Hashable, Sendable {
    public var path: String
    /// True when the session created it rather than editing something existing.
    public var wasCreated: Bool

    public init(path: String, wasCreated: Bool) {
        self.path = path
        self.wasCreated = wasCreated
    }

    public var name: String { FileSupport.lastComponent(of: path) }
}

/// What a session actually did, as opposed to when it last breathed.
public struct SessionActivity: Codable, Hashable, Sendable {
    /// Files written or edited inside the project, newest first.
    public var touched: [TouchedFile]
    /// How many times each tool was called — forty reads and no edits is a
    /// session exploring; forty edits is a rewrite.
    public var toolCounts: [String: Int]
    public var messageCount: Int
    public var startedAt: Date?

    public init(touched: [TouchedFile] = [], toolCounts: [String: Int] = [:],
                messageCount: Int = 0, startedAt: Date? = nil) {
        self.touched = touched
        self.toolCounts = toolCounts
        self.messageCount = messageCount
        self.startedAt = startedAt
    }

    public var created: [TouchedFile] { touched.filter(\.wasCreated) }
    public var edited: [TouchedFile] { touched.filter { !$0.wasCreated } }

    public var isEmpty: Bool { touched.isEmpty && toolCounts.isEmpty }

    /// One line for a row: "wrote 4 files, edited 9".
    public var summary: String? {
        var parts: [String] = []
        if !created.isEmpty { parts.append("wrote \(created.count) file\(created.count == 1 ? "" : "s")") }
        if !edited.isEmpty { parts.append("edited \(edited.count)") }
        if parts.isEmpty, let dominant = toolCounts.max(by: { $0.value < $1.value }) {
            parts.append("\(dominant.value)× \(dominant.key)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// Derives what a session did from the transcript it already writes.
///
/// Borrowed from `mission-control`, which got more value from this than from
/// anything else it built — and rightly: it turns "this session is quiet" into
/// "this session wrote four files and edited nine, then went quiet". The
/// difference between those two sentences is the difference between a monitor
/// and something worth opening.
///
/// It needs no hook, no convention and no cooperation from anything. It reads a
/// file Claude Code writes anyway, which makes it the cheapest real signal
/// available and one that cannot silently stop working because an agent forgot
/// a convention.
///
/// **Privacy.** Only file *paths inside the project* are kept. Tool inputs,
/// outputs and prompt text are parsed and dropped, consistent with the rule that
/// harness data is never copied into app state that gets written elsewhere.
public final class SessionActivityReader: @unchecked Sendable {
    /// Window read from the tail of a transcript. Large enough to cover a real
    /// working session, small enough to stay on the refresh path.
    static let tailBytes: UInt64 = 512 * 1024
    /// Cap on files reported, so a codemod touching a thousand files can't turn
    /// one row into a wall.
    static let maxFiles = 40

    private struct CacheEntry {
        var signature: String
        var activity: SessionActivity
    }

    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]

    public init() {}

    /// - Parameter projectPath: files outside this are ignored — an agent
    ///   reading its own config in `~` did not change your project.
    public func activity(forTranscript path: String, projectPath: String?) -> SessionActivity? {
        let url = URL(fileURLWithPath: path)
        let signature = "\(FileSupport.modificationDate(of: url).timeIntervalSince1970)"

        lock.lock()
        if let entry = cache[path], entry.signature == signature {
            lock.unlock()
            return entry.activity.isEmpty ? nil : entry.activity
        }
        lock.unlock()

        guard let text = FileSupport.readTail(of: url, limit: Self.tailBytes) else { return nil }
        let activity = Self.parse(text, projectPath: projectPath)

        lock.lock()
        cache[path] = CacheEntry(signature: signature, activity: activity)
        lock.unlock()

        return activity.isEmpty ? nil : activity
    }

    /// Walks transcript lines for tool calls.
    ///
    /// Tolerates both the Claude Code shape (`message.content[]` blocks of
    /// `type: "tool_use"`) and the Codex shape, which nests the same thing under
    /// `payload`. A format that moves yields fewer files rather than a crash.
    public static func parse(_ text: String, projectPath: String?) -> SessionActivity {
        var activity = SessionActivity()
        var seen: [String: Bool] = [:]      // path → wasCreated
        var order: [String] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            activity.messageCount += 1

            let message = (object["message"] as? [String: Any])
                ?? (object["payload"] as? [String: Any])
                ?? object
            guard let blocks = message["content"] as? [[String: Any]] else { continue }

            for block in blocks {
                guard block["type"] as? String == "tool_use",
                      let name = block["name"] as? String else { continue }
                activity.toolCounts[name, default: 0] += 1

                // Only tools that *change* a file count as touching it. Reading
                // one is not work on it, and reporting "edited README.md" when
                // the agent merely opened it is worse than saying nothing.
                guard Self.writingTools.contains(name),
                      let input = block["input"] as? [String: Any],
                      let filePath = input["file_path"] as? String ?? input["path"] as? String,
                      Self.isInside(filePath, projectPath: projectPath)
                else { continue }

                // `Write` on a path not yet seen is a creation; anything else is
                // an edit. Getting this exactly right would need the filesystem's
                // history, and the distinction only has to be useful, not exact.
                let created = name == "Write" && seen[filePath] == nil
                if seen[filePath] == nil { order.append(filePath) }
                seen[filePath] = (seen[filePath] ?? false) || created
            }
        }

        activity.touched = order.reversed().prefix(Self.maxFiles).map {
            TouchedFile(path: $0, wasCreated: seen[$0] ?? false)
        }
        return activity
    }

    /// Tools that modify a file. Deliberately a closed set rather than "anything
    /// with a file_path": an unrecognised tool is reported as a count, not as a
    /// change, because claiming a file changed when it didn't is the one error
    /// that makes this signal worth less than nothing.
    static let writingTools: Set<String> = [
        "Write", "Edit", "MultiEdit", "NotebookEdit", "str_replace_editor", "apply_patch"
    ]

    /// Files outside the project don't count as work on it.
    static func isInside(_ path: String, projectPath: String?) -> Bool {
        guard let projectPath, !projectPath.isEmpty else { return false }
        let root = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"
        return path == projectPath || path.hasPrefix(root)
    }
}
