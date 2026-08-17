import SwiftUI
import MultiTaskCore

/// Presentation for the core's semantic types.
///
/// These live here rather than on the types themselves because `MultiTaskCore`
/// imports Foundation only — a `Color` property on `SessionStatus` is what used
/// to make the models un-portable, and moving it out is what let the engine
/// build and test on Linux.
extension SessionStatus {
    var color: Color {
        switch self {
        case .working: return .green
        case .needsAttention: return .orange
        case .idle: return .secondary
        case .unknown: return .gray
        }
    }
}

extension ProjectStatus {
    var color: Color {
        switch self {
        case .needsYou: return .orange
        case .working: return .green
        case .ready: return .accentColor
        case .blocked: return .purple
        case .dormant: return .secondary
        case .unbriefed: return .gray
        }
    }

    var symbolName: String {
        switch self {
        case .needsYou: return "exclamationmark.circle.fill"
        case .working: return "circle.fill"
        case .ready: return "arrow.right.circle.fill"
        case .blocked: return "pause.circle.fill"
        case .dormant: return "moon.zzz.fill"
        case .unbriefed: return "questionmark.circle"
        }
    }
}

extension WaitingReason {
    var symbolName: String {
        switch self {
        case .approval: return "hand.raised.fill"
        case .question: return "questionmark.bubble.fill"
        case .done: return "checkmark.circle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

/// Formats activity timestamps as compact relative strings.
enum RelativeTime {
    static func string(from date: Date, status: SessionStatus) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        let elapsed = compact(seconds)
        switch status {
        case .needsAttention: return "waiting \(elapsed)"
        case .working: return seconds < 5 ? "now" : "\(elapsed) ago"
        default: return "\(elapsed) ago"
        }
    }

    static func ago(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        return seconds < 5 ? "just now" : "\(compact(seconds)) ago"
    }

    static func compact(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}
