import Foundation
import Testing
@testable import MultiTaskCore

@Suite("TaskStore")
struct TaskStoreTests {
    let now = Fixtures.auditNow

    private func store() -> (TaskStore, TempDir) {
        let dir = TempDir()
        return (TaskStore(directory: dir.url), dir)
    }

    @Test("A task round-trips through its file, fields and body intact")
    func roundTrip() throws {
        let (store, dir) = store()
        let task = TaskRecord(
            id: "t1", title: "Wire the audit log", projectId: "app-1",
            assignee: .agent("claude"), state: .running, deps: [],
            acceptance: "mtm doctor reports precise joins",
            waiting: .approval, waitingReason: "Needs a signing cert",
            externalRef: "linear:ENG-412", origin: "claude:sess-9",
            claimedBy: "claude", leaseExpires: now.addingTimeInterval(1800),
            createdAt: now, updatedAt: now, sessions: ["s1", "s2"],
            body: "The outcome, in prose."
        )
        _ = try store.save(task, now: now)

        let loaded = try #require(store.load().first)
        #expect(loaded.title == "Wire the audit log")
        #expect(loaded.projectId == "app-1")
        #expect(loaded.assignee == .agent("claude"))
        #expect(loaded.state == .running)
        #expect(loaded.acceptance == "mtm doctor reports precise joins")
        #expect(loaded.waiting == .approval)
        #expect(loaded.waitingReason == "Needs a signing cert")
        #expect(loaded.externalRef == "linear:ENG-412")
        #expect(loaded.claimedBy == "claude")
        #expect(loaded.sessions == ["s1", "s2"])
        #expect(loaded.body == "The outcome, in prose.")
        _ = dir
    }

    @Test("Assignee survives every spelling an agent might write")
    func assigneeEncoding() {
        #expect(Assignee(encoded: "me") == .me)
        #expect(Assignee(encoded: "agent:codex") == .agent("codex"))
        // A bare delegate name is what a person or an agent will actually type.
        #expect(Assignee(encoded: "claude") == .agent("claude"))
        #expect(Assignee(encoded: "") == .unassigned)
        #expect(Assignee.agent("agy").encoded == "agent:agy")
        #expect(Assignee.me.isHuman)
        #expect(Assignee.agent("claude").isAgent)
    }

