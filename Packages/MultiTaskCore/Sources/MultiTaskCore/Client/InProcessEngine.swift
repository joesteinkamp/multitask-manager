import Foundation

/// Runs the detection engine inside the calling process.
///
/// This is the conformance that makes the daemon optional. The app and `mtm`
/// both talk to `EngineClient`, so a machine with no `mtmd` installed — or one
/// whose daemon just died — loses only the shared-state and cold-start benefits,
/// never the feature.
///
/// It owns three things a bare `DetectionEngine` doesn't: the refresh loop, the
/// user overrides, and the notification policy. The policy lives here rather than
/// in the UI on purpose — it is stateful (it remembers what it already told you
/// about), so two evaluators would double-notify. The engine decides; the app
/// delivers.
public actor InProcessEngine: EngineClient {
    private let configurationProvider: ConfigurationProviding
    private let engine: DetectionEngine
    private let overridesStore: OverridesStore
    private let taskStore: TaskStore
    private let decisions: DecisionLog
    private let policy: NotificationPolicy

    private var overrides: UserOverrides
    private var latest: EngineSnapshot?
    private var refreshTask: Task<Void, Never>?
    private var subscribers: [String: AsyncStream<EngineEvent>.Continuation] = [:]

    public init(configuration: ConfigurationProviding = StaticConfiguration(),
                engine: DetectionEngine? = nil,
                overridesStore: OverridesStore = OverridesStore(),
                taskStore: TaskStore = TaskStore(),
                decisions: DecisionLog = DecisionLog(),
                policy: NotificationPolicy = NotificationPolicy()) {
        self.configurationProvider = configuration
        self.engine = engine ?? DetectionEngine(configuration: configuration)
        self.overridesStore = overridesStore
        self.taskStore = taskStore
        self.decisions = decisions
        self.policy = policy
        self.overrides = overridesStore.load()
    }

    // MARK: Lifecycle

    /// Begins refreshing on the configured cadence.
    ///
    /// Uses a cancellable `Task` rather than a `Timer` so it needs no run loop —
    /// which is what lets the same code serve a menu-bar app, a one-shot CLI
    /// command, and eventually a headless daemon.
    public func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshNow()
                let interval = await self.configuration.refreshInterval
                try? await Task.sleep(nanoseconds: UInt64(max(1, interval) * 1_000_000_000))
            }
        }
    }

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    deinit {
        refreshTask?.cancel()
    }

    private var configuration: Configuration { configurationProvider.configuration }

    // MARK: EngineClient

    public func list(_ query: SessionQuery) async throws -> EngineSnapshot {
        var snapshot: EngineSnapshot
        if query.refresh || latest == nil {
            snapshot = await refreshNow()
        } else {
            snapshot = latest!
        }

        if query.waitingOnly {
            snapshot.sessions = AttentionTriage.waitingSessions(snapshot.sessions)
        }
        if let path = query.projectPath {
            snapshot.sessions = snapshot.sessions.filter { $0.projectPath == path }
            snapshot.waves = snapshot.waves.filter { $0.projectPath == path }
            snapshot.repositories = snapshot.repositories.filter { $0.path == path }
        }
        return snapshot
    }

    public func get(sessionId: String) async throws -> Session? {
        let snapshot = await currentSnapshot()
        return snapshot.sessions.first { $0.id == sessionId }
    }

    public func health() async throws -> EngineHealth {
        let snapshot = await currentSnapshot()
        return EngineHealth(
            auditLogPath: snapshot.audit.path,
            auditRecordsRead: snapshot.audit.recordsRead,
            auditMalformedLines: snapshot.audit.malformedLines,
            auditSessionsIndexed: snapshot.audit.sessionsIndexed,
            preciseJoins: snapshot.audit.preciseJoins,
            sessionCount: snapshot.sessions.count,
            degraded: snapshot.degraded,
            lastRefresh: snapshot.refreshedAt == .distantPast ? nil : snapshot.refreshedAt
        )
    }

    public nonisolated func subscribe() -> AsyncStream<EngineEvent> {
        AsyncStream { continuation in
            let id = UUID().uuidString
            Task { await self.addSubscriber(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.removeSubscriber(id: id) }
            }
        }
    }

    @discardableResult
    public func act(_ action: EngineAction) async throws -> ActionResult {
        switch action {
        case .refresh:
            break

        case .hide(let sessionId):
            // A manual entry has nowhere to be hidden *to* — removing it deletes it,
            // which is what the app has always done.
            if overrides.manual.contains(where: { $0.id == sessionId }) {
                overrides.manual.removeAll { $0.id == sessionId }
            } else {
                overrides.hidden.insert(sessionId)
            }
            overrides.renames[sessionId] = nil
            overrides.pinned.remove(sessionId)

        case .unhide(let sessionId):
            overrides.hidden.remove(sessionId)

        case .clearHidden:
            overrides.hidden.removeAll()

        case .pin(let sessionId):
            overrides.pinned.insert(sessionId)

        case .unpin(let sessionId):
            overrides.pinned.remove(sessionId)

        case .rename(let sessionId, let title):
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ProtocolFault(.badParameters, "A session title can't be empty")
            }
            if let index = overrides.manual.firstIndex(where: { $0.id == sessionId }) {
                overrides.manual[index].title = trimmed
            } else {
                overrides.renames[sessionId] = trimmed
            }

        case .addManual(let title, let projectPath):
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ProtocolFault(.badParameters, "A session title can't be empty")
            }
            overrides.manual.append(Session(
                id: "manual:\(UUID().uuidString)",
                title: trimmed,
                projectName: trimmed,
                projectPath: projectPath,
                source: .manual,
                lastActivity: Date(),
                isManual: true
            ))

        case .removeManual(let sessionId):
            overrides.manual.removeAll { $0.id == sessionId }

        case .mute(let projectPath):
            overrides.mutedProjects.insert(projectPath)

        case .unmute(let projectPath):
            overrides.mutedProjects.remove(projectPath)

        // Task actions write to the task store rather than to overrides, and
        // return early so they don't trigger an overrides save.
        case .createTask(let fields):
            let created = try create(fields)
            decisions.record(.taskCreated, "Filed \"\(created.title)\"",
                             actor: fields.origin ?? "me",
                             projectId: created.projectId, taskId: created.id)
            return ActionResult(ok: true, snapshot: await refreshNow())

        case .updateTask(let fields):
            let before = taskStore.resolve(fields.taskId)
            let updated = try update(fields)
            // Narrate only what's worth reading back in three months: an
            // escalation and a reassignment are decisions; a state tick is not.
            if updated.waiting != nil, before?.waiting == nil {
                decisions.record(.taskEscalated,
                                 "\"\(updated.title)\" needs a human: \(updated.waitingReason ?? updated.waiting!.label)",
                                 projectId: updated.projectId, taskId: updated.id)
            } else if let assignee = fields.assignee, before?.assignee != updated.assignee {
                decisions.record(.taskAssigned, "\"\(updated.title)\" handed to \(assignee)",
                                 projectId: updated.projectId, taskId: updated.id)
            }
            return ActionResult(ok: true, snapshot: await refreshNow())

        case .claimTask(let taskId, let owner):
            guard let task = taskStore.resolve(taskId) else {
                throw TaskStoreError.notFound(taskId)
            }
            _ = try taskStore.save(TaskQueue.claim(task, by: owner))
            decisions.record(.taskAssigned, "\(owner) took \"\(task.title)\"",
                             actor: owner, projectId: task.projectId, taskId: task.id)
            return ActionResult(ok: true, snapshot: await refreshNow())

        case .completeTask(let taskId, let note):
            guard var task = taskStore.resolve(taskId) else {
                throw TaskStoreError.notFound(taskId)
            }
            task.state = .done
            task.claimedBy = nil
            task.leaseExpires = nil
            // Completing clears the wait — the thing a human was needed for is
            // finished, so it must stop counting against the project.
            task.waiting = nil
            task.waitingReason = nil
            if let note, !note.isEmpty {
                task.body = task.body.isEmpty ? note : task.body + "\n\n" + note
            }
            _ = try taskStore.save(task)
            decisions.record(.taskCompleted, "Completed \"\(task.title)\"",
                             actor: task.claimedBy ?? task.assignee.label,
                             projectId: task.projectId, taskId: task.id)
            return ActionResult(ok: true, snapshot: await refreshNow())

        case .snoozeTask(let taskId, let days):
            guard var task = taskStore.resolve(taskId) else {
                throw TaskStoreError.notFound(taskId)
            }
            task.snoozedUntil = Date().addingTimeInterval(Double(days) * 86_400)
            _ = try taskStore.save(task)
            decisions.record(.taskSnoozed, "Snoozed \"\(task.title)\" for \(days) day\(days == 1 ? "" : "s")",
                             projectId: task.projectId, taskId: task.id)
            return ActionResult(ok: true, snapshot: await refreshNow())

        case .deleteTask(let taskId):
            guard let task = taskStore.resolve(taskId) else {
                throw TaskStoreError.notFound(taskId)
            }
            taskStore.delete(id: task.id)
            return ActionResult(ok: true, snapshot: await refreshNow())
        }

        if action != .refresh {
            overridesStore.save(overrides)
        }
        return ActionResult(ok: true, snapshot: await refreshNow())
    }

    // MARK: Tasks

    /// Creates a task, or updates in place when its external reference is
    /// already on the board — which is what lets an agent-driven sync run twice
    /// without doubling everything.
    @discardableResult
    func create(_ fields: EngineAction.CreateTask) throws -> TaskRecord {
        let now = Date()
        let task = TaskRecord(
            id: TaskRecord.identifier(title: fields.title, now: now),
            title: fields.title,
            projectId: fields.projectId,
            assignee: fields.assignee.map(Assignee.init(encoded:)) ?? .unassigned,
            state: fields.state.flatMap(TaskState.init(rawValue:)) ?? .backlog,
            deps: fields.deps,
            acceptance: fields.acceptance,
            externalRef: fields.externalRef,
            origin: fields.origin,
            createdAt: now,
            updatedAt: now,
            body: fields.body ?? ""
        )
        return try taskStore.upsert(task, now: now)
    }

    /// Recent decisions, most recent first — the record of *why*, as opposed to
    /// the audit trail's record of *that*.
    public func recentDecisions(limit: Int = 50, projectId: String? = nil) -> [Decision] {
        decisions.recent(limit: limit, projectId: projectId)
    }

    /// Applies a partial update. Absent fields are left alone rather than
    /// cleared, so a caller that knows about three fields can't silently erase
    /// the ones it doesn't.
    @discardableResult
    func update(_ fields: EngineAction.UpdateTask) throws -> TaskRecord {
        guard var task = taskStore.resolve(fields.taskId) else {
            throw TaskStoreError.notFound(fields.taskId)
        }
        if let title = fields.title { task.title = title }
        if let state = fields.state, let parsed = TaskState(rawValue: state) { task.state = parsed }
        if let assignee = fields.assignee { task.assignee = Assignee(encoded: assignee) }
        if let acceptance = fields.acceptance { task.acceptance = acceptance }
        if let body = fields.body { task.body = body }
        if let deps = fields.deps { task.deps = deps }
        if let projectId = fields.projectId { task.projectId = projectId }
        if let waiting = fields.waiting {
            task.waiting = waiting.isEmpty ? nil : WaitingReason(rawValue: waiting)
        }
        if let reason = fields.waitingReason { task.waitingReason = reason }
        return try taskStore.save(task)
    }

    // MARK: Internals

    /// The last snapshot, refreshing first if there has never been one.
    private func currentSnapshot() async -> EngineSnapshot {
        if let latest { return latest }
        return await refreshNow()
    }

    @discardableResult
    private func refreshNow() async -> EngineSnapshot {
        let snapshot = await engine.refresh(overrides: overrides)
        let previous = latest
        latest = snapshot

        // Only push when something a subscriber would react to changed — see
        // `changeDigest`, which deliberately ignores the activity timestamps that
        // drift on every tick. A subscriber that redraws regardless is how a
        // five-second cadence turns into a list that flickers under the cursor.
        if previous?.changeDigest != snapshot.changeDigest {
            broadcast(.snapshot(snapshot))
        }

        for notification in policy.evaluate(sessions: snapshot.sessions,
                                            configuration: configuration,
                                            mutedProjects: overrides.mutedProjects) {
            broadcast(.notify(notification))
        }

        return snapshot
    }

    /// Records current statuses without notifying — call before `start()` so the
    /// app doesn't announce every already-quiet session the moment it launches.
    public func primeNotifications() async {
        let snapshot = await currentSnapshot()
        policy.prime(with: snapshot.sessions)
    }

    private func broadcast(_ event: EngineEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    private func addSubscriber(id: String, continuation: AsyncStream<EngineEvent>.Continuation) {
        subscribers[id] = continuation
        // A new subscriber shouldn't have to wait a full cadence to draw anything.
        if let latest { continuation.yield(.snapshot(latest)) }
    }

    private func removeSubscriber(id: String) {
        subscribers.removeValue(forKey: id)
    }
}
