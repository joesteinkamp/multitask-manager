import Foundation

/// What an ambient indicator should say, at a glance, without being opened.
///
/// One state, chosen by what would make you act soonest. **The precedence is the
/// design**: something blocked on you outranks work in flight, which outranks
/// work already finished, which outranks silence.
///
/// Lives in the core rather than the macOS app for two reasons: the rule is pure
/// and therefore testable, and the Windows client's taskbar has to answer exactly
/// the same question. A second implementation would answer it differently within
/// a month.
public enum BarState: Equatable, Sendable {
    /// Something is blocked on you. The only state permitted colour.
    case needsYou(Int)
    /// Agents are working. Shown, but in the bar's own ink — work in flight is
    /// news you are allowed to ignore.
    case working(Int)
    /// A run finished and nothing is running now.
    case complete
    /// Nothing running, nothing waiting. Deliberately indistinguishable from any
    /// other quiet utility: the absence of a signal is the signal.
    case calm

    /// The number to show beside the glyph, or `nil` where a count would say
    /// nothing.
    ///
    /// Never a count of things that merely exist — "3 finished" invites an
    /// action that is not there.
    public var count: Int? {
        switch self {
        case .needsYou(let count), .working(let count): return count
        case .complete, .calm: return nil
        }
    }

    /// Whether this state may spend colour. Exactly one may.
    public var deservesColour: Bool {
        if case .needsYou = self { return true }
        return false
    }
}

public extension EngineSnapshot {
    /// How many agents are working right now, across every project.
    ///
    /// Counted in *sessions*, unlike the attention count: three agents in one
    /// project is three things happening, and this number exists to say how much
    /// is in flight.
    var workingSessionCount: Int {
        sessions.filter { $0.status == .working }.count
    }

    var completeSessionCount: Int {
        sessions.filter { $0.status == .complete }.count
    }

    /// Projects blocked on a person, plus agents waiting on a decision.
    ///
    /// Projects rather than sessions here, because a project is what you act on
    /// — and an ask from an agent is its own kind of blocked.
    var needsYouCount: Int {
        activeProjects.filter { $0.status == .needsYou }.count + pendingApprovals.count
    }

    var barState: BarState {
        if needsYouCount > 0 { return .needsYou(needsYouCount) }
        if workingSessionCount > 0 { return .working(workingSessionCount) }
        if completeSessionCount > 0 { return .complete }
        return .calm
    }
}
