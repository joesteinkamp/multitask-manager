import Foundation

/// Reads the harness audit log and turns it into an activity signal.
///
/// This is an *enrichment source*, not a `SessionDetector`: it never produces
/// sessions, it annotates the ones the detectors already found — the same shape
/// as `ProjectContextReader`. Delete the log and the app behaves exactly as it
/// did before (ground rule 1).
///
/// The log is a JSONL append log written by the harness's `log-tool.sh`, at
/// `$AI_TOOL_LOG` or `~/.ai-logs/tool-calls.jsonl`. One record per line:
///
/// ```json
/// {"ts":"2026-08-15T12:00:00Z","tool":"claude","session":"abc123",
///  "cwd":"/Users/joe/dev/app","event":"PreToolUse","tool_name":"Edit",
///  "tool_use_id":"toolu_01…","input":"{…}","response":"{…}"}
/// ```
///
/// Three properties of that file drive the whole design:
///
/// 1. **It only grows.** So each pass reads `offset → EOF` and nothing else,
///    which keeps this affordable on a 5-second refresh even when the log is
///    hundreds of megabytes.
/// 2. **It is not reliably line-atomic.** The harness appends under `flock`
///    where available, and *stock macOS has no `flock`* — so two parallel agents
///    can interleave a single line into garbage. Malformed lines are skipped and
///    counted, never fatal.
/// 3. **It carries sensitive text.** `input` and `response` are truncated and
///    pattern-redacted on a best-effort basis, which is not a guarantee. This
///    type decodes neither field, so they are never retained, never re-logged,
///    and never displayed (ground rule 5).
final class AuditLogReader {
    static let shared = AuditLogReader()

    // MARK: Types

    /// Per-pass snapshot handed to `attach(to:index:)`.
    struct Index {
        /// Audit `session` value → what we know about it.
        var bySession: [String: AuditActivity] = [:]
        /// Working directory → most recent event there. The coarser fallback
        /// join for when session ids don't line up (open question 1).
        var byWorkingDirectory: [String: Date] = [:]

        var isEmpty: Bool { bySession.isEmpty && byWorkingDirectory.isEmpty }
    }

    /// Surfaced in Settings so the log's health is visible rather than guessed
    /// at. `malformedLines` in particular is expected to be non-zero on a busy
    /// machine — it's a symptom of the missing `flock`, not a bug.
    struct Health {
        var path: String = ""
        var exists: Bool = false
        var sessionsTracked: Int = 0
        var recordsIndexed: Int = 0
        var malformedLines: Int = 0
        var rotations: Int = 0
        var bytesRead: Int = 0
        var lastReadAt: Date?
    }

    /// Fields we are willing to look at. Everything else in the record —
    /// including `input` and `response` — is dropped here, at parse time.
    private struct Record: Decodable {
        var ts: String?
        var session: String?
        var cwd: String?
        var event: String?
        var toolName: String?

        enum CodingKeys: String, CodingKey {
            case ts, session, cwd, event
            case toolName = "tool_name"
        }
    }

    // MARK: Tuning

    /// How much of an unseen log to prime from. Two megabytes is a few thousand
    /// records — enough to classify whatever is running now, without paying to
    /// parse a history nobody asked for.
    private let primeWindow: UInt64 = 2 * 1024 * 1024

    /// Ceiling on a single pass, so a burst (or a very long sleep) can't turn
    /// one refresh tick into a multi-hundred-megabyte read.
    private let maxBytesPerPass: UInt64 = 8 * 1024 * 1024

    /// A "line" longer than this is not a line, it's a corrupt append. Drop it
    /// rather than buffering it forever.
    private let maxPartialBytes = 1 * 1024 * 1024

    /// Sessions untouched for longer than this fall out of the index.
    private let retention: TimeInterval = 24 * 60 * 60

    // MARK: State

    /// Guards every mutable field below. `refresh` runs on the detection queue,
    /// `health` is read from the main actor for Settings.
    private let lock = NSLock()

    private var index = Index()
    private var health = Health()

    private var deviceID: UInt64 = 0
    private var inode: UInt64 = 0
    private var offset: UInt64 = 0
    private var partial = Data()
    private var hasPrimed = false

    // MARK: Path resolution

