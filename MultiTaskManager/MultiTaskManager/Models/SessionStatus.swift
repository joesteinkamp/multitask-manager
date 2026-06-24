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
