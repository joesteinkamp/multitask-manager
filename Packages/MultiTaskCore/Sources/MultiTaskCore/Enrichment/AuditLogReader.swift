import Foundation

/// What the audit log knows about one session.
public struct AuditActivity: Sendable, Equatable {
    /// Timestamp of the most recent record for this session, of any event type.
    public var lastEventAt: Date
    /// `tool_name` of the most recent tool record — "Edit", "Bash", …
    public var lastToolName: String?
    /// How many records this session has contributed since the reader started.
    public var eventCount: Int
    /// When the harness recorded `SessionEnd`. Non-nil means finished as a *fact*,
    /// not an inference — cleared again if later activity shows the session resumed.
    public var endedAt: Date?
    /// Why it ended, taken from the `SessionEnd` record's `tool_name`
    /// ("clear", "prompt_input_exit", …).
    public var endReason: String?
    /// Working directory last seen for this session, used for the fallback join.
    public var cwd: String?
    /// Harness that wrote the records: "claude", "codex", "cursor", …
    public var tool: String?

    public init(lastEventAt: Date, lastToolName: String? = nil, eventCount: Int = 0,
                endedAt: Date? = nil, endReason: String? = nil, cwd: String? = nil,
                tool: String? = nil) {
        self.lastEventAt = lastEventAt
        self.lastToolName = lastToolName
        self.eventCount = eventCount
        self.endedAt = endedAt
        self.endReason = endReason
        self.cwd = cwd
        self.tool = tool
    }

    public var hasEnded: Bool { endedAt != nil }
}

/// A snapshot of the audit log's contents, keyed both ways.
public struct AuditIndex: Sendable {
    /// Exact join: harness session id → activity. Verified against real data to
    /// cover 95 of 97 local Claude Code transcripts and every Codex rollout.
    public var bySession: [String: AuditActivity] = [:]
    /// Coarse fallback for sessions whose id we can't line up: project path →
    /// most recent activity seen in that directory.
    public var byCWD: [String: AuditActivity] = [:]
    /// Lines that could not be parsed, cumulative. Surfaced in Settings as a health
    /// metric rather than hidden, because a rising count means the log is being
    /// corrupted by interleaved concurrent appends.
    public var malformedLines: Int = 0
    /// Total records consumed since the reader started.
    public var recordsRead: Int = 0
    /// When the last successful pass finished, `nil` before the first one.
    public var lastReadAt: Date?
    /// Set when the log is missing or unreadable — the app degrades to transcript
    /// mtimes and says so, rather than silently losing precision.
    public var degraded: DegradedReason?

    public init() {}

    /// Looks up a session by exact id, falling back to its project directory.
    ///
    /// - Parameter tool: which agent the session belongs to. **The directory
    ///   fallback must not cross agents.** Three Codex sessions working in one
    ///   project produce audit events for that directory; a Claude Code session
    ///   in the same project then matched them and reported *itself* as working.
    ///   The result was a project showing "Claude Code active" when no Claude
    ///   Code was running at all — activity attributed to the wrong agent, and
    ///   the same work counted twice.
    public func activity(sessionId: String?, projectPath: String?,
                         tool: String? = nil) -> AuditActivity? {
        if let sessionId, let hit = bySession[sessionId] { return hit }
        guard let projectPath, let hit = byCWD[projectPath] else { return nil }
        // No tool on either side means the old, coarse behaviour — better than
        // nothing when the harness did not record one.
        guard let tool, let hitTool = hit.tool else { return hit }
        return hitTool.caseInsensitiveCompare(tool) == .orderedSame ? hit : nil
    }
}

