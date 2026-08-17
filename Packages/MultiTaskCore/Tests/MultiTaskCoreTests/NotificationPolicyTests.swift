import Foundation
import Testing
@testable import MultiTaskCore

@Suite("NotificationPolicy")
struct NotificationPolicyTests {
    let start = Fixtures.auditNow
    let config = Configuration()

    /// Drives the policy through `count` refreshes with the same sessions, five
    /// seconds apart — the app's default cadence.
    private func tick(_ policy: NotificationPolicy,
                      _ sessions: [Session],
                      count: Int = 1,
                      from offset: TimeInterval = 0,
                      config: Configuration? = nil,
                      muted: Set<String> = []) -> [PendingNotification] {
        var last: [PendingNotification] = []
        for i in 0..<count {
            last = policy.evaluate(sessions: sessions,
                                   configuration: config ?? self.config,
                                   mutedProjects: muted,
                                   now: start.addingTimeInterval(offset + Double(i) * 5))
        }
        return last
    }

    private func attention(_ id: String, project: String = "app", path: String? = "/p") -> Session {
        Session.stub(id: id, project: project, path: path, lastActivity: start, status: .needsAttention)
    }

    private func working(_ id: String) -> Session {
        Session.stub(id: id, lastActivity: start, status: .working)
    }

    @Test("The first evaluation only records state — no launch-time burst")
    func firstPassIsSilent() {
        let policy = NotificationPolicy()
        // Every quiet session on the machine is already needing attention at launch.
        let sessions = (1...5).map { attention("s\($0)") }
        #expect(tick(policy, sessions).isEmpty)
    }

    @Test("Fires once a crossing has held for two consecutive refreshes")
    func debounceRequiresTwoHolds() {
        let policy = NotificationPolicy()
        policy.prime(with: [working("s1")])

        #expect(tick(policy, [attention("s1")]).isEmpty)            // first hold
        let fired = tick(policy, [attention("s1")], from: 5)        // second hold
        #expect(fired.count == 1)
        #expect(fired[0].kind == .single(sessionId: "s1"))
    }

    @Test("A status that flaps back before the second refresh never notifies")
    func flappingIsSuppressed() {
        let policy = NotificationPolicy()
        policy.prime(with: [working("s1")])

        #expect(tick(policy, [attention("s1")]).isEmpty)       // one slow tool call
        #expect(tick(policy, [working("s1")], from: 5).isEmpty)  // …and it's back
        #expect(tick(policy, [attention("s1")], from: 10).isEmpty) // hold count restarted
    }

    @Test("A session that stays in attention doesn't re-notify every refresh")
    func firesOncePerEpisode() {
        let policy = NotificationPolicy()
        policy.prime(with: [working("s1")])

        _ = tick(policy, [attention("s1")])
        #expect(tick(policy, [attention("s1")], from: 5).count == 1)
        // Twenty more refreshes of the same state produce nothing further.
        #expect(tick(policy, [attention("s1")], count: 20, from: 10).isEmpty)
    }

    @Test("The cooldown blocks a second notification for the same session")
    func cooldownBlocksRepeat() {
        let policy = NotificationPolicy()
        policy.prime(with: [working("s1")])
        _ = tick(policy, [attention("s1")], count: 2)

        // Back to work, then quiet again — inside the 10-minute cooldown.
        _ = tick(policy, [working("s1")], from: 20)
        #expect(tick(policy, [attention("s1")], count: 2, from: 30).isEmpty)

        // Past the cooldown, the next episode notifies again.
        _ = tick(policy, [working("s1")], from: 700)
        #expect(tick(policy, [attention("s1")], count: 2, from: 710).count == 1)
    }

