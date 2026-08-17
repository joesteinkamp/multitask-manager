import Foundation
import AppKit
import Combine
import MultiTaskCore

/// The app's view model: subscribes to the engine and republishes what SwiftUI
/// needs.
///
/// It used to *be* the engine — detectors, merge logic, the status heuristic and
/// a timer in one `@MainActor` class. All of that moved to `MultiTaskCore`,
/// where it can be tested. What's left here is the part that genuinely belongs
/// to a Mac app: `@Published` properties, activating a window, and revealing a
/// folder in Finder.
@MainActor
final class SessionStore: ObservableObject {
    /// **Projects are the primary unit.** Sessions are still published because
    /// rows drill into them, but the popover leads with these.
    @Published private(set) var projects: [Project] = []
    @Published private(set) var sessions: [Session] = []
    /// The work — the unit this app manages. Sessions are how it observes.
    @Published private(set) var tasks: [TaskRecord] = []
    /// Ranked answer to "what should I do next", with the reason for each.
    @Published private(set) var nextUp: [ReadyItem] = []
    /// Tasks explicitly blocked on a person. Requests, not suggestions.
    @Published private(set) var awaitingMe: [TaskRecord] = []
    @Published private(set) var waves: [Wave] = []
    @Published private(set) var repositories: [RepositoryState] = []
    @Published private(set) var degraded: [DegradedReason] = []
    @Published private(set) var lastRefresh: Date = .distantPast
    /// Set when notification authorization was denied, so Settings can say so
    /// rather than silently never notifying.
    @Published var notificationsDenied = false

    private let prefs = Preferences.shared
    private let overridesStore = OverridesStore.shared
    private let projectStore = ProjectStore()
    private let notifier = NotificationPresenter()

    private var engine: InProcessEngine!
    private var overrides: UserOverrides
    private var eventTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// Drives the menu bar badge.
    var needsAttentionCount: Int {
        projects.filter { $0.status == .needsYou && $0.record.lifecycle.isActive }.count
    }

    var activeProjects: [Project] {
        projects.filter { $0.record.lifecycle.isActive }
    }

    /// What to do first, across everything.
    var triageQueue: [Session] {
        AttentionTriage.waitingSessions(sessions)
    }

    var hiddenCount: Int { overrides.hidden.count }

    init() {
        overrides = overridesStore.load()

        let detection = DetectionEngine(
            configuration: prefs,
            additionalDetectors: [RunningAppsDetector(configuration: prefs)],
            projectStore: projectStore
        )
        engine = InProcessEngine(configuration: prefs,
                                 engine: detection,
                                 overridesStore: overridesStore)

        // Restart the engine's cadence when the interval preference changes.
        prefs.$refreshInterval
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { await self?.restart() } }
            .store(in: &cancellables)

