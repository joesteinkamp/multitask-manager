import SwiftUI

/// High-level state of a tracked session, derived from activity signals.
enum SessionStatus: String, Codable, CaseIterable {
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
    var sortRank: Int {
        switch self {
        case .needsAttention: return 0
        case .working: return 1
        case .idle: return 2
        case .unknown: return 3
        }
    }

    var color: Color {
        switch self {
        case .working: return .green
        case .needsAttention: return .orange
        case .idle: return .secondary
        case .unknown: return .gray
        }
    }

    /// SF Symbol used for the per-row status dot.
    var symbolName: String {
        switch self {
        case .working: return "circle.fill"
        case .needsAttention: return "exclamationmark.circle.fill"
        case .idle: return "moon.zzz.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    var label: String {
        switch self {
        case .working: return "Working"
        case .needsAttention: return "Needs attention"
        case .idle: return "Idle"
        case .unknown: return "Unknown"
        }
    }
}

/// *Why* a session is waiting, when a v2 hook record says so.
///
/// Only the hook knows the difference between "stopped at an approval gate" and
/// "finished the job" — the mtime heuristic sees the same silence either way.
/// `triageRank` is what makes that distinction actionable: an approval gate is
/// blocking a running agent, a question is blocking a decision, and a finished
/// run is merely waiting to be noticed.
enum WaitingKind: String, Codable, CaseIterable, Hashable {
    /// Stopped at a permission gate — an agent is blocked right now.
    case approval
    /// Asked the user something and is waiting on the answer.
    case question
    /// Finished its work; nothing is blocked, but it's done.
    case done
    /// Stopped because something failed.
    case error

    /// Lower sorts first. Consumed by P3.5's attention triage.
    var triageRank: Int {
        switch self {
        case .approval: return 0
        case .error: return 1
        case .question: return 2
        case .done: return 3
        }
    }

    var label: String {
        switch self {
        case .approval: return "Waiting for approval"
        case .question: return "Asked a question"
        case .done: return "Finished"
        case .error: return "Stopped with an error"
        }
    }

    var symbolName: String {
        switch self {
        case .approval: return "hand.raised.fill"
        case .question: return "questionmark.bubble.fill"
        case .done: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    /// Sentence used as a notification body when the hook supplied no `reason`.
    var notificationBody: String {
        switch self {
        case .approval: return "Waiting for your approval to continue."
        case .question: return "Asked you a question and is waiting."
        case .done: return "Finished — ready for you to look at."
        case .error: return "Stopped with an error."
        }
    }

    /// Tolerant parse: hooks are shell scripts written by hand, so accept the
    /// obvious spellings rather than only the canonical one.
    static func parse(_ raw: String?) -> WaitingKind? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "approval", "permission", "gate", "approve":
            return .approval
        case "question", "ask", "input", "prompt":
            return .question
        case "done", "finished", "complete", "completed", "stop":
            return .done
        case "error", "failed", "failure", "fail":
            return .error
        default:
            return nil
        }
    }
}
