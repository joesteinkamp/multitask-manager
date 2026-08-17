import Foundation

/// A notification the app should post. The policy decides *whether* and *what*;
/// the app owns `UNUserNotificationCenter` and the delivery.
public struct PendingNotification: Codable, Sendable, Equatable {
    public enum Kind: Codable, Sendable, Equatable {
        /// One session crossed into needing attention.
        case single(sessionId: String)
        /// Several crossed at once — one message instead of a burst.
        case summary(sessionIds: [String])
        /// An agent is asking permission to spend something.
        case approval(requestId: String)
    }

    public var kind: Kind
    public var title: String
    public var body: String
    /// Session to focus when the notification's "Open" action is used. For a
    /// summary this is the highest-priority one; for an approval there is no
    /// session, and the app opens its own popover instead.
    public var primarySessionId: String

    public init(kind: Kind, title: String, body: String, primarySessionId: String) {
        self.kind = kind
        self.title = title
        self.body = body
        self.primarySessionId = primarySessionId
    }

    /// Whether acting on this means answering a question rather than looking at
    /// something. Drives whether the app opens the popover or focuses a window.
    public var isDecision: Bool {
        if case .approval = kind { return true }
        return false
    }
}

/// Decides when a status change is worth interrupting the user for.
///
/// Kept as a pure, injectable-clock policy object rather than living inside the
/// notification-center plumbing, because the plumbing is the easy part: the thing
/// that decides whether this feature is useful or is uninstalled on day one is the
/// debounce and cooldown behaviour, and that only gets tuned if it can be tested.
///
/// The rules, in the order they are applied:
/// 1. **Edge only.** Fires on the transition *into* `needsAttention` from
///    `working` or `unknown`. Entering `idle` never fires, and a session that is
///    already needing attention doesn't re-fire every refresh.
/// 2. **Primed start.** The first evaluation after launch only records state.
///    Otherwise every quiet session on the machine notifies at once at startup.
/// 3. **Debounce.** The status must hold across two consecutive refreshes. The
///    mtime heuristic flaps — one slow tool call crosses the 45s threshold and the
///    next write crosses back — and an alert per flap is worse than no alerts.
/// 4. **Cooldown.** One notification per session per cooldown window.
/// 5. **Coalesce.** Three or more within 30 seconds become a single summary.
/// 6. **Mute and quiet hours.** Muted projects never notify; inside quiet hours
///    nothing is delivered, and nothing is queued for later either — a backlog
///    arriving at 07:00 is the burst this is trying to avoid.
public final class NotificationPolicy: @unchecked Sendable {
    /// Window in which repeated crossings coalesce into one summary.
    public static let coalesceWindow: TimeInterval = 30
    /// Consecutive refreshes a status must hold before it can notify.
    public static let requiredHolds = 2

    private let lock = NSLock()
    private var previousStatus: [String: SessionStatus] = [:]
    private var consecutiveHolds: [String: Int] = [:]
    private var lastNotifiedAt: [String: Date] = [:]
    private var recentNotifications: [Date] = []
    private var announcedApprovals: Set<String> = []
    private var primed = false

    public init() {}

    /// Records state without ever notifying — used to prime at launch.
    ///
    /// Approvals are primed too: relaunching the app should not re-announce a
    /// request that has been sitting in the queue since yesterday. It is still
    /// visible, and still counted; it just isn't news.
    public func prime(with sessions: [Session], approvals: [ApprovalRequest] = []) {
        lock.lock()
        defer { lock.unlock() }
        for session in sessions { previousStatus[session.id] = session.status }
        for request in approvals { announcedApprovals.insert(request.id) }
        primed = true
    }