    static var defaultPath: URL {
        DetectorSupport.homeDirectory
            .appendingPathComponent(".ai-logs", isDirectory: true)
            .appendingPathComponent("tool-calls.jsonl")
    }

    /// Resolution order: explicit user setting, then `AI_TOOL_LOG`, then the
    /// default.
    ///
    /// The environment variable is usually *absent* here: a GUI app launched
    /// from Finder inherits `launchd`'s environment, not the user's shell. P3.1
    /// adds a login-shell environment snapshot that will make this reliable; the
    /// user setting is the escape hatch until then.
    static func resolvePath(override: String?) -> URL {
        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        if let env = ProcessInfo.processInfo.environment["AI_TOOL_LOG"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        return defaultPath
    }

    // MARK: Reading

    /// Consumes everything appended since the last call and returns the current
    /// index. Never throws: an unreadable or absent log yields an empty index,
    /// which downstream treats as "no extra signal".
    @discardableResult
    func refresh(path: URL) -> Index {
        lock.lock()
        defer { lock.unlock() }

        health.path = path.path
        health.lastReadAt = Date()

        guard let stat = Self.stat(path) else {
            // No log — drop the index so a deleted log leaves behavior exactly
            // as it was before this reader existed, rather than letting stale
            // entries steer status for another day.
            health.exists = false
            health.sessionsTracked = 0
            index = Index()
            deviceID = 0
            inode = 0
            offset = 0
            partial = Data()
            hasPrimed = false
            return index
        }
        health.exists = true

        // Rotation: a new file at the same path, or one that shrank under us.
        if stat.device != deviceID || stat.inode != inode {
            if hasPrimed { health.rotations += 1 }
            deviceID = stat.device
            inode = stat.inode
            offset = 0
            partial.removeAll(keepingCapacity: false)
            hasPrimed = false
        } else if stat.size < offset {
            health.rotations += 1
            offset = 0
            partial.removeAll(keepingCapacity: false)
        }

        var start = offset
        // True when `start` lands somewhere other than a record boundary, so the
        // bytes up to the first newline are the tail of a record we never saw.
        var startsMidRecord = false

        if !hasPrimed {
            // First sight of this file: start near the tail rather than parsing
            // a history nobody asked for.
            start = stat.size > primeWindow ? stat.size - primeWindow : 0
            startsMidRecord = start > 0
            hasPrimed = true
        } else if stat.size > start, stat.size - start > maxBytesPerPass {
            start = stat.size - maxBytesPerPass
            partial.removeAll(keepingCapacity: false)
            startsMidRecord = true
        }

        guard stat.size > start else {
            offset = stat.size
            prune(now: Date())
            return index
        }

        guard let handle = try? FileHandle(forReadingFrom: path) else { return index }
        defer { try? handle.close() }

        let chunk: Data
        do {
            try handle.seek(toOffset: start)
            chunk = try handle.readToEnd() ?? Data()
        } catch {
            return index
        }

        offset = start + UInt64(chunk.count)
        health.bytesRead += chunk.count

        // Only when we deliberately jumped into the middle of the file. A normal
        // continuation read starts exactly where the last one stopped, and its
        // first bytes are a real record even when nothing was left buffered.
        var body = chunk
        if startsMidRecord {
            if let firstNewline = body.firstIndex(of: 0x0A) {
                body = Data(body[body.index(after: firstNewline)...])
            } else {
                body = Data()
            }
        }

        let now = Date()
        consume(body, now: now)
        prune(now: now)
        return index
    }

    /// Splits a chunk into whole lines, holding any trailing fragment back for
    /// the next pass.
    private func consume(_ chunk: Data, now: Date) {
        var buffer = partial
        buffer.append(chunk)
        partial = Data()

        guard let lastNewline = buffer.lastIndex(of: 0x0A) else {
            // No complete line yet. Keep buffering unless it has stopped looking
            // like a line at all.
            if buffer.count > maxPartialBytes {
                health.malformedLines += 1
            } else {
                partial = buffer
            }
            return
        }

        let complete = buffer[buffer.startIndex...lastNewline]
        let remainder = buffer[buffer.index(after: lastNewline)...]
        partial = remainder.count > maxPartialBytes ? Data() : Data(remainder)
        if remainder.count > maxPartialBytes { health.malformedLines += 1 }

        for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
            ingest(Data(line), now: now)
        }
    }

