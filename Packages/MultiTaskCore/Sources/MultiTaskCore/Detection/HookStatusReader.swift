import Foundation

/// Optional, best-effort precise status source.
///
/// A Claude Code / Codex `Stop` or `Notification` hook can drop a small JSON file
/// into `~/.multitaskmanager/status/`. When present, these records give an exact
/// status that outranks every inferred signal. The app works fully without any
/// hooks configured.
///
/// Records produced here are keyed with a `hook:` id prefix. `DetectionEngine`
/// matches them to a detected session by `sessionId` first and `projectPath`
/// second, copying the status across; unmatched records are surfaced on their own.
///
/// ## Contract v1 (still accepted)
/// ```json
/// { "projectPath": "/Users/me/dev/app", "project": "app",
///   "status": "needsAttention", "updatedAt": 1719240000 }
/// ```
///
/// ## Contract v2
/// ```json
/// { "schemaVersion": 2, "projectPath": "/Users/me/dev/app", "project": "app",
///   "sessionId": "f9f9b53d-1831-4798-966e-45eddd79dd68",
///   "status": "needsAttention", "waiting": "approval",
///   "reason": "Bash(rm -rf build/)", "updatedAt": 1719240000 }
/// ```
///
/// A record with no `schemaVersion` parses exactly as it did under v1, so an
/// un-upgraded hook keeps working unchanged. `sessionId` is what lets a hook
/// address one session in a project running several.
public struct HookStatusReader: SessionDetector {
    public let id = "hooks"
    public let displayName = "Hook Status Files"

    public var maxAge: TimeInterval
    public var statusDirectory: URL

    public init(maxAge: TimeInterval = 24 * 60 * 60, statusDirectory: URL? = nil) {
        self.maxAge = maxAge
        self.statusDirectory = statusDirectory ?? Self.defaultStatusDirectory
    }

    public static var defaultStatusDirectory: URL {
        FileSupport.stateDirectory.appendingPathComponent("status", isDirectory: true)
    }

    /// One parsed status file. Kept `public` so the daemon and CLI can reuse the
    /// decoding without going through a detector pass.
    public struct Record: Decodable, Sendable {
        public var schemaVersion: Int?
        public var projectPath: String?
        public var project: String?
        public var sessionId: String?
        public var status: String
        public var waiting: String?
        public var reason: String?
        public var updatedAt: Double?
    }

    public func detect() async -> DetectionOutcome {
        let dir = statusDirectory
        guard FileSupport.isDirectory(dir) else {
            // Hooks are opt-in, so their absence is normal rather than degraded —
            // reporting it as breakage would train the user to ignore the warning.
            return .empty
        }
        let cutoff = Date().addingTimeInterval(-maxAge)
        var sessions: [Session] = []
        var unreadable = 0

        for file in FileSupport.contents(of: dir) where file.pathExtension == "json" {
            let mtime = FileSupport.modificationDate(of: file)
            guard mtime >= cutoff else { continue }
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  let parsed = Self.parseStatus(record.status)
            else {
                unreadable += 1
                continue
            }

            let projectPath = record.projectPath
            let projectName = record.project
                ?? projectPath.map(FileSupport.lastComponent(of:))
                ?? file.deletingPathExtension().lastPathComponent
            let lastActivity = record.updatedAt.map { Date(timeIntervalSince1970: $0) } ?? mtime
            let waiting = record.waiting.flatMap(WaitingReason.init(rawValue:))

            // A v2 record that says *why* it's waiting can correct a status that only
            // said "needs attention" — an error is still attention, but a `done`
            // shouldn't outrank a live approval gate during triage.
            sessions.append(Session(
                id: "hook:\(record.sessionId ?? projectPath ?? projectName)",
                title: projectName,
                projectName: projectName,
                projectPath: projectPath,
                source: .claudeCode,
                lastActivity: lastActivity,
                harnessSessionId: record.sessionId,
                hookStatus: parsed,
                waiting: waiting,
                reason: record.reason,
                evidence: .hook
            ))
        }

        let degraded = unreadable == 0 ? nil : DegradedReason(
            detectorId: id,
            message: "\(unreadable) unreadable hook status file(s) in \(dir.path)"
        )
        return DetectionOutcome(sessions: sessions, degraded: degraded)
    }

    public static func parseStatus(_ raw: String) -> SessionStatus? {
        switch raw.lowercased() {
        case "working", "active", "running", "busy":
            return .working
        case "needsattention", "needs_attention", "waiting", "stop", "done", "idle_waiting", "attention", "error", "blocked":
            return .needsAttention
        case "idle":
            return .idle
        default:
            return nil
        }
    }
}
