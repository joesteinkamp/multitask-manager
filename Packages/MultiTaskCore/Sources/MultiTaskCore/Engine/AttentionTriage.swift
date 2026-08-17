import Foundation

/// Orders the sessions waiting on you, rather than just listing them.
///
/// A list of eight things needing attention is only marginally better than no list
/// at all — the useful question is which one to pick up first. The ordering is:
///
/// 1. **Why it's waiting.** An approval gate genuinely outranks a finished run: one
///    is *blocked* on you, the other is merely done. Only a v2 hook knows which,
///    which is why the hook contract had to come first.
/// 2. **How good the evidence is.** A hook saying "waiting for approval" outranks a
///    guess derived from a file going quiet, so inferred states can't jump the
///    queue ahead of facts.
/// 3. **How long it's been waiting.** Longest first — that's the one going stale.
///
/// Pinned projects get a one-tier boost rather than an absolute override: pinning
/// says "this matters more to me", not "show me finished runs ahead of blocked ones".
public enum AttentionTriage {
    /// Sort key for one session. Lower sorts first.
    public struct Priority: Comparable, Sendable {
        public var tier: Int
        public var evidenceStrength: Int
        /// Negated so that longer waits sort first.
        public var negatedWait: TimeInterval

        public static func < (lhs: Priority, rhs: Priority) -> Bool {
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            if lhs.evidenceStrength != rhs.evidenceStrength {
                return lhs.evidenceStrength < rhs.evidenceStrength
            }
            return lhs.negatedWait < rhs.negatedWait
        }
    }

    /// Tier assigned to a session with no `waiting` value — everything inferred
    /// from file activity sorts below everything a hook reported.
    static let inferredTier = WaitingReason.allCases.count

    public static func priority(_ session: Session, now: Date = Date()) -> Priority {
        let baseTier = session.waiting?.triageRank ?? inferredTier
        // Pinning is worth one tier, never more.
        let tier = session.isPinned ? max(0, baseTier - 1) : baseTier
        return Priority(
            tier: tier,
            evidenceStrength: session.evidence.strength,
            negatedWait: -now.timeIntervalSince(session.lastActivity)
        )
    }

    /// Sessions ordered most-urgent first. Input order breaks exact ties, so the
    /// result is stable across refreshes rather than shuffling under the cursor.
    public static func rank(_ sessions: [Session], now: Date = Date()) -> [Session] {
        sessions.enumerated()
            .sorted { lhs, rhs in
                let l = priority(lhs.element, now: now)
                let r = priority(rhs.element, now: now)
                if l != r { return l < r }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// The subset needing attention, ranked. What the popover's triage list shows.
    public static func waitingSessions(_ sessions: [Session], now: Date = Date()) -> [Session] {
        rank(sessions.filter { $0.status == .needsAttention }, now: now)
    }
}
