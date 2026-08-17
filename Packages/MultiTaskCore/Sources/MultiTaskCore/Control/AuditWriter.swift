import Foundation

/// Appends this app's own actions to the harness audit log.
///
/// Once the app launches and steers agents, what it did on your behalf belongs
/// in the same log as everything else — so `audit.sh` renders one start-to-finish
/// timeline whether a run began in a terminal or here. Records use `tool: "mtm"`
/// and **exactly** the field names in the harness's own shape: a near-miss
/// produces records that parse but never display, which is the worst outcome
/// because nothing appears broken.
///
/// Ground rule 5 still applies in the other direction: this writes only what the
/// app itself did. It never re-logs anything read *from* the audit log.
public struct AuditWriter: Sendable {
    public static let toolName = "mtm"

    private let path: String

    public init(path: String? = nil) {
        self.path = path ?? Configuration.defaultAuditLogPath
    }

    public init(configuration: Configuration) {
        self.path = configuration.auditLogPath
    }

    static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// One record, in the harness's shape.
    ///
    /// - Parameters:
    ///   - event: `PreToolUse` before acting, `PostToolUse` after — the same
    ///     pairing the hooks use, so a control-plane action reads like any other.
    ///   - toolName: what the app did — `run`, `cancel`, `provision`.
    ///   - input: truncated and never containing anything read from the log.
    public func record(event: String, toolName: String, session: String,
                       cwd: String?, input: String?, response: String? = nil,
                       at: Date = Date()) {
        var record: [String: Any] = [
            "ts": Self.formatter.string(from: at),
            "tool": Self.toolName,
            "session": session,
            "event": event,
            "tool_name": toolName,
            "tool_use_id": NSNull(),
            "input": input.map { String($0.prefix(2000)) } ?? NSNull(),
            "response": response.map { String($0.prefix(2000)) } ?? NSNull()
        ]
        record["cwd"] = cwd ?? NSNull()

        guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        else { return }
        data.append(UInt8(ascii: "\n"))
        append(data)
    }

    /// Convenience for a run's two records.
    public func recordStart(_ run: RunRecord) {
        record(event: "PreToolUse", toolName: "run", session: run.id,
               cwd: run.workingDirectory, input: run.displayCommand)
    }

    public func recordEnd(_ run: RunRecord) {
        let outcome = "\(run.state.rawValue)"
            + (run.exitCode.map { " exit \($0)" } ?? "")
            + (run.note.map { " — \($0)" } ?? "")
        record(event: "PostToolUse", toolName: "run", session: run.id,
               cwd: run.workingDirectory, input: run.displayCommand, response: outcome)
    }

    /// Appends without disturbing anything else writing to the log.
    ///
    /// A single `write` of one line is what the harness's own shell hook does on
    /// platforms without `flock`; the readers on both sides already tolerate an
    /// interleaved line, and losing a record is better than blocking a launch.
    private func append(_ data: Data) {
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            return
        }
        // No log yet — create it, and its directory.
        let url = URL(fileURLWithPath: path)
        try? FileSupport.fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
