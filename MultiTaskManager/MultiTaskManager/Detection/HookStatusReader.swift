import Foundation

/// Optional, best-effort precise status source.
///
/// A Claude Code / Codex `Stop` or `Notification` hook can drop a small JSON file
/// into `~/.multitaskmanager/status/`. When present, these records give an exact
/// "working" / "needs attention" signal that overrides the activity-timeout
/// heuristic. The app works fully without any hooks configured.
///
/// Records produced here are keyed with a `hook:` id prefix. `SessionStore` matches
/// them to a detected session by `projectPath` and copies the `hookStatus` over;
/// unmatched records are surfaced on their own.
///
/// Expected file shape (any extra keys ignored):
/// ```json
/// { "projectPath": "/Users/me/dev/app", "project": "app",
///   "status": "needsAttention", "updatedAt": 1719240000 }
/// ```
struct HookStatusReader: SessionDetector {
    let id = "hooks"
    let displayName = "Hook Status Files"

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
                hookStatus: parsed
            )
            sessions.append(session)
        }
        return sessions
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
