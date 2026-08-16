import Foundation

/// Optional, best-effort precise status source.
///
/// A Claude Code / Codex `Stop` or `Notification` hook can drop a small JSON file
/// into `~/.multitaskmanager/status/`. When present, these records give an exact
/// "working" / "needs attention" signal that overrides the activity-timeout
/// heuristic. The app works fully without any hooks configured.
///
/// Records produced here are keyed with a `hook:` id prefix. `SessionStore` matches
/// them to a detected session by `projectPath` and copies the hook fields over;
/// unmatched records are surfaced on their own.
///
/// ## Contract v1 (still accepted verbatim)
/// ```json
/// { "projectPath": "/Users/me/dev/app", "project": "app",
///   "status": "needsAttention", "updatedAt": 1719240000 }
/// ```
///
/// ## Contract v2
/// ```json
/// { "schemaVersion": 2, "projectPath": "/Users/me/dev/app", "project": "app",
///   "status": "needsAttention", "sessionId": "abc123",
///   "waiting": "approval", "reason": "wants to run the migration",
///   "updatedAt": 1719240000 }
/// ```
///
/// Every v2 field is optional and an absent `schemaVersion` parses exactly as v1
/// did, so a stale hook script never breaks the list. `waiting` is the field that
/// makes triage possible: only the hook can distinguish an approval gate from a
/// finished run. `sessionId` gives `AuditLogReader` an exact join key instead of
/// a filename-derived guess.
struct HookStatusReader: SessionDetector {
    let id = "hooks"
    let displayName = "Hook Status Files"

    /// Highest contract version this build understands. Records claiming a newer
    /// major are still read for their v1 fields — forward compatibility costs
    /// nothing here and a partial read beats dropping the record.
    static let supportedSchemaVersion = 2

    var maxAge: TimeInterval = 24 * 60 * 60

    static var statusDirectory: URL {
        DetectorSupport.homeDirectory
            .appendingPathComponent(".multitaskmanager", isDirectory: true)
            .appendingPathComponent("status", isDirectory: true)
    }

    private struct Record: Decodable {
        var projectPath: String?
        var project: String?
        var status: String
        var updatedAt: Double?

        // v2 additions — all optional.
        var schemaVersion: Int?
        var sessionId: String?
        var reason: String?
        var waiting: String?
    }

    func detect() -> [Session] {
        let dir = Self.statusDirectory
        guard DetectorSupport.isDirectory(dir) else { return [] }
        let cutoff = Date().addingTimeInterval(-maxAge)
        var sessions: [Session] = []

        for file in DetectorSupport.contents(of: dir) where file.pathExtension == "json" {
            let mtime = DetectorSupport.modificationDate(of: file)
            guard mtime >= cutoff,
                  let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  let parsed = Self.parseStatus(record.status)
            else { continue }

            let projectPath = record.projectPath
            let projectName = record.project
                ?? (projectPath as NSString?)?.lastPathComponent
                ?? file.deletingPathExtension().lastPathComponent
            let lastActivity = record.updatedAt.map { Date(timeIntervalSince1970: $0) } ?? mtime

            let session = Session(
                id: "hook:\(projectPath ?? projectName)",
                title: projectName,
                projectName: projectName,
                projectPath: projectPath,
                source: .claudeCode,
                lastActivity: lastActivity,
                hookStatus: parsed,
                waiting: WaitingKind.parse(record.waiting),
                statusReason: Self.trimmedReason(record.reason),
                harnessSessionID: record.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            sessions.append(session)
        }
        return sessions
    }

    /// Hook `reason` text is written by shell scripts and lands in notification
    /// bodies, so bound it and drop the empties.
    static func trimmedReason(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed.count <= 160 ? trimmed : String(trimmed.prefix(159)) + "…"
    }

    static func parseStatus(_ raw: String) -> SessionStatus? {
        switch raw.lowercased() {
        case "working", "active", "running", "busy":
            return .working
        case "needsattention", "needs_attention", "waiting", "stop", "done", "idle_waiting", "attention":
            return .needsAttention
        case "idle":
            return .idle
        default:
            return nil
        }
    }
}
