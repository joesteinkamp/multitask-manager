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
    private let policy: NotificationPolicy

    private var overrides: UserOverrides
    private var latest: EngineSnapshot?
    private var refreshTask: Task<Void, Never>?
    private var subscribers: [String: AsyncStream<EngineEvent>.Continuation] = [:]

    public init(configuration: ConfigurationProviding = StaticConfiguration(),
                engine: DetectionEngine? = nil,
                overridesStore: OverridesStore = OverridesStore(),
                policy: NotificationPolicy = NotificationPolicy()) {
        self.configurationProvider = configuration
        self.engine = engine ?? DetectionEngine(configuration: configuration)
        self.overridesStore = overridesStore
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
        }

        if action != .refresh {
            overridesStore.save(overrides)
        }
        return ActionResult(ok: true, snapshot: await refreshNow())
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
