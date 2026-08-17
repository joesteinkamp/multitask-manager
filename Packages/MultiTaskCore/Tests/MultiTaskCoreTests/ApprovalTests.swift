import Foundation
import Testing
@testable import MultiTaskCore

/// The approval queue is what lets agents write without letting them spend.
///
/// The direct token gate works because a person reads the description and a
/// person replays the token. Over MCP that assumption fails: an agent handed a
/// token can just call again with it. So agents ask, people decide, and these
/// tests pin the separation down.
@Suite("Approvals — agents ask, people decide")
struct ApprovalTests {

    private func engine(_ dir: TempDir) -> (InProcessEngine, TaskStore, ApprovalStore, String) {
        let projectStore = ProjectStore(directory: dir.url.appendingPathComponent("projects"))
        let taskStore = TaskStore(directory: dir.url.appendingPathComponent("tasks"))
        let runStore = RunStore(directory: dir.url.appendingPathComponent("runs"))
        let approvals = ApprovalStore(directory: dir.url.appendingPathComponent("approvals"))

        projectStore.save(ProjectRecord(id: "app-1", name: "app", path: dir.makeDirectory("app").path))

        let engine = InProcessEngine(
            configuration: StaticConfiguration(.fixtureOnly),
            engine: DetectionEngine(configuration: StaticConfiguration(.fixtureOnly),
                                    projectStore: projectStore, taskStore: taskStore),
            overridesStore: OverridesStore(directory: dir.url.appendingPathComponent("state")),
            taskStore: taskStore,
            decisions: DecisionLog(directory: dir.url),
            runStore: runStore,
            launcher: Launcher(runStore: runStore),
            auditWriter: AuditWriter(path: dir.path("audit.jsonl")),
            approvals: approvals
        )
        return (engine, taskStore, approvals, "app-1")
    }

    @Test("Asking files a request and starts nothing")
    func askingIsNotDoing() async throws {
        let dir = TempDir()
        let (engine, taskStore, approvals, projectId) = engine(dir)
        _ = try taskStore.save(TaskRecord(id: "t1", title: "Ship it", projectId: projectId,
                                          state: .ready, acceptance: "Signed"))

        let result = try await engine.act(.requestApproval(
            kind: "run", taskId: "t1", delegate: "claude",
            requestedBy: "codex", rationale: "the build is green"))

        let request = try #require(result.approval)
        #expect(request.state == .pending)
        #expect(request.requestedBy == "codex")
        #expect(request.rationale == "the build is green")
        // The person sees the same detail the direct gate would have shown them.
        #expect(request.details.contains { $0.contains("Signed") })
        #expect(await engine.runs().isEmpty)
        #expect(approvals.pending().count == 1)
    }

    @Test("A pending request shows up as something needing attention")
    func pendingRequestsSurface() async throws {
        let dir = TempDir()
        let (engine, taskStore, _, projectId) = engine(dir)
        _ = try taskStore.save(TaskRecord(id: "t1", title: "Ship it", projectId: projectId, state: .ready))

        let before = try await engine.list().needsAttentionCount
        _ = try await engine.act(.requestApproval(kind: "run", taskId: "t1", delegate: "claude",
                                                  requestedBy: "codex", rationale: nil))
        let snapshot = try await engine.list()

        // Carried on the snapshot, not somewhere you have to go looking: an ask
        // nobody notices is the same as no ask at all.
        #expect(snapshot.pendingApprovals.count == 1)
        #expect(snapshot.needsAttentionCount == before + 1)
    }

    @Test("Asking twice for the same thing does not queue it twice")
    func duplicateAsksCollapse() async throws {
        let dir = TempDir()
        let (engine, taskStore, approvals, projectId) = engine(dir)
        _ = try taskStore.save(TaskRecord(id: "t1", title: "Ship it", projectId: projectId, state: .ready))

        let first = try await engine.act(.requestApproval(kind: "run", taskId: "t1", delegate: "claude",
                                                          requestedBy: "codex", rationale: nil))
        let second = try await engine.act(.requestApproval(kind: "run", taskId: "t1", delegate: "claude",
                                                           requestedBy: "codex", rationale: nil))

        // A retrying agent must not turn one decision into a queue of identical
        // ones — that is how an approval list becomes something to dismiss.
        #expect(approvals.pending().count == 1)
        #expect(first.approval?.id == second.approval?.id)
    }

    @Test("Declining records the reason and starts nothing")
    func decliningIsRecorded() async throws {
        let dir = TempDir()
        let (engine, taskStore, _, projectId) = engine(dir)
        _ = try taskStore.save(TaskRecord(id: "t1", title: "Ship it", projectId: projectId, state: .ready))

        let asked = try await engine.act(.requestApproval(kind: "run", taskId: "t1", delegate: "claude",
                                                          requestedBy: "codex", rationale: nil))
        let id = try #require(asked.approval?.id)

        let decided = try await engine.act(.decideApproval(id: id, approve: false, note: "not this week"))

        #expect(decided.approval?.state == .denied)
        #expect(decided.approval?.note == "not this week")
        #expect(decided.approval?.decidedAt != nil)
        #expect(await engine.runs().isEmpty)
    }