    @Test("A cycle is refused at write time, not discovered at scheduling time")
    func cycleRejected() throws {
        let (store, dir) = store()
        _ = try store.save(TaskRecord(id: "a", title: "A"), now: now)
        _ = try store.save(TaskRecord(id: "b", title: "B", deps: ["a"]), now: now)

        // a → b → a
        #expect(throws: TaskStoreError.self) {
            _ = try store.save(TaskRecord(id: "a", title: "A", deps: ["b"]), now: now)
        }
        // The rejected write left the store as it was.
        #expect(store.task(id: "a")?.deps.isEmpty == true)
        _ = dir
    }

    @Test("A dependency on a task that doesn't exist is refused")
    func unknownDependency() throws {
        let (store, dir) = store()
        #expect(throws: TaskStoreError.self) {
            _ = try store.save(TaskRecord(id: "a", title: "A", deps: ["ghost"]), now: now)
        }
        _ = dir
    }

    @Test("An empty title is refused")
    func emptyTitle() throws {
        let (store, dir) = store()
        #expect(throws: TaskStoreError.self) {
            _ = try store.save(TaskRecord(id: "a", title: "   "), now: now)
        }
        _ = dir
    }

    @Test("Upsert on an external reference updates rather than duplicating")
    func upsertIsIdempotent() throws {
        let (store, dir) = store()
        // The case that matters: an agent's sync sweep running a second time.
        _ = try store.upsert(TaskRecord(id: "x1", title: "Fix login", externalRef: "linear:ENG-1"), now: now)
        _ = try store.upsert(TaskRecord(id: "x2", title: "Fix login (renamed)", externalRef: "linear:ENG-1"), now: now)

        let all = store.load()
        #expect(all.count == 1)
        #expect(all[0].title == "Fix login (renamed)")
        #expect(all[0].id == "x1")   // keeps the original identity
        _ = dir
    }

    @Test("A re-sync with fewer fields must not erase what's already there")
    func upsertMerges() throws {
        let (store, dir) = store()
        // What a first sync, plus a person's edits, leaves on the board.
        _ = try store.save(TaskRecord(
            id: "x1", title: "Port to Windows", projectId: "app-1",
            assignee: .agent("codex"), state: .ready,
            acceptance: "mtm doctor reports the same joins",
            waiting: .approval, waitingReason: "needs a cert",
            snoozedUntil: now.addingTimeInterval(3600),
            externalRef: "linear:ENG-7", claimedBy: "codex",
            leaseExpires: now.addingTimeInterval(1800),
            body: "Notes a human wrote."
        ), now: now)

        // The tracker's second sweep knows only the title and the ref.
        let merged = try store.upsert(
            TaskRecord(id: "ignored", title: "Port to Windows", externalRef: "linear:ENG-7"),
            now: now
        )

        #expect(store.load().count == 1)
        #expect(merged.acceptance == "mtm doctor reports the same joins")
        #expect(merged.assignee == .agent("codex"))
        #expect(merged.projectId == "app-1")
        #expect(merged.body == "Notes a human wrote.")
        // Workflow state belongs to this board, not to the tracker.
        #expect(merged.claimedBy == "codex")
        #expect(merged.snoozedUntil != nil)
        #expect(merged.waiting == .approval)
        _ = dir
    }

    @Test("A re-sync never un-finishes work completed locally")
    func upsertKeepsDone() throws {
        let (store, dir) = store()
        var task = TaskRecord(id: "x1", title: "Fix login", state: .done, externalRef: "linear:ENG-1")
        _ = try store.save(task, now: now)

        // The tracker still says it's open; local completion wins.
        task = TaskRecord(id: "other", title: "Fix login", state: .ready, externalRef: "linear:ENG-1")
        let merged = try store.upsert(task, now: now)
        #expect(merged.state == .done)
        _ = dir
    }

    @Test("Any unique id prefix resolves, an ambiguous one doesn't")
    func prefixResolution() throws {
        let (store, dir) = store()
        _ = try store.save(TaskRecord(id: "20260817-alpha", title: "Alpha"), now: now)
        _ = try store.save(TaskRecord(id: "20260817-beta", title: "Beta"), now: now)

        #expect(store.resolve("20260817-a")?.title == "Alpha")
        #expect(store.resolve("20260817")?.title == nil)   // ambiguous
        #expect(store.resolve("Beta")?.id == "20260817-beta")
        _ = dir
    }

    @Test("Ids are readable and derived from the title")
    func identifiers() {
        let id = TaskRecord.identifier(title: "Notify when a session needs attention!", now: now)
        #expect(id.hasPrefix("20260815-"))
        #expect(id.contains("notify-when-a-session"))
        #expect(!id.contains("!"))
    }
}

@Suite("TaskQueue — what's ready")
struct TaskReadinessTests {
    let now = Fixtures.auditNow

    private func task(_ id: String, _ state: TaskState = .ready,
                      assignee: Assignee = .me, deps: [String] = [],
                      snoozed: Date? = nil, claimedBy: String? = nil,
                      lease: Date? = nil, updated: Date? = nil) -> TaskRecord {
        TaskRecord(id: id, title: id, assignee: assignee, state: state, deps: deps,
                   snoozedUntil: snoozed, claimedBy: claimedBy, leaseExpires: lease,
                   updatedAt: updated ?? now)
    }

    @Test("A task whose dependencies aren't done is not ready")
    func dependenciesGate() {
        let tasks = [task("a", .ready), task("b", .ready, deps: ["a"])]
        #expect(TaskQueue.ready(for: nil, tasks: tasks, now: now).map(\.id) == ["a"])
        #expect(TaskQueue.blocked(tasks: tasks, now: now).map(\.id) == ["b"])
    }

    @Test("Dependencies met means ready")
    func dependenciesCleared() {
        let tasks = [task("a", .done), task("b", .ready, deps: ["a"])]
        #expect(TaskQueue.ready(for: nil, tasks: tasks, now: now).map(\.id) == ["b"])
        #expect(TaskQueue.blocked(tasks: tasks, now: now).isEmpty)
    }

    @Test("A snoozed task is out of the way until its date")
    func snoozeHides() {
        let asleep = task("a", .ready, snoozed: now.addingTimeInterval(3600))
        let awake = task("b", .ready, snoozed: now.addingTimeInterval(-3600))
        let ready = TaskQueue.ready(for: nil, tasks: [asleep, awake], now: now)
        #expect(ready.map(\.id) == ["b"])
    }