    @Test("Three or more crossings in one window collapse into a single summary")
    func coalescesBurst() throws {
        let policy = NotificationPolicy()
        let sessions = (1...4).map { attention("s\($0)") }
        policy.prime(with: (1...4).map { working("s\($0)") })

        _ = tick(policy, sessions)
        let fired = tick(policy, sessions, from: 5)

        #expect(fired.count == 1)
        let notification = try #require(fired.first)
        #expect(notification.title == "4 sessions need you")
        if case let .summary(ids) = notification.kind {
            #expect(ids.count == 4)
        } else {
            Issue.record("expected a summary, got \(notification.kind)")
        }
    }

    @Test("Two crossings stay as two individual notifications")
    func twoStayIndividual() {
        let policy = NotificationPolicy()
        policy.prime(with: [working("s1"), working("s2")])

        _ = tick(policy, [attention("s1"), attention("s2")])
        let fired = tick(policy, [attention("s1"), attention("s2")], from: 5)
        #expect(fired.count == 2)
        #expect(fired.allSatisfy { if case .single = $0.kind { return true } else { return false } })
    }

    @Test("A muted project never notifies")
    func muteSuppresses() {
        let policy = NotificationPolicy()
        policy.prime(with: [working("s1")])
        let fired = tick(policy, [attention("s1", path: "/muted")], count: 2, muted: ["/muted"])
        #expect(fired.isEmpty)
    }

    @Test("Notifications can be turned off wholesale")
    func disabledProducesNothing() {
        var off = config
        off.enableNotifications = false
        let policy = NotificationPolicy()
        policy.prime(with: [working("s1")])
        #expect(tick(policy, [attention("s1")], count: 3, config: off).isEmpty)
    }

    @Test("Entering idle never notifies")
    func idleNeverNotifies() {
        let policy = NotificationPolicy()
        policy.prime(with: [working("s1")])
        let idle = Session.stub(id: "s1", lastActivity: start, status: .idle)
        #expect(tick(policy, [idle], count: 5).isEmpty)
    }

    @Test("Quiet hours drop notifications rather than queueing them for 07:00")
    func quietHoursSuppress() {
        var quiet = config
        quiet.quietHoursStart = 22 * 60
        quiet.quietHoursEnd = 7 * 60

        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 15
        components.hour = 23; components.minute = 30
        let lateNight = Calendar.current.date(from: components)!

        let policy = NotificationPolicy()
        policy.prime(with: [working("s1")])
        _ = policy.evaluate(sessions: [attention("s1")], configuration: quiet, now: lateNight)
        let fired = policy.evaluate(sessions: [attention("s1")], configuration: quiet,
                                    now: lateNight.addingTimeInterval(5))
        #expect(fired.isEmpty)
    }

    @Test("A quiet-hours range that wraps past midnight is handled")
    func quietHoursWrap() {
        var quiet = config
        quiet.quietHoursStart = 22 * 60
        quiet.quietHoursEnd = 7 * 60

        func at(hour: Int, minute: Int = 0) -> Date {
            var c = DateComponents()
            c.year = 2026; c.month = 8; c.day = 15; c.hour = hour; c.minute = minute
            return Calendar.current.date(from: c)!
        }

        #expect(NotificationPolicy.isWithinQuietHours(now: at(hour: 23), configuration: quiet))
        #expect(NotificationPolicy.isWithinQuietHours(now: at(hour: 3), configuration: quiet))
        #expect(NotificationPolicy.isWithinQuietHours(now: at(hour: 12), configuration: quiet) == false)
        #expect(NotificationPolicy.isWithinQuietHours(now: at(hour: 21, minute: 59), configuration: quiet) == false)
    }

    @Test("A same-day quiet range doesn't wrap")
    func quietHoursSameDay() {
        var quiet = config
        quiet.quietHoursStart = 9 * 60
        quiet.quietHoursEnd = 17 * 60

        func at(hour: Int) -> Date {
            var c = DateComponents()
            c.year = 2026; c.month = 8; c.day = 15; c.hour = hour
            return Calendar.current.date(from: c)!
        }
        #expect(NotificationPolicy.isWithinQuietHours(now: at(hour: 12), configuration: quiet))
        #expect(NotificationPolicy.isWithinQuietHours(now: at(hour: 20), configuration: quiet) == false)
    }

