import Foundation

/// Decides *whether* a status change is worth interrupting the user for.
///
/// Deliberately free of `UserNotifications` — this is the part with the judgment
/// in it, and the part whose defaults decide whether the feature survives its
/// first day. `NotificationManager` does the delivery.
///
/// The heuristic that produces `needsAttention` flaps: one slow tool call crosses
/// the 45-second threshold and the next write crosses back. Firing on every
/// crossing would produce a notification storm on a busy day and teach the user
/// to ignore the app. So a crossing has to survive four filters before it
/// becomes an alert:
///
/// 1. **Edge, not level.** Only `working → needsAttention` and
///    `unknown → needsAttention` count. Entering `idle` never notifies — an idle
///    session isn't waiting on anyone.
/// 2. **Held across two consecutive refreshes.** Kills the flap.
/// 3. **Per-session cooldown.** One session can't nag.
/// 4. **Coalesced.** Three or more crossings inside a short window collapse into
///    one summary instead of a burst.
final class AttentionNotifier {
    struct Policy {
        /// How long before the same session may notify again.
        var cooldown: TimeInterval = 10 * 60
        /// Crossings inside this window are candidates for coalescing.
        var coalesceWindow: TimeInterval = 30
        /// This many crossings in the window collapse into one summary.
        var coalesceThreshold: Int = 3
        /// Refreshes the status must hold before an alert is emitted.
        var requiredConsecutiveRefreshes: Int = 2
    }

    enum Alert {
        case single(Session)
        case summary(count: Int, sessions: [Session])
    }

    var policy = Policy()

    private var previousStatus: [String: SessionStatus] = [:]
    private var attentionStreak: [String: Int] = [:]
    /// Sessions whose current `needsAttention` run began with a qualifying edge.
    private var edgeQualified: Set<String> = []
    private var lastNotified: [String: Date] = [:]
    private var recentCrossings: [Date] = []
    private var hasSeeded = false

    /// Folds one refresh into the notifier's state and returns what to deliver.
    ///
    /// - Parameters:
    ///   - sessions: the merged, classified list for this refresh.
    ///   - isMuted: per-project mute check, from `UserOverrides`.
    ///   - isQuiet: whether quiet hours are in effect right now.
    ///
    /// Bookkeeping advances even when nothing is delivered, so a session muted
    /// or silenced during quiet hours doesn't fire late once the reason lifts.
    func evaluate(
        sessions: [Session],
        now: Date = Date(),
        isMuted: (Session) -> Bool,
        isQuiet: Bool
    ) -> [Alert] {
        defer { recordStatuses(of: sessions, now: now) }

        // The first refresh is a baseline, not a set of transitions. Without
        // this, launching the app while three sessions sit quiet fires three
        // notifications for work the user already knows about.
        guard hasSeeded else {
            hasSeeded = true
            return []
        }

        var candidates: [Session] = []

        for session in sessions {
            guard session.status == .needsAttention else {
                attentionStreak[session.id] = 0
                edgeQualified.remove(session.id)
                continue
            }

            let prior = previousStatus[session.id]

            if prior == .needsAttention {
                attentionStreak[session.id, default: 0] += 1
            } else {
                attentionStreak[session.id] = 1
                // A session first seen already needing attention is almost
                // always an old transcript the detector just surfaced, not
                // something that just stopped. Live work always appears as
                // `working` first.
                if prior == .working || prior == .unknown {
                    edgeQualified.insert(session.id)
                } else {
                    edgeQualified.remove(session.id)
                }
            }

            // `== ` rather than `>=` so one crossing yields exactly one alert,
            // however long the session then sits there.
            guard edgeQualified.contains(session.id),
                  attentionStreak[session.id] == policy.requiredConsecutiveRefreshes
            else { continue }

            if let last = lastNotified[session.id],
               now.timeIntervalSince(last) < policy.cooldown { continue }
            if isMuted(session) { continue }

            candidates.append(session)
        }

        guard !candidates.isEmpty else { return [] }

        // Quiet hours drop the alert rather than queueing it: a 3 a.m. crossing
        // is not news at 8 a.m., and the badge carried it the whole time.
        guard !isQuiet else {
            for session in candidates { lastNotified[session.id] = now }
            return []
        }

        for session in candidates { lastNotified[session.id] = now }

        recentCrossings.removeAll { now.timeIntervalSince($0) > policy.coalesceWindow }
        recentCrossings.append(contentsOf: candidates.map { _ in now })

        if recentCrossings.count >= policy.coalesceThreshold {
            return [.summary(count: recentCrossings.count, sessions: candidates)]
        }
        return candidates.map { .single($0) }
    }

    /// Forgets everything. Used when the user turns notifications off and on
    /// again, so re-enabling doesn't replay a backlog of transitions.
    func reset() {
        previousStatus = [:]
        attentionStreak = [:]
        edgeQualified = []
        lastNotified = [:]
        recentCrossings = []
        hasSeeded = false
    }

    private func recordStatuses(of sessions: [Session], now: Date) {
        previousStatus = Dictionary(
            sessions.map { ($0.id, $0.status) },
            uniquingKeysWith: { _, latest in latest }
        )

        // Drop bookkeeping for sessions that no longer exist, but keep cooldowns
        // for a while — a session that disappears and comes straight back
        // shouldn't get a free notification.
        let live = Set(sessions.map(\.id))
        attentionStreak = attentionStreak.filter { live.contains($0.key) }
        edgeQualified.formIntersection(live)
        lastNotified = lastNotified.filter { now.timeIntervalSince($0.value) < policy.cooldown * 2 }
    }
}

/// A nightly window during which nothing is delivered.
enum QuietHours {
    /// Whether `date` falls inside `[start, end)`, both expressed as minutes
    /// from local midnight. Windows that wrap past midnight (22:00 → 07:00) are
    /// the normal case, not the edge case.
    static func isActive(
        at date: Date,
        startMinutes: Int,
        endMinutes: Int,
        calendar: Calendar = .current
    ) -> Bool {
        let start = normalize(startMinutes)
        let end = normalize(endMinutes)
        guard start != end else { return false }

        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)

        if start < end { return minutes >= start && minutes < end }
        return minutes >= start || minutes < end
    }

    private static func normalize(_ minutes: Int) -> Int {
        let day = 24 * 60
        return ((minutes % day) + day) % day
    }

    /// "22:00" for 1320.
    static func format(_ minutes: Int) -> String {
        let normalized = normalize(minutes)
        return String(format: "%02d:%02d", normalized / 60, normalized % 60)
    }
}