    @Test("A live claim takes a task out of the queue; an expired one returns it")
    func claimsAndLeases() throws {
        let live = task("a", .running, claimedBy: "codex", lease: now.addingTimeInterval(600))
        let stale = task("b", .running, claimedBy: "codex", lease: now.addingTimeInterval(-600))

        #expect(live.hasLiveClaim(now: now))
        #expect(stale.hasLiveClaim(now: now) == false)

        // This is what stops a crashed agent stranding work in `running` forever.
        let reclaimed = TaskQueue.reclaimExpired([live, stale], now: now)
        #expect(reclaimed.map(\.id) == ["b"])
        #expect(reclaimed[0].state == .ready)
        #expect(reclaimed[0].claimedBy == nil)
    }

    @Test("Two agents can't claim the same task")
    func claimIsExclusive() throws {
        let held = try TaskQueue.claim(task("a"), by: "claude", now: now)
        #expect(held.state == .running)
        #expect(throws: TaskStoreError.self) {
            _ = try TaskQueue.claim(held, by: "codex", now: now)
        }
        // The same owner renewing its own claim is fine.
        #expect(throws: Never.self) {
            _ = try TaskQueue.claim(held, by: "claude", now: now)
        }
    }

    @Test("Work blocked on a human is never offered as available")
    func waitingIsNotReady() {
        // The bug this guards: an agent being handed something it cannot
        // finish, because the thing standing in the way is a person.
        var waiting = task("a")
        waiting.waiting = .approval
        waiting.waitingReason = "needs a cert"
        #expect(TaskQueue.ready(for: nil, tasks: [waiting], now: now).isEmpty)
        // It is still visible — just in the queue that says a human is needed.
        #expect(TaskQueue.needingAHuman(tasks: [waiting], now: now).count == 1)
    }

    @Test("Filtering by assignee separates the two queues")
    func assigneeFilter() {
        let tasks = [task("mine", assignee: .me), task("theirs", assignee: .agent("claude"))]
        #expect(TaskQueue.ready(for: .me, tasks: tasks, now: now).map(\.id) == ["mine"])
        #expect(TaskQueue.ready(for: .agent("claude"), tasks: tasks, now: now).map(\.id) == ["theirs"])
        #expect(TaskQueue.ready(for: nil, tasks: tasks, now: now).count == 2)
    }
}

@Suite("TaskQueue — what to do next")
struct WhatNextTests {
    let now = Fixtures.auditNow

    private func task(_ id: String, deps: [String] = [], state: TaskState = .ready,
                      project: String? = nil, daysOld: Double = 0) -> TaskRecord {
        TaskRecord(id: id, title: id, projectId: project, assignee: .me, state: state,
                   deps: deps, updatedAt: now.addingTimeInterval(-daysOld * 86_400))
    }

    @Test("Unblocking someone else beats starting something new")
    func unblockingWins() throws {
        // `old` has sat longer, but `blocker` frees two other tasks.
        let tasks = [
            task("blocker"),
            task("old", daysOld: 30),
            task("waiter1", deps: ["blocker"]),
            task("waiter2", deps: ["blocker"])
        ]
        let next = TaskQueue.next(for: .me, tasks: tasks, now: now)
        let first = try #require(next.first)
        #expect(first.task.id == "blocker")
        #expect(first.unblocks == 2)
        #expect(first.reason == "Unblocks 2 other tasks")
    }

    @Test("Work already in progress beats work not yet begun")
    func resumeBeatsStart() throws {
        let tasks = [task("fresh"), task("started", state: .running, daysOld: 1)]
        let next = TaskQueue.next(for: .me, tasks: tasks, now: now)
        #expect(next.first?.task.id == "started")
        #expect(next.first?.reason == "Already in progress")
    }

    @Test("A pinned project's work sorts above an equal peer")
    func pinnedWins() throws {
        let tasks = [task("other", project: "p2"), task("pinned", project: "p1")]
        let next = TaskQueue.next(for: .me, tasks: tasks, pinnedProjectIds: ["p1"], now: now)
        #expect(next.first?.task.id == "pinned")
        #expect(next.first?.reason == "In a pinned project")
    }