    /// Notifications for agents' requests.
    ///
    /// None of the session rules apply here, and that is the point. A status
    /// heuristic flaps, so it needs holds and a cooldown; a request is a discrete
    /// event that either exists or doesn't. So this fires once per request, the
    /// first time it is seen, and never again — no debounce to sit through, since
    /// the whole cost of the delay is an agent doing nothing.
    ///
    /// Quiet hours are still respected. The request does not disappear or get
    /// queued for 07:00 — it stays in the popover and in the badge, which is the
    /// difference between a reminder and an alarm.
    public func evaluate(approvals: [ApprovalRequest],
                         configuration: Configuration,
                         now: Date = Date()) -> [PendingNotification] {
        lock.lock()
        defer { lock.unlock() }

        let pending = approvals.filter { $0.effectiveState(now: now) == .pending }
        defer {
            // Forget requests that have been decided, so the set cannot grow
            // without bound across a long-running app.
            let live = Set(pending.map(\.id))
            announcedApprovals = announcedApprovals.intersection(live)
            for request in pending { announcedApprovals.insert(request.id) }
        }

        guard primed else {
            primed = true
            return []
        }
        guard configuration.enableNotifications else { return [] }
        if Self.isWithinQuietHours(now: now, configuration: configuration) { return [] }

        let fresh = pending.filter { !announcedApprovals.contains($0.id) }
        guard !fresh.isEmpty else { return [] }

        if fresh.count >= 3 {
            return [PendingNotification(
                kind: .approval(requestId: fresh[0].id),
                title: "\(fresh.count) agents are waiting on you",
                body: fresh.prefix(3).map(\.requestedBy).joined(separator: ", "),
                primarySessionId: fresh[0].id
            )]
        }

        return fresh.map { request in
            PendingNotification(
                kind: .approval(requestId: request.id),
                title: "\(request.requestedBy) is asking you",
                body: request.summary,
                primarySessionId: request.id
            )
        }
    }

    /// - Parameters:
    ///   - sessions: the freshly merged session list.
    ///   - mutedProjects: project paths the user muted.
    /// - Returns: notifications to post, usually empty.
    public func evaluate(sessions: [Session],
                         configuration: Configuration,
                         mutedProjects: Set<String> = [],
                         now: Date = Date()) -> [PendingNotification] {
        lock.lock()
        defer { lock.unlock() }

        let currentIds = Set(sessions.map(\.id))
        defer {
            // Forget sessions that vanished so the maps don't grow forever.
            previousStatus = previousStatus.filter { currentIds.contains($0.key) }
            consecutiveHolds = consecutiveHolds.filter { currentIds.contains($0.key) }
            lastNotifiedAt = lastNotifiedAt.filter { currentIds.contains($0.key) }
            for session in sessions { previousStatus[session.id] = session.status }
        }

        guard primed else {
            primed = true
            return []
        }
        guard configuration.enableNotifications else { return [] }

        var eligible: [Session] = []

        for session in sessions {
            let previous = previousStatus[session.id] ?? .unknown

            guard session.status == .needsAttention else {
                consecutiveHolds[session.id] = 0
                continue
            }
            // Already-attending sessions keep their hold count but must have
            // crossed an edge at some point to be eligible at all.
            let crossed = previous == .working || previous == .unknown || previous == .needsAttention
            guard crossed else {
                consecutiveHolds[session.id] = 0
                continue
            }

            let holds = (consecutiveHolds[session.id] ?? 0) + 1
            consecutiveHolds[session.id] = holds
            guard holds == Self.requiredHolds else { continue }

            if let path = session.projectPath, mutedProjects.contains(path) { continue }
            if let last = lastNotifiedAt[session.id],
               now.timeIntervalSince(last) < configuration.notificationCooldown { continue }
            if Self.isWithinQuietHours(now: now, configuration: configuration) { continue }

            eligible.append(session)
        }

        guard !eligible.isEmpty else { return [] }

        recentNotifications.removeAll { now.timeIntervalSince($0) > Self.coalesceWindow }
        let wouldBeTotal = recentNotifications.count + eligible.count

        for session in eligible {
            lastNotifiedAt[session.id] = now
            recentNotifications.append(now)
        }

        let ranked = AttentionTriage.rank(eligible, now: now)

        if wouldBeTotal >= 3 {
            let ids = ranked.map(\.id)
            let primary = ranked[0]
            return [PendingNotification(
                kind: .summary(sessionIds: ids),
                title: "\(ids.count) sessions need you",
                body: ranked.prefix(3).map(\.projectName).joined(separator: ", "),
                primarySessionId: primary.id
            )]
        }

        return ranked.map { session in
            PendingNotification(
                kind: .single(sessionId: session.id),
                title: session.projectName,
                body: Self.body(for: session),
                primarySessionId: session.id
            )
        }
    }

    static func body(for session: Session) -> String {
        if let reason = session.reason, !reason.isEmpty { return reason }
        if let waiting = session.waiting { return waiting.label }
        if let tool = session.lastToolName { return "Quiet since \(tool)" }
        return "Waiting for you"
    }

    /// Quiet hours as minutes from midnight, local time. A range whose end is
    /// before its start wraps past midnight (22:00 → 07:00).
    static func isWithinQuietHours(now: Date, configuration: Configuration) -> Bool {
        guard let start = configuration.quietHoursStart,
              let end = configuration.quietHoursEnd,
              start != end else { return false }
        let components = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if start < end { return minutes >= start && minutes < end }
        return minutes >= start || minutes < end
    }
}