    @Test("The body explains the wait when a hook said why")
    func bodyPrefersTheReason() {
        var session = attention("s1")
        session.waiting = .approval
        #expect(NotificationPolicy.body(for: session) == "Needs approval")

        session.reason = "Bash(rm -rf build/)"
        #expect(NotificationPolicy.body(for: session) == "Bash(rm -rf build/)")

        var bare = attention("s2")
        bare.lastToolName = "Edit"
        #expect(NotificationPolicy.body(for: bare) == "Quiet since Edit")
        #expect(NotificationPolicy.body(for: attention("s3")) == "Waiting for you")
    }
}

@Suite("AttentionTriage")
struct AttentionTriageTests {
    let now = Fixtures.auditNow

    private func waiting(_ id: String, _ reason: WaitingReason?, evidence: StatusEvidence = .hook,
                         ageSeconds: TimeInterval = 60, pinned: Bool = false) -> Session {
        Session.stub(id: id, lastActivity: now.addingTimeInterval(-ageSeconds),
                     waiting: reason, evidence: evidence,
                     status: .needsAttention, isPinned: pinned)
    }

    @Test("An approval gate outranks a question, which outranks a finished run")
    func waitingReasonOrder() {
        let ranked = AttentionTriage.rank([
            waiting("done", .done),
            waiting("question", .question),
            waiting("approval", .approval),
            waiting("error", .error)
        ], now: now)

        #expect(ranked.map(\.id) == ["approval", "error", "question", "done"])
    }

    @Test("Anything inferred sorts below everything a hook reported")
    func inferredSortsLast() {
        let ranked = AttentionTriage.rank([
            waiting("inferred", nil, evidence: .fileActivity),
            waiting("done", .done)
        ], now: now)
        #expect(ranked.map(\.id) == ["done", "inferred"])
    }

    @Test("Within a tier, a hook's word beats a guess")
    func evidenceBreaksTies() {
        let ranked = AttentionTriage.rank([
            waiting("guessed", nil, evidence: .fileActivity, ageSeconds: 600),
            waiting("known", nil, evidence: .sessionEnd, ageSeconds: 60)
        ], now: now)
        #expect(ranked.map(\.id) == ["known", "guessed"])
    }

    @Test("Otherwise the longest wait comes first")
    func longestWaitFirst() {
        let ranked = AttentionTriage.rank([
            waiting("recent", .done, ageSeconds: 30),
            waiting("stale", .done, ageSeconds: 3000)
        ], now: now)
        #expect(ranked.map(\.id) == ["stale", "recent"])
    }

    @Test("Pinning is worth one tier, not an override")
    func pinnedIsWorthOneTier() {
        // Pinned `question` (tier 2 → 1) climbs past unpinned `question`, but does
        // not jump an unpinned `approval` at tier 0.
        let ranked = AttentionTriage.rank([
            waiting("plain-question", .question),
            waiting("pinned-question", .question, pinned: true),
            waiting("approval", .approval)
        ], now: now)
        #expect(ranked.map(\.id) == ["approval", "pinned-question", "plain-question"])
    }

    @Test("Only sessions needing attention enter the queue")
    func filtersToWaiting() {
        let sessions = [
            Session.stub(id: "busy", lastActivity: now, status: .working),
            waiting("waiting", .approval),
            Session.stub(id: "asleep", lastActivity: now, status: .idle)
        ]
        #expect(AttentionTriage.waitingSessions(sessions, now: now).map(\.id) == ["waiting"])
    }

    @Test("Exact ties keep their input order so the list doesn't shuffle")
    func stableOrdering() {
        let sessions = (1...5).map { waiting("s\($0)", .done, ageSeconds: 60) }
        #expect(AttentionTriage.rank(sessions, now: now).map(\.id) == sessions.map(\.id))
    }
}