    @Test("Otherwise the thing going stale comes first, and says how long")
    func oldestLast() throws {
        let tasks = [task("recent", daysOld: 0), task("stale", daysOld: 6)]
        let next = TaskQueue.next(for: .me, tasks: tasks, now: now)
        #expect(next.first?.task.id == "stale")
        #expect(next.first?.reason == "Ready for 6 days")
    }

    @Test("Blocked work never appears in the answer")
    func blockedExcluded() {
        let tasks = [task("open"), task("blocked", deps: ["open"])]
        #expect(TaskQueue.next(for: .me, tasks: tasks, now: now).map(\.task.id) == ["open"])
    }

    @Test("Tasks waiting on a human are ordered by why, then by how long")
    func humanQueueOrdering() {
        var approval = task("approval")
        approval.waiting = .approval
        approval.updatedAt = now
        var done = task("done-task")
        done.waiting = .done
        done.updatedAt = now.addingTimeInterval(-10_000)
        var question = task("question")
        question.waiting = .question
        question.updatedAt = now

        let queue = TaskQueue.needingAHuman(tasks: [done, question, approval], now: now)
        // Approval outranks a question, which outranks a merely finished run —
        // even though the finished one has waited far longer.
        #expect(queue.map(\.id) == ["approval", "question", "done-task"])
    }

    @Test("A snoozed task stops being a request until it's due")
    func snoozedNotRequested() {
        var waiting = task("a")
        waiting.waiting = .approval
        waiting.snoozedUntil = now.addingTimeInterval(3600)
        #expect(TaskQueue.needingAHuman(tasks: [waiting], now: now).isEmpty)
    }

    @Test("Limit truncates without changing the order")
    func limitRespected() {
        let tasks = (1...5).map { task("t\($0)", daysOld: Double($0)) }
        let all = TaskQueue.next(for: .me, tasks: tasks, now: now)
        let capped = TaskQueue.next(for: .me, tasks: tasks, now: now, limit: 2)
        #expect(capped.count == 2)
        #expect(capped.map(\.task.id) == Array(all.map(\.task.id).prefix(2)))
    }
}

@Suite("Tasks through the engine")
struct TaskEngineTests {

    private func engine(_ dir: TempDir) -> InProcessEngine {
        InProcessEngine(
            configuration: StaticConfiguration(.fixtureOnly),
            engine: DetectionEngine(
                configuration: StaticConfiguration(.fixtureOnly),
                projectStore: ProjectStore(directory: dir.url.appendingPathComponent("projects")),
                taskStore: TaskStore(directory: dir.url.appendingPathComponent("tasks"))
            ),
            overridesStore: OverridesStore(directory: dir.url.appendingPathComponent("state")),
            taskStore: TaskStore(directory: dir.url.appendingPathComponent("tasks"))
        )
    }

    @Test("Creating a task through the engine puts it in the snapshot")
    func createShowsUp() async throws {
        let dir = TempDir()
        let engine = engine(dir)

        let result = try await engine.act(.createTask(.init(
            title: "Write DESIGN.json",
            acceptance: "Both UIs generate from one file",
            state: "ready"
        )))
        let snapshot = try #require(result.snapshot)
        #expect(snapshot.tasks.count == 1)
        #expect(snapshot.tasks[0].acceptance == "Both UIs generate from one file")
    }

    @Test("A partial update leaves untouched fields alone")
    func updateIsPartial() async throws {
        let dir = TempDir()
        let engine = engine(dir)
        let created = try await engine.act(.createTask(.init(title: "A", acceptance: "keep me")))
        let id = try #require(created.snapshot?.tasks.first?.id)

        let updated = try await engine.act(.updateTask(.init(taskId: id, state: "running")))
        let task = try #require(updated.snapshot?.tasks.first)
        #expect(task.state == .running)
        // A caller that knows about one field must not erase the others.
        #expect(task.acceptance == "keep me")
        #expect(task.title == "A")
    }

