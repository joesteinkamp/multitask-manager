import Foundation
import Testing
@testable import MultiTaskCore

/// The menu bar answers one question — is anything waiting on me — and the
/// precedence below is how it picks which single thing to say.
@Suite("What the menu bar says")
struct BarStateTests {
    let now = Date(timeIntervalSince1970: 1_755_252_000)

    private func snapshot(needsYou: Int = 0, working: Int = 0,
                          complete: Int = 0, approvals: Int = 0) -> EngineSnapshot {
        var snapshot = EngineSnapshot()
        snapshot.projects = (0..<needsYou).map { index in
            Project(record: ProjectRecord(id: "p\(index)", name: "p\(index)", path: "/p\(index)"),
                    status: .needsYou, statusReason: "", lastActivity: now)
        }
        snapshot.sessions =
            (0..<working).map { index in
                var session = Session.stub(id: "w\(index)", lastActivity: now)
                session.status = .working
                return session
            }
            + (0..<complete).map { index in
                var session = Session.stub(id: "c\(index)", lastActivity: now)
                session.status = .complete
                return session
            }
        // Requested *now*, not at the suite's fixed instant: an approval expires
        // 24 hours after it was made, measured against the real clock, so a
        // fixture stamped with a constant from last year is already expired and
        // would silently never count.
        snapshot.approvals = (0..<approvals).map { index in
            ApprovalRequest(id: "a\(index)", kind: .run, summary: "Run it",
                            details: [], requestedBy: "codex", requestedAt: Date())
        }
        return snapshot
    }

    @Test("Silence is the default, and is a state rather than an absence")
    func calm() {
        #expect(snapshot().barState == .calm)
        // No count: a number here would be a count of nothing.
        #expect(snapshot().barState.count == nil)
        #expect(snapshot().barState.deservesColour == false)
    }

    @Test("Work in flight is shown, and counted in sessions")
    func working() {
        // Three agents in one project is three things happening.
        #expect(snapshot(working: 3).barState == .working(3))
        #expect(snapshot(working: 3).barState.count == 3)
        // Shown, but never coloured — it asks nothing of you.
        #expect(snapshot(working: 3).barState.deservesColour == false)
    }

    @Test("Something blocked on you outranks everything else")
    func needsYouWins() {
        let busy = snapshot(needsYou: 1, working: 5, complete: 2)
        #expect(busy.barState == .needsYou(1))
        #expect(busy.barState.deservesColour)
    }

    @Test("An agent's request counts as blocked on you")
    func approvalsCount() {
        // An ask is exactly the case the colour exists for: an agent is stopped
        // until you answer.
        #expect(snapshot(approvals: 2).barState == .needsYou(2))
        #expect(snapshot(needsYou: 1, approvals: 2).barState == .needsYou(3))
    }

    @Test("Work in flight outranks work already finished")
    func workingOutranksComplete() {
        // Finished is a fact about the past; working is happening now.
        #expect(snapshot(working: 1, complete: 4).barState == .working(1))
    }

    @Test("Finished shows only when nothing is running, and carries no number")
    func complete() {
        #expect(snapshot(complete: 2).barState == .complete)
        // "2 finished" invites an action that is not there.
        #expect(snapshot(complete: 2).barState.count == nil)
        #expect(snapshot(complete: 2).barState.deservesColour == false)
    }

    @Test("Exactly one state may spend colour")
    func onlyOneStateIsColoured() {
        // The rule the whole design rests on: if more than one state is
        // coloured, a colourless bar stops meaning anything.
        let states: [BarState] = [.calm, .working(2), .complete, .needsYou(1)]
        #expect(states.filter(\.deservesColour) == [.needsYou(1)])
    }

    @Test("Archived projects do not light the bar")
    func archivedProjectsIgnored() {
        var snapshot = EngineSnapshot()
        var record = ProjectRecord(id: "old", name: "old", path: "/old")
        record.lifecycle = .archived
        snapshot.projects = [Project(record: record, status: .needsYou,
                                     statusReason: "", lastActivity: now)]
        // Archived means put away; it must not be able to interrupt.
        #expect(snapshot.barState == .calm)
    }
}