/// Reads `~/.ai-logs/tool-calls.jsonl` — the harness's own record of every tool
/// call every agent makes — and turns it into an activity index.
///
/// This is an *enrichment source*, not a `SessionDetector`: it produces no sessions
/// of its own, it annotates the ones the detectors found, the way
/// `ProjectContextReader` does. Deleting the log leaves the app behaving exactly as
/// it did before this existed.
///
/// ## Why it matters
/// Before this, "finished" was inferred from a transcript file going quiet. The log
/// carries an explicit `SessionEnd` record, so finished becomes a fact.
///
/// ## Handling of the file itself
/// The log is append-only and large (35 MB locally). Each pass reads only from the
/// last offset to EOF, buffering a trailing partial line for the next pass. On the
/// first pass it seeks to the last 2 MB rather than parsing months of history.
/// Rotation is detected by `(device, inode)` change or by the file shrinking.
///
/// ## Privacy
/// Records carry truncated, best-effort-redacted tool inputs and responses. Those
/// two fields are never decoded, never retained, and never re-logged — only the
/// derived counters and timestamps below survive a pass (ground rule 5).
public final class AuditLogReader: @unchecked Sendable {
    /// One record, deliberately omitting `input` and `response` so the decoder
    /// never materialises them.
    struct Record: Decodable {
        var ts: String?
        var tool: String?
        var session: String?
        var cwd: String?
        var event: String?
        var tool_name: String?
    }

    /// How much history to read on the very first pass.
    static let firstPassWindow: UInt64 = 2 * 1024 * 1024
    /// Sessions untouched for longer than this are dropped from the index so it
    /// can't grow without bound in a long-running daemon.
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    private let path: String
    private let lock = NSLock()

    // Tail state, all guarded by `lock`.
    private var offset: UInt64 = 0
    private var identity: (device: UInt64, inode: UInt64) = (0, 0)
    private var leftover = Data()
    private var index = AuditIndex()
    private var started = false

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    /// Some harnesses write fractional seconds; a second formatter avoids
    /// reconfiguring the first one per line.
    private let isoFractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(path: String) {
        self.path = FileSupport.expandingTilde(path)
    }

    public convenience init(configuration: Configuration) {
        self.init(path: configuration.auditLogPath)
    }

    /// Consumes everything appended since the last call and returns the updated
    /// index. Never throws: a missing or unreadable log yields a degraded index and
    /// the rest of the app carries on with transcript mtimes.
    @discardableResult
    public func refresh(now: Date = Date()) -> AuditIndex {
        lock.lock()
        defer { lock.unlock() }

        guard FileSupport.fileManager.fileExists(atPath: path) else {
            index.degraded = DegradedReason(
                detectorId: "auditLog",
                message: "No harness audit log at \(path) — status falls back to file activity"
            )
            return index
        }

        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            index.degraded = DegradedReason(
                detectorId: "auditLog",
                message: "Cannot read \(path)"
            )
            return index
        }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let currentIdentity = FileSupport.fileIdentity(ofPath: path)

        var dropLeadingPartial = false
        if !started {
            // First pass: skip the backlog. Months of history would cost seconds to
            // parse and tell us nothing about what is running right now.
            started = true
            identity = currentIdentity
            if size > Self.firstPassWindow {
                offset = size - Self.firstPassWindow
                dropLeadingPartial = true
            } else {
                offset = 0
            }
        } else if currentIdentity != identity || size < offset {
            // Rotated (or truncated) out from under us: start over at the top of the
            // new file rather than reading from a meaningless offset.
            identity = currentIdentity
            offset = 0
            leftover.removeAll(keepingCapacity: false)
        }

        guard size > offset else {
            index.degraded = nil
            index.lastReadAt = now
            return index
        }

        try? handle.seek(toOffset: offset)
        let fresh = (try? handle.readToEnd()) ?? Data()
        offset = size

        var buffer = leftover
        buffer.append(fresh)
        leftover.removeAll(keepingCapacity: true)

        // Split on newline bytes rather than on decoded characters, so a multi-byte
        // sequence straddling two passes survives instead of becoming a parse error.
        var lines = buffer.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if let last = lines.last, !buffer.isEmpty, buffer.last != UInt8(ascii: "\n") {
            leftover = Data(last)
            lines.removeLast()
        }
        if dropLeadingPartial, !lines.isEmpty {
            // The 2 MB seek almost certainly landed mid-record.
            lines.removeFirst()
        }

        for line in lines where !line.isEmpty {
            ingest(Data(line))
        }

