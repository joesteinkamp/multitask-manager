import Foundation

/// Where a session was discovered (or that it was added by hand).
public enum SessionSource: Codable, Hashable, Sendable {
    case claudeCode
    case codex
    case desktopApp(bundleId: String)
    case devFolder
    case manual

    /// Short label shown as a tag in the UI.
    public var label: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .desktopApp: return "Desktop"
        case .devFolder: return "Folder"
        case .manual: return "Manual"
        }
    }

    /// SF Symbol representing the source.
    public var symbolName: String {
        switch self {
        case .claudeCode: return "terminal"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .desktopApp: return "app.badge"
        case .devFolder: return "folder"
        case .manual: return "hand.point.up.left"
        }
    }

    /// The harness name this source appears under in the audit log's `tool` field,
    /// or `nil` for sources the harness never logs.
    public var auditToolName: String? {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .desktopApp, .devFolder, .manual: return nil
        }
    }
}

/// A single tracked unit of work the user is multitasking on.
///
/// `id` is intentionally *stable* across refreshes (derived from the source plus a
/// path or uuid) so that user overrides — hides, renames, pins — and the computed
/// status survive re-detection.
public struct Session: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var projectName: String
    public var projectPath: String?
    public var source: SessionSource

    /// Timestamp of the most recent activity signal for this session. Drives the
    /// stagnation heuristic in `DetectionEngine`.
    public var lastActivity: Date

    /// True when the user added this entry manually (vs. auto-detected).
    public var isManual: Bool = false

    /// Optional handles used to focus/activate the underlying work.
    public var pid: Int32?
    public var bundleId: String?

    /// Path to the session's transcript/log, when one exists (Claude Code / Codex).
    /// Used to read what the session is working on right now. `nil` for desktop-app,
    /// dev-folder, and manual entries.
    public var transcriptPath: String?

    /// The harness's own id for this session — the transcript filename's UUID for
    /// Claude Code. This is the join key into the audit log; verified to match for
    /// 95 of 97 local transcripts. `nil` when the source doesn't expose one.
    public var harnessSessionId: String?

    /// Plain-text project briefing (goal / now / next) assembled by
    /// `ProjectContextReader`. Transient — recomputed each refresh, never persisted.
    public var context: ProjectContext?

    /// Precise status reported by an opt-in hook, when available. Overrides the
    /// activity-timeout heuristic.
    public var hookStatus: SessionStatus?

    /// Why the session is waiting, when a v2 hook said so. Drives triage ordering.
    public var waiting: WaitingReason?

    /// Short free-text explanation from a v2 hook record, or the `SessionEnd`
    /// reason from the audit log ("clear", "prompt_input_exit", …).
    public var reason: String?

    /// What the current status is based on. Transient, recomputed each refresh.
    public var evidence: StatusEvidence = .none

    /// Last tool this session invoked, per the audit log. Transient.
    public var lastToolName: String?

    /// Computed/last-published status. Filled in by `DetectionEngine`.
    public var status: SessionStatus = .unknown

    /// Whether the user pinned this session to keep it near the top.
    public var isPinned: Bool = false

    public init(id: String, title: String, projectName: String, projectPath: String? = nil,
                source: SessionSource, lastActivity: Date, isManual: Bool = false,
                pid: Int32? = nil, bundleId: String? = nil, transcriptPath: String? = nil,
                harnessSessionId: String? = nil, context: ProjectContext? = nil,
                hookStatus: SessionStatus? = nil, waiting: WaitingReason? = nil,
                reason: String? = nil, evidence: StatusEvidence = .none,
                lastToolName: String? = nil, status: SessionStatus = .unknown,
                isPinned: Bool = false) {
        self.id = id
        self.title = title
        self.projectName = projectName
        self.projectPath = projectPath
        self.source = source
        self.lastActivity = lastActivity
        self.isManual = isManual
        self.pid = pid
        self.bundleId = bundleId
        self.transcriptPath = transcriptPath
        self.harnessSessionId = harnessSessionId
        self.context = context
        self.hookStatus = hookStatus
        self.waiting = waiting
        self.reason = reason
        self.evidence = evidence
        self.lastToolName = lastToolName
        self.status = status
        self.isPinned = isPinned
    }
}