    @Test("Completing clears the wait, so the project stops asking for you")
    func completeClearsWaiting() async throws {
        let dir = TempDir()
        let engine = engine(dir)
        let created = try await engine.act(.createTask(.init(title: "Needs a cert")))
        let id = try #require(created.snapshot?.tasks.first?.id)

        _ = try await engine.act(.updateTask(.init(taskId: id, waiting: "approval",
                                                   waitingReason: "signing cert")))
        var snapshot = try #require(try await engine.act(.refresh).snapshot)
        #expect(snapshot.tasksNeedingYou().count == 1)

        _ = try await engine.act(.completeTask(taskId: id, note: "Cert installed."))
        snapshot = try #require(try await engine.act(.refresh).snapshot)
        #expect(snapshot.tasksNeedingYou().isEmpty)
        #expect(snapshot.tasks[0].state == .done)
        #expect(snapshot.tasks[0].body.contains("Cert installed."))
    }

    @Test("A task can be claimed by an agent and shows as running")
    func claimThroughEngine() async throws {
        let dir = TempDir()
        let engine = engine(dir)
        let created = try await engine.act(.createTask(.init(title: "Port to Windows", state: "ready")))
        let id = try #require(created.snapshot?.tasks.first?.id)

        let claimed = try await engine.act(.claimTask(taskId: id, owner: "codex"))
        let task = try #require(claimed.snapshot?.tasks.first)
        #expect(task.state == .running)
        #expect(task.claimedBy == "codex")
        #expect(task.hasLiveClaim(now: Date()))
    }

    @Test("Snoozing removes it from the answer until it's due")
    func snoozeThroughEngine() async throws {
        let dir = TempDir()
        let engine = engine(dir)
        let created = try await engine.act(.createTask(.init(title: "Later", assignee: "me", state: "ready")))
        let id = try #require(created.snapshot?.tasks.first?.id)
        #expect(created.snapshot?.whatNext(for: .me).count == 1)

        let snoozed = try await engine.act(.snoozeTask(taskId: id, days: 3))
        #expect(snoozed.snapshot?.whatNext(for: .me).isEmpty == true)
    }

    @Test("An unknown task id fails loudly rather than silently")
    func unknownTask() async throws {
        let dir = TempDir()
        let engine = engine(dir)
        await #expect(throws: TaskStoreError.self) {
            _ = try await engine.act(.completeTask(taskId: "nope", note: nil))
        }
    }
}

@Suite("Project status, with real tasks")
struct ProjectStatusWithTasksTests {
    let now = Fixtures.auditNow

    private func verdict(tasks: [TaskRecord], nextSteps: Int = 0) -> ProjectAssembler.StatusVerdict {
        var briefs = BriefSet()
        briefs.product = true
        return ProjectAssembler.status(
            record: ProjectRecord(id: "p", name: "app", path: "/p", createdAt: now),
            sessions: [], tasks: tasks, repository: nil, briefs: briefs,
            nextStepCount: nextSteps, lastActivity: now, now: now
        )
    }

    @Test("A task waiting on a human makes the project need you, with the reason")
    func waitingTaskSurfaces() {
        var task = TaskRecord(id: "t", title: "Ship", state: .ready)
        task.waiting = .approval
        task.waitingReason = "Needs a signing cert"

        let result = verdict(tasks: [task])
        #expect(result.status == .needsYou)
        #expect(result.reason.contains("Needs a signing cert"))
    }

    @Test("Ready tasks make the project ready, and count whose they are")
    func readyTasksCount() {
        let tasks = [
            TaskRecord(id: "a", title: "A", assignee: .me, state: .ready),
            TaskRecord(id: "b", title: "B", assignee: .agent("codex"), state: .ready)
        ]
        let result = verdict(tasks: tasks)
        #expect(result.status == .ready)
        #expect(result.reason == "2 ready, 1 yours")
    }

    @Test("All work blocked reads as blocked, not as ready")
    func blockedProject() {
        // `a` is held by an agent with a live lease, so it isn't yours to resume;
        // `b` waits on `a`. Nothing here is startable by anyone.
        var claimed = TaskRecord(id: "a", title: "A", state: .running)
        claimed.claimedBy = "codex"
        claimed.leaseExpires = now.addingTimeInterval(1800)

        let result = verdict(tasks: [claimed, TaskRecord(id: "b", title: "B", state: .ready, deps: ["a"])])
        #expect(result.status == .blocked)
        #expect(result.reason.contains("waiting on dependencies"))
    }

