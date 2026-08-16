import Foundation

/// Where a session was discovered (or that it was added by hand).
enum SessionSource: Codable, Hashable {
    case claudeCode
    case codex
    case desktopApp(bundleId: String)
    case devFolder
    case manual

    /// Short label shown as a tag in the UI.
    var label: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .desktopApp: return "Desktop"
        case .devFolder: return "Folder"
        case .manual: return "Manual"
        }
    }

    /// SF Symbol representing the source.
    var symbolName: String {
        switch self {
        case .claudeCode: return "terminal"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .desktopApp: return "app.badge"
        case .devFolder: return "folder"
        case .manual: return "hand.point.up.left"
        }
    }
}

/// A single tracked unit of work the user is multitasking on.
///
/// `id` is intentionally *stable* across refreshes (derived from the source plus a
/// path or uuid) so that user overrides — hides, renames, pins — and the computed
/// status survive re-detection.
struct Session: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var projectName: String
    var projectPath: String?
    var source: SessionSource

    /// Timestamp of the most recent activity signal for this session. Drives the
    /// stagnation heuristic in `SessionStore`.
    var lastActivity: Date

    /// True when the user added this entry manually (vs. auto-detected).
    var isManual: Bool = false

    /// Optional handles used to focus/activate the underlying work.
    var pid: Int32?
    var bundleId: String?

    /// Path to the session's transcript/log, when one exists (Claude Code / Codex).
    /// Used to read what the session is working on right now. `nil` for desktop-app,
    /// dev-folder, and manual entries.
    var transcriptPath: String?

    /// Plain-text project briefing (goal / now / next) assembled by
    /// `ProjectContextReader`. Transient — recomputed each refresh, never persisted.
    var context: ProjectContext?

    /// Precise status reported by an opt-in hook, when available. Overrides the
    /// activity-timeout heuristic.
    var hookStatus: SessionStatus?

    /// Why the session is waiting, from a v2 hook record. Nil for v1 hooks and
    /// for sessions with no hook at all.
    var waiting: WaitingKind?

    /// Short free-text explanation from a v2 hook record ("needs approval to run
    /// the migration"). Shown in the row and used as the notification body.
    var statusReason: String?

    /// Harness session id, when something told us one directly — currently a v2
    /// hook record. Preferred over the transcript-derived guess when joining to
    /// the audit log.
    var harnessSessionID: String?

    /// Derived audit-log index for this session. Transient — recomputed each
    /// refresh by `AuditLogReader`, never persisted.
    var audit: AuditActivity?

    /// Computed/last-published status. Filled in by `SessionStore`.
    var status: SessionStatus = .unknown

    /// Whether the user pinned this session to keep it near the top.
    var isPinned: Bool = false

    /// Key used to look this session up in the audit log index.
    ///
    /// A v2 hook tells us the id outright. Otherwise we guess it from the
    /// transcript filename, which is a UUID for Claude Code
    /// (`<session-uuid>.jsonl`) and contains one for Codex rollouts
    /// (`rollout-<timestamp>-<session-uuid>.jsonl`). Whether that guess matches
    /// the audit log's `session` value is open question 1 in docs/PLAN.md —
    /// `AuditLogReader` falls back to a working-directory join when it doesn't.
    var auditSessionID: String? {
        if let harnessSessionID, !harnessSessionID.isEmpty { return harnessSessionID }
        guard let transcriptPath else { return nil }
        let stem = ((transcriptPath as NSString).lastPathComponent as NSString).deletingPathExtension
        return Session.embeddedUUID(in: stem) ?? stem
    }

    /// Finds a `8-4-4-4-12` hex run inside a dash-separated string. Cheaper than
    /// a regex and runs once per session per refresh.
    static func embeddedUUID(in text: String) -> String? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        let widths = [8, 4, 4, 4, 12]
        guard parts.count >= widths.count else { return nil }

        for start in 0...(parts.count - widths.count) {
            let window = parts[start..<(start + widths.count)]
            let matches = zip(window, widths).allSatisfy { part, width in
                part.count == width && part.allSatisfy(\.isHexDigit)
            }
            if matches { return window.joined(separator: "-") }
        }
        return nil
    }
}
