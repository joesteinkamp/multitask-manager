import Foundation

/// High-level state of a tracked session, derived from activity signals.
///
/// Presentation (colors) lives in the app layer — the core must not import SwiftUI,
/// so it carries only the semantics and the sort weight.
public enum SessionStatus: String, Codable, CaseIterable, Sendable {
    /// Recent activity — the agent appears to be actively working.
    case working
    /// No recent activity while the session is still alive — likely finished and
    /// waiting for the user's input/action.
    case needsAttention
    /// Stale / long-idle / underlying process gone.
    case idle
    /// Not enough information to classify.
    case unknown

    /// Sort weight so "needs attention" floats to the top of lists.
    public var sortRank: Int {
        switch self {
        case .needsAttention: return 0
        case .working: return 1
        case .idle: return 2
        case .unknown: return 3
        }
    }

    /// SF Symbol used for the per-row status dot. A plain string, so it costs the
    /// core nothing to carry and saves the app a parallel switch.
    public var symbolName: String {
        switch self {
        case .working: return "circle.fill"
        case .needsAttention: return "exclamationmark.circle.fill"
        case .idle: return "moon.zzz.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    public var label: String {
        switch self {
        case .working: return "Working"
        case .needsAttention: return "Needs attention"
        case .idle: return "Idle"
        case .unknown: return "Unknown"
        }
    }
}

/// *Why* a session is waiting, when the hook is precise enough to say (contract v2).
///
/// This is what makes triage possible: an approval gate genuinely outranks a
/// finished run, and only the hook knows which it is. Absent for sessions whose
/// status was inferred from file activity.
public enum WaitingReason: String, Codable, CaseIterable, Sendable {
    /// Blocked on a confirmation gate — the user is the only one who can proceed.
    case approval
    /// The agent asked something and stopped.
    case question
    /// The run finished successfully and is waiting to be picked up.
    case done
    /// The run stopped because something failed.
    case error

    /// Triage weight, lowest first. Approval outranks everything because it is the
    /// only state where the agent is *blocked* rather than merely finished.
    public var triageRank: Int {
        switch self {
        case .approval: return 0
        case .error: return 1
        case .question: return 2
        case .done: return 3
        }
    }

    public var label: String {
        switch self {
        case .approval: return "Needs approval"
        case .question: return "Asked a question"
        case .done: return "Finished"
        case .error: return "Failed"
        }
    }
}

/// How confident the status is — used to keep inferred states from outranking
/// facts during triage, and to explain the status in the UI.
public enum StatusEvidence: String, Codable, Sendable {
    /// A hook told us explicitly.
    case hook
    /// The audit log recorded a `SessionEnd` — the run is definitively over.
    case sessionEnd
    /// Derived from the age of the last audit-log event for this session.
    case auditActivity
    /// Derived from transcript file modification time — the weakest signal.
    case fileActivity
    /// Nothing usable.
    case none

    /// Lower is stronger.
    public var strength: Int {
        switch self {
        case .hook: return 0
        case .sessionEnd: return 1
        case .auditActivity: return 2
        case .fileActivity: return 3
        case .none: return 4
        }
    }
}