        prune(now: now)
        index.degraded = nil
        index.lastReadAt = now
        return index
    }

    /// The current index without reading anything new.
    public var snapshot: AuditIndex {
        lock.lock()
        defer { lock.unlock() }
        return index
    }

    /// Cumulative count of lines that failed to parse. Rising means concurrent
    /// appends are interleaving — expected on stock macOS, which has no `flock`.
    public var malformedLineCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return index.malformedLines
    }

    // MARK: Parsing

    /// Folds one line into the index. Any failure increments the malformed counter
    /// and returns — one bad line must never abort a pass.
    private func ingest(_ line: Data) {
        guard let record = try? JSONDecoder().decode(Record.self, from: line),
              let session = record.session, !session.isEmpty,
              let tsString = record.ts,
              let ts = parseTimestamp(tsString)
        else {
            index.malformedLines += 1
            return
        }

        index.recordsRead += 1
        let event = AuditEvent(rawValue: record.event)

        var activity = index.bySession[session] ?? AuditActivity(lastEventAt: ts)
        activity.eventCount += 1
        activity.tool = record.tool ?? activity.tool
        if let cwd = record.cwd, !cwd.isEmpty { activity.cwd = cwd }

        if ts >= activity.lastEventAt {
            activity.lastEventAt = ts
            if event == .sessionEnd {
                activity.endedAt = ts
                activity.endReason = record.tool_name
            } else {
                // A record after the end means the session was resumed, so "finished"
                // is no longer true. Without this a resumed session would stay marked
                // finished forever.
                activity.endedAt = nil
                activity.endReason = nil
                if event.isToolCall { activity.lastToolName = record.tool_name }
            }
        } else if event == .sessionEnd, activity.endedAt == nil {
            // Out-of-order arrival: still record the end, but don't move the clock.
            activity.endedAt = ts
            activity.endReason = record.tool_name
        }

        index.bySession[session] = activity

        // Secondary index for the coarse join. `cwd` is absent from a few hundred
        // records locally, so this is genuinely best-effort.
        if let cwd = activity.cwd {
            if let existing = index.byCWD[cwd], existing.lastEventAt > activity.lastEventAt {
                // Keep the newer session's view of this directory.
            } else {
                index.byCWD[cwd] = activity
            }
        }
    }

    private func parseTimestamp(_ raw: String) -> Date? {
        isoFormatter.date(from: raw) ?? isoFractionalFormatter.date(from: raw)
    }

    /// Drops long-dead sessions so a resident daemon's index stays bounded.
    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        index.bySession = index.bySession.filter { $0.value.lastEventAt >= cutoff }
        index.byCWD = index.byCWD.filter { $0.value.lastEventAt >= cutoff }
    }
}

/// The event names the harness writes, normalised.
///
/// Two things the raw log forced on this type: names arrive in more than one
/// casing (`PreToolUse` alongside `preToolUse` under the same `claude` harness),
/// and Cursor uses an entirely different vocabulary (`beforeShellExecution`,
/// `afterFileEdit`). Matching is therefore case-insensitive over a known set, and
/// anything unrecognised still counts as activity — an unknown event still proves
/// the agent was alive at that timestamp, which is the signal that matters most.
public enum AuditEvent: Equatable, Sendable {
    case preToolUse
    case postToolUse
    case sessionEnd
    case preCompact
    case scorecard
    /// Cursor's equivalents.
    case beforeShellExecution
    case afterFileEdit
    /// Anything the harness adds later. Still counts as activity.
    case other(String)

    public init(rawValue: String?) {
        switch (rawValue ?? "").lowercased() {
        case "pretooluse": self = .preToolUse
        case "posttooluse": self = .postToolUse
        case "sessionend": self = .sessionEnd
        case "precompact": self = .preCompact
        case "scorecard": self = .scorecard
        case "beforeshellexecution": self = .beforeShellExecution
        case "afterfileedit": self = .afterFileEdit
        default: self = .other(rawValue ?? "")
        }
    }

    /// Whether the record names a tool worth showing as "last tool".
    public var isToolCall: Bool {
        switch self {
        case .preToolUse, .postToolUse, .beforeShellExecution, .afterFileEdit: return true
        case .sessionEnd, .preCompact, .scorecard, .other: return false
        }
    }
}