    @Test("A running task you left is resumable, not blocked")
    func resumableIsReady() {
        // The counterpart to the case above: nobody holds it, so it's the most
        // available work in the project rather than an obstacle.
        let result = verdict(tasks: [TaskRecord(id: "a", title: "A", assignee: .me, state: .running)])
        #expect(result.status == .ready)
    }

    @Test("Real tasks take precedence over roadmap checkboxes")
    func tasksBeatRoadmap() {
        let tasks = [TaskRecord(id: "a", title: "A", assignee: .me, state: .ready)]
        let result = verdict(tasks: tasks, nextSteps: 9)
        #expect(result.reason.contains("task"))       // not "9 items ready to pick up"
        #expect(!result.reason.contains("9 items"))
    }
}

@Suite("DecisionLog")
struct DecisionLogTests {
    let now = Fixtures.auditNow

    @Test("Records why, and reads back most recent first")
    func recordAndRead() {
        let dir = TempDir()
        let log = DecisionLog(directory: dir.url)

        log.record(.taskCreated, "Filed \"Ship the build\"", taskId: "t1", at: now)
        log.record(.taskEscalated, "\"Ship the build\" needs a human: no signing cert",
                   taskId: "t1", at: now.addingTimeInterval(60))

        let recent = log.recent()
        #expect(recent.count == 2)
        #expect(recent[0].category == .taskEscalated)
        #expect(recent[0].summary.contains("no signing cert"))
    }

    @Test("Filters by project, so one project's history is readable on its own")
    func filterByProject() {
        let dir = TempDir()
        let log = DecisionLog(directory: dir.url)
        log.record(.taskCreated, "A", projectId: "p1", at: now)
        log.record(.taskCreated, "B", projectId: "p2", at: now)

        #expect(log.recent(projectId: "p1").map(\.summary) == ["A"])
    }

    @Test("A corrupt line is skipped, not fatal")
    func corruptLineTolerated() throws {
        let dir = TempDir()
        let log = DecisionLog(directory: dir.url)
        log.record(.other, "good", at: now)

        let file = dir.url.appendingPathComponent("decisions.jsonl")
        let existing = try String(contentsOf: file, encoding: .utf8)
        try (existing + "{ not json\n").write(to: file, atomically: true, encoding: .utf8)

        #expect(log.recent().map(\.summary) == ["good"])
    }

    @Test("Pruning drops what has outlived its usefulness as narration")
    func pruning() {
        let dir = TempDir()
        let log = DecisionLog(directory: dir.url)
        log.record(.other, "ancient", at: now.addingTimeInterval(-200 * 86_400))
        log.record(.other, "recent", at: now)

        log.prune(now: now)
        #expect(log.recent().map(\.summary) == ["recent"])
    }

    @Test("The engine narrates the decisions it takes, and only those")
    func engineNarrates() async throws {
        let dir = TempDir()
        let taskStore = TaskStore(directory: dir.url.appendingPathComponent("tasks"))
        let log = DecisionLog(directory: dir.url)
        let engine = InProcessEngine(
            configuration: StaticConfiguration(.fixtureOnly),
            engine: DetectionEngine(configuration: StaticConfiguration(.fixtureOnly),
                                    projectStore: ProjectStore(directory: dir.url.appendingPathComponent("p")),
                                    taskStore: taskStore),
            overridesStore: OverridesStore(directory: dir.url.appendingPathComponent("s")),
            taskStore: taskStore,
            decisions: log
        )

        let created = try await engine.act(.createTask(.init(title: "Ship it", state: "ready")))
        let id = try #require(created.snapshot?.tasks.first?.id)

        // A plain state change is mechanical — it must NOT be narrated.
        _ = try await engine.act(.updateTask(.init(taskId: id, state: "running")))
        // An escalation is a decision.
        _ = try await engine.act(.updateTask(.init(taskId: id, waiting: "approval",
                                                    waitingReason: "no cert")))
        _ = try await engine.act(.completeTask(taskId: id, note: nil))

        let entries = log.recent()
        let categories = entries.map(\.category)
        #expect(categories.contains(.taskCreated))
        #expect(categories.contains(.taskEscalated))
        #expect(categories.contains(.taskCompleted))
        // Three decisions, not four: the state tick produced no line.
        #expect(entries.count == 3)
        #expect(entries.first { $0.category == .taskEscalated }?.summary.contains("no cert") == true)
    }
}