        start()
    }

    // MARK: Lifecycle

    func start() {
        eventTask?.cancel()
        let engine = engine!
        eventTask = Task { [weak self] in
            // Prime first so launching the app doesn't announce every session
            // that was already quiet.
            await engine.primeNotifications()
            await engine.start()
            for await event in engine.subscribe() {
                guard let self else { return }
                switch event {
                case .snapshot(let snapshot):
                    await self.apply(snapshot)
                case .notify(let notification):
                    await self.deliver(notification)
                }
            }
        }
    }

    private func restart() async {
        await engine.stop()
        start()
    }

    private func apply(_ snapshot: EngineSnapshot) {
        projects = snapshot.projects
        tasks = snapshot.tasks
        nextUp = snapshot.whatNext(for: .me, limit: 5)
        awaitingMe = snapshot.tasksNeedingYou()
        sessions = snapshot.sessions
        waves = snapshot.waves
        repositories = snapshot.repositories
        degraded = snapshot.degraded
        lastRefresh = snapshot.refreshedAt
    }

    private func deliver(_ notification: PendingNotification) async {
        let granted = await notifier.deliver(notification)
        if !granted { notificationsDenied = true }
    }

    /// Forces a pass now, rather than waiting for the cadence.
    func refresh() {
        Task { [engine] in _ = try? await engine?.act(.refresh) }
    }

    // MARK: Actions

    /// Every mutation goes through the engine's action set rather than editing
    /// overrides here, so the CLI, the app and (later) an agent over MCP all
    /// take the same path and hit the same gates.
    private func perform(_ action: EngineAction) {
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.engine.act(action)
            self.overrides = self.overridesStore.load()
        }
    }

    func addManual(title: String, projectPath: String?) {
        perform(.addManual(title: title, projectPath: projectPath))
    }

    func remove(_ session: Session) {
        perform(session.isManual ? .removeManual(sessionId: session.id) : .hide(sessionId: session.id))
    }

    func rename(_ session: Session, to newTitle: String) {
        perform(.rename(sessionId: session.id, title: newTitle))
    }

    func togglePin(_ session: Session) {
        perform(session.isPinned ? .unpin(sessionId: session.id) : .pin(sessionId: session.id))
    }

    func clearHidden() { perform(.clearHidden) }

    func toggleMute(_ project: Project) {
        guard let path = project.path else { return }
        perform(isMuted(project) ? .unmute(projectPath: path) : .mute(projectPath: path))
    }

    func isMuted(_ project: Project) -> Bool {
        guard let path = project.path else { return false }
        return overrides.mutedProjects.contains(path)
    }

    // MARK: Tasks

    /// Captures a piece of work. `acceptance` is optional here but strongly
    /// wanted: work filed without it gets delivered wrong and rejected, which
    /// costs more than writing the line.
    func addTask(title: String, projectId: String? = nil,
                 assignee: Assignee = .me, acceptance: String? = nil) {
        perform(.createTask(.init(
            title: title,
            projectId: projectId,
            assignee: assignee.encoded,
            acceptance: acceptance,
            origin: "app",
            state: "ready"
        )))
    }

    func complete(_ task: TaskRecord) { perform(.completeTask(taskId: task.id, note: nil)) }

    func snooze(_ task: TaskRecord, days: Int = 7) {
        perform(.snoozeTask(taskId: task.id, days: days))
    }

    func delete(_ task: TaskRecord) { perform(.deleteTask(taskId: task.id)) }

    func start(_ task: TaskRecord) {
        perform(.updateTask(.init(taskId: task.id, state: TaskState.running.rawValue)))
    }

    /// Hands a task to a delegate. It does not *run* anything — assigning is
    /// organising, and organising is free; starting a run is the gated step and
    /// lives in Phase 3.
    func assign(_ task: TaskRecord, to assignee: Assignee) {
        perform(.updateTask(.init(taskId: task.id, assignee: assignee.encoded)))
    }

    /// Clears a task's request for a human, once you've dealt with it.
    func resolveWaiting(_ task: TaskRecord) {
        perform(.updateTask(.init(taskId: task.id, waiting: "")))
    }

    /// The delegates this machine can hand work to, for the assign menu.
    lazy var delegates: [String] = RosterReader().read().delegates.map(\.name)

    // MARK: Project lifecycle

    func archive(_ project: Project) {
        var record = project.record
        record.lifecycle = .archived
        projectStore.save(record)
        refresh()
    }

    func park(_ project: Project, days: Int = 7) {
        var record = project.record
        record.lifecycle = .parked(until: Date().addingTimeInterval(Double(days) * 86_400))
        projectStore.save(record)
        refresh()
    }

    func unarchive(_ project: Project) {
        var record = project.record
        record.lifecycle = .active
        projectStore.save(record)
        refresh()
    }

    func togglePin(_ project: Project) {
        var record = project.record
        record.isPinned.toggle()
        projectStore.save(record)
        refresh()
    }

    // MARK: Opening things

    /// Brings the underlying work to the foreground: activates the app for
    /// desktop sessions, or reveals the project folder in Finder otherwise.
    func activate(_ session: Session) {
        if let pid = session.pid, let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateAllWindows])
            return
        }
        if let bundleId = session.bundleId,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.open(url)
            return
        }
        if let path = session.projectPath { reveal(path) }
    }

    func activate(_ project: Project) {
        if let path = project.path { reveal(path) }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Focuses the session a notification was about.
    func focus(sessionId: String) {
        if let session = sessions.first(where: { $0.id == sessionId }) { activate(session) }
    }
}