    @Test("A decision can only be made once")
    func decisionsAreFinal() async throws {
        let dir = TempDir()
        let (engine, taskStore, _, projectId) = engine(dir)
        _ = try taskStore.save(TaskRecord(id: "t1", title: "Ship it", projectId: projectId, state: .ready))

        let asked = try await engine.act(.requestApproval(kind: "run", taskId: "t1", delegate: "claude",
                                                          requestedBy: "codex", rationale: nil))
        let id = try #require(asked.approval?.id)
        _ = try await engine.act(.decideApproval(id: id, approve: false, note: "no"))

        // Reversing a decline by approving afterwards would make the queue a
        // place where a second attempt beats the first answer.
        let again = try await engine.act(.decideApproval(id: id, approve: true, note: nil))
        #expect(again.ok == false)
        #expect(again.approval?.state == .denied)
        #expect(await engine.runs().isEmpty)
    }

    @Test("A request that aged out cannot be approved")
    func staleRequestsExpire() async throws {
        let dir = TempDir()
        let (engine, taskStore, approvals, projectId) = engine(dir)
        _ = try taskStore.save(TaskRecord(id: "t1", title: "Ship it", projectId: projectId, state: .ready))

        // Filed two days ago: the repository has moved and the person no longer
        // holds the context they would be agreeing to.
        let old = ApprovalRequest(
            id: "ask-old", kind: .run, summary: "Run “Ship it” with claude",
            details: [], requestedBy: "codex",
            requestedAt: Date().addingTimeInterval(-2 * 86_400),
            taskId: "t1", projectId: projectId, delegate: "claude")
        approvals.save(old)

        #expect(old.hasExpired())
        #expect(approvals.pending().isEmpty)      // not offered as a decision

        let attempt = try await engine.act(.decideApproval(id: "ask-old", approve: true, note: nil))
        #expect(attempt.ok == false)
        #expect(attempt.approval?.state == .expired)
        #expect(await engine.runs().isEmpty)
    }

    @Test("An unknown request is refused rather than invented")
    func unknownRequest() async throws {
        let dir = TempDir()
        let (engine, _, _, _) = engine(dir)
        await #expect(throws: (any Error).self) {
            _ = try await engine.act(.decideApproval(id: "ask-nope", approve: true, note: nil))
        }
    }

    @Test("Asking about a task with no project directory says so")
    func noDirectory() async throws {
        let dir = TempDir()
        let (engine, taskStore, approvals, _) = engine(dir)
        _ = try taskStore.save(TaskRecord(id: "t1", title: "Homeless", state: .ready))

        await #expect(throws: LaunchError.noWorkingDirectory) {
            _ = try await engine.act(.requestApproval(kind: "run", taskId: "t1", delegate: "claude",
                                                       requestedBy: "codex", rationale: nil))
        }
        #expect(approvals.pending().isEmpty)
    }

    @Test("An approval mints a token matching the request that was described")
    func approvalTokenMatchesWhatWasShown() async throws {
        let dir = TempDir()
        let (engine, taskStore, _, projectId) = engine(dir)
        _ = try taskStore.save(TaskRecord(id: "t1", title: "Ship it", projectId: projectId, state: .ready))

        let asked = try await engine.act(.requestApproval(kind: "run", taskId: "t1", delegate: "codex",
                                                          requestedBy: "claude", rationale: nil))
        let request = try #require(asked.approval)

        // The described command and the authorising token come from one builder,
        // so an approval can never authorise a run other than the one on screen.
        let described = try #require(request.details.first { $0.hasPrefix("Command:") })
        #expect(described.contains("codex"))
        #expect(request.delegate == "codex")
    }
}

/// Approving something that then fails to happen.
@Suite("Approvals — when the thing refuses to happen")
struct ApprovalFailureTests {

    @Test("An approval consumed by an attempt that failed stays pending")
    func failedApprovalStaysPending() async throws {
        let dir = TempDir()
        let projectStore = ProjectStore(directory: dir.url.appendingPathComponent("projects"))
        let taskStore = TaskStore(directory: dir.url.appendingPathComponent("tasks"))
        let approvals = ApprovalStore(directory: dir.url.appendingPathComponent("approvals"))
        let runStore = RunStore(directory: dir.url.appendingPathComponent("runs"))

        // A directory that is not a git repository, so provisioning cannot work.
        projectStore.save(ProjectRecord(id: "app-1", name: "app", path: dir.makeDirectory("app").path))

        let engine = InProcessEngine(
            configuration: StaticConfiguration(.fixtureOnly),
            engine: DetectionEngine(configuration: StaticConfiguration(.fixtureOnly),
                                    projectStore: projectStore, taskStore: taskStore),
            overridesStore: OverridesStore(directory: dir.url.appendingPathComponent("state")),
            taskStore: taskStore,
            decisions: DecisionLog(directory: dir.url),
            runStore: runStore,
            launcher: Launcher(runStore: runStore),
            auditWriter: AuditWriter(path: dir.path("audit.jsonl")),
            approvals: approvals
        )
        _ = try taskStore.save(TaskRecord(id: "t1", title: "Ship it", projectId: "app-1", state: .ready))

        let asked = try await engine.act(.requestApproval(kind: "provision", taskId: "t1",
                                                          delegate: "gemini",
                                                          requestedBy: "codex", rationale: nil))
        let id = try #require(asked.approval?.id)

        await #expect(throws: (any Error).self) {
            _ = try await engine.act(.decideApproval(id: id, approve: true, note: nil))
        }

        // Still a live decision. An approval spent on something that never
        // happened would leave the person believing they had said yes, with
        // nothing running and nothing left to say yes to.
        #expect(approvals.request(id: id)?.state == .pending)
        #expect(approvals.pending().count == 1)
    }
}
