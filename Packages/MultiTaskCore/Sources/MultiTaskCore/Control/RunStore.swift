import Foundation

public enum RunState: String, Codable, Sendable {
    case starting
    case running
    case finished
    case failed
    /// Stopped by a person, or by a budget.
    case cancelled

    public var isTerminal: Bool { self != .starting && self != .running }

    public var label: String {
        switch self {
        case .starting: return "Starting"
        case .running: return "Running"
        case .finished: return "Finished"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

/// One invocation of a delegate.
///
/// A run always belongs to a task where one exists, because that attachment is
/// what makes the audit trail and the report describe something somebody asked
/// for rather than a command that happened.
public struct RunRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var taskId: String?
    public var projectId: String?
    /// The delegate name — "claude", "codex", "agy", "agent", "lm".
    public var delegate: String
    /// Exactly what was executed, argument by argument. Stored so a run can be
    /// explained afterwards without guessing, and so a report can show it.
    public var command: [String]
    public var workingDirectory: String
    public var state: RunState
    public var startedAt: Date
    public var endedAt: Date?
    public var exitCode: Int32?
    /// Why it ended, when that isn't obvious from the exit code.
    public var note: String?
    public var pid: Int32?

    public init(id: String, taskId: String? = nil, projectId: String? = nil,
                delegate: String, command: [String], workingDirectory: String,
                state: RunState = .starting, startedAt: Date = Date(),
                endedAt: Date? = nil, exitCode: Int32? = nil,
                note: String? = nil, pid: Int32? = nil) {
        self.id = id
        self.taskId = taskId
        self.projectId = projectId
        self.delegate = delegate
        self.command = command
        self.workingDirectory = workingDirectory
        self.state = state
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exitCode = exitCode
        self.note = note
        self.pid = pid
    }

    public var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

    /// The shell-ish form, for display only — never for execution.
    public var displayCommand: String { command.joined(separator: " ") }

    /// One readable line.
    ///
    /// A delegate's prompt is a multi-paragraph brief, and pasting it raw into a
    /// confirmation produces a wall nobody reads — which turns the gate into a
    /// reflex `y`. So newlines collapse and long arguments are elided; the full
    /// command is still on the record for anyone who wants it.
    public var shortCommand: String {
        let flattened = command.map { argument -> String in
            let single = argument
                .replacingOccurrences(of: "\n", with: " ")
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .joined(separator: " ")
            return single.count > 60 ? String(single.prefix(57)) + "…" : single
        }
        return flattened.joined(separator: " ")
    }

    public static func identifier(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "run-\(formatter.string(from: now))-\(Int.random(in: 100...999))"
    }
}

/// Runs on disk, one directory each, under `~/.multitaskmanager/runs/`.
///
/// **Output goes to files, not an in-app terminal.** Pretending to be a terminal
/// is a large amount of work to end up worse than the terminal the user already
/// has — and once output is a file, the existing detectors pick the session up
/// like any other, and a report can be assembled from it later.
public final class RunStore: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileSupport.stateDirectory
            .appendingPathComponent("runs", isDirectory: true)
        try? FileSupport.fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public var path: String { directory.path }

    public func directory(for id: String) -> URL {
        directory.appendingPathComponent(id, isDirectory: true)
    }

    public func stdoutURL(for id: String) -> URL { directory(for: id).appendingPathComponent("stdout.log") }
    public func stderrURL(for id: String) -> URL { directory(for: id).appendingPathComponent("stderr.log") }

    public func save(_ run: RunRecord) {
        lock.lock()
        defer { lock.unlock() }
        let dir = directory(for: run.id)
        try? FileSupport.fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(run) else { return }
        try? FileSupport.write(data, to: dir.appendingPathComponent("run.json"))
    }

    public func load() -> [RunRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard FileSupport.isDirectory(directory) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return FileSupport.contents(of: directory)
            .filter { FileSupport.isDirectory($0) }
            .compactMap { dir in
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("run.json")) else { return nil }
                return try? decoder.decode(RunRecord.self, from: data)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func run(id: String) -> RunRecord? {
        load().first { $0.id == id }
    }

    /// Tail of a run's output, for showing what it's doing without opening a file.
    public func tail(of id: String, bytes: UInt64 = 8 * 1024) -> String? {
        FileSupport.readTail(of: stdoutURL(for: id), limit: bytes)
    }
}