    /// Folds one line into the index. Anything unparseable is counted and
    /// dropped — an interleaved append must never abort the pass.
    private func ingest(_ line: Data, now: Date) {
        guard let record = try? JSONDecoder().decode(Record.self, from: line) else {
            health.malformedLines += 1
            return
        }

        let timestamp = Self.parseTimestamp(record.ts) ?? now
        health.recordsIndexed += 1

        let cwd = record.cwd.flatMap { $0.isEmpty ? nil : $0 }
        if let cwd {
            let known = index.byWorkingDirectory[cwd] ?? .distantPast
            if timestamp > known { index.byWorkingDirectory[cwd] = timestamp }
        }

        guard let session = record.session, !session.isEmpty else { return }

        var activity = index.bySession[session]
            ?? AuditActivity(lastEventAt: .distantPast, eventCount: 0)
        activity.eventCount += 1
        if let cwd { activity.cwd = cwd }

        if record.event == "SessionEnd" {
            activity.endedAt = timestamp
        } else if let endedAt = activity.endedAt, timestamp > endedAt {
            // Work resumed after an end record — a resumed session is running
            // again, not finished.
            activity.endedAt = nil
        }

        if timestamp >= activity.lastEventAt {
            activity.lastEventAt = timestamp
            if let toolName = record.toolName, !toolName.isEmpty {
                activity.lastToolName = toolName
            }
        }

        index.bySession[session] = activity
    }

    /// Bounds memory: the index is only ever used to classify *current* work.
    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        index.bySession = index.bySession.filter { $0.value.lastEventAt >= cutoff }
        index.byWorkingDirectory = index.byWorkingDirectory.filter { $0.value >= cutoff }
        health.sessionsTracked = index.bySession.count
    }

    // MARK: Attaching

    /// Annotates detected sessions with whatever the index knows about them.
    ///
    /// Tries the session-id join first and falls back to working directory. The
    /// fallback is flagged on the result so status resolution can trust it less
    /// — a cwd match identifies the project, not the session, and two agents in
    /// one repo would share it.
    func attach(to sessions: [Session], index: Index) -> [Session] {
        guard !index.isEmpty else { return sessions }

        return sessions.map { session in
            var updated = session

            if let key = session.auditSessionID, let activity = index.bySession[key] {
                updated.audit = activity
            } else if let path = session.projectPath,
                      let lastEventAt = index.byWorkingDirectory[path] {
                updated.audit = AuditActivity(
                    lastEventAt: lastEventAt,
                    eventCount: 0,
                    matchedByWorkingDirectory: true
                )
            } else {
                return session
            }

            // Audit records are a truer activity signal than a transcript's
            // mtime, so let them move the clock forward (never backward).
            if let audit = updated.audit, audit.lastEventAt > updated.lastActivity {
                updated.lastActivity = audit.lastEventAt
            }
            return updated
        }
    }

    // MARK: Health

    var currentHealth: Health {
        lock.lock()
        defer { lock.unlock() }
        return health
    }

    /// Drops all tail state. Used when the configured path changes so the reader
    /// primes the new file instead of reading it at a stale offset.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        index = Index()
        health = Health()
        deviceID = 0
        inode = 0
        offset = 0
        partial = Data()
        hasPrimed = false
    }

    // MARK: Helpers

    private struct FileIdentity {
        var device: UInt64
        var inode: UInt64
        var size: UInt64
    }

    private static func stat(_ url: URL) -> FileIdentity? {
        guard let attributes = try? DetectorSupport.fileManager
            .attributesOfItem(atPath: url.path) else { return nil }
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        return FileIdentity(device: device, inode: inode, size: size)
    }

    private static let iso8601WithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// The harness writes `date -u +%Y-%m-%dT%H:%M:%SZ`, but tolerate fractional
    /// seconds and epoch seconds so a hook variant doesn't silently produce
    /// records that all look like "now".
    static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let date = iso8601.date(from: raw) { return date }
        if let date = iso8601WithFraction.date(from: raw) { return date }
        if let epoch = Double(raw), epoch > 0 { return Date(timeIntervalSince1970: epoch) }
        return nil
    }
}
