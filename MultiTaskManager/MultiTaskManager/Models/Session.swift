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

    /// Precise status reported by an opt-in hook, when available. Overrides the
    /// activity-timeout heuristic.
    var hookStatus: SessionStatus?

    /// Computed/last-published status. Filled in by `SessionStore`.
    var status: SessionStatus = .unknown

    /// Whether the user pinned this session to keep it near the top.
    var isPinned: Bool = false
}
