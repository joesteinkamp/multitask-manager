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
    /// Agents asking permission to spend something. These outrank everything
    /// else in the popover: an agent is stopped until you answer, so every
    /// minute one sits here is a minute of idle work.
    @Published private(set) var pendingApprovals: [ApprovalRequest] = []
    @Published private(set) var runs: [RunRecord] = []
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
            + pendingApprovals.count
    }

    /// Runs still going, for the "working" summary.
    var activeRuns: [RunRecord] { runs.filter { !$0.state.isTerminal } }

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
                    // No `await`: this Task inherits SessionStore's MainActor
                    // context, and `apply` is a synchronous MainActor method, so
                    // there is no hop to suspend on. `deliver` genuinely is async.
                    self.apply(snapshot)
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
        pendingApprovals = snapshot.pendingApprovals
        runs = snapshot.runs
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

    /// Every muted project path, for the list in Settings.
    ///
    /// Muting happens on a project's row, which is the right place for it — but
    /// a muted project stops being somewhere you look, so the row you would undo
    /// it from is the row you no longer visit. Without a list, muting is a
    /// one-way door.
    var mutedProjectPaths: [String] { overrides.mutedProjects.sorted() }

    func unmute(path: String) { perform(.unmute(projectPath: path)) }

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
    /// organising, and organising is free. Starting the run is the gated step.
    func assign(_ task: TaskRecord, to assignee: Assignee) {
        perform(.updateTask(.init(taskId: task.id, assignee: assignee.encoded)))
    }

    // MARK: Control

    /// Asks the engine what running this task would do, without doing it.
    ///
    /// The app never guesses the confirmation text: it shows exactly what the
    /// engine hands back, so the sheet and the thing that runs cannot drift
    /// apart. Returns `nil` when the run is impossible — no project directory,
    /// no such delegate — with the reason in `error`.
    func describeRun(_ task: TaskRecord, delegate: String?) async -> (ConfirmationRequest?, String?) {
        do {
            let result = try await engine.act(.runTask(taskId: task.id, delegate: delegate, confirm: nil))
            return (result.confirmation, nil)
        } catch {
            return (nil, "\(error)")
        }
    }

    /// Starts a run the person has just agreed to, carrying the token from the
    /// description they were shown.
    @discardableResult
    func confirmRun(_ task: TaskRecord, delegate: String?, token: String) async -> String? {
        do {
            let result = try await engine.act(.runTask(taskId: task.id, delegate: delegate,
                                                       confirm: token))
            guard result.runId != nil else {
                return "That confirmation no longer matches this task. Try again."
            }
            return nil
        } catch {
            return "\(error)"
        }
    }

    func cancel(_ run: RunRecord) { perform(.cancelRun(runId: run.id)) }

    /// Opens a run's output in whatever the user reads logs with. Output is a
    /// file precisely so this works, rather than the app pretending to be a
    /// terminal.
    func showOutput(_ run: RunRecord) {
        NSWorkspace.shared.open(RunStore().stdoutURL(for: run.id))
    }

    // MARK: Approvals

    /// A person's decision on an agent's request.
    ///
    /// Approving here is the *only* path that mints a confirmation token, and it
    /// runs inside the engine. Nothing in the app — and nothing over MCP — can
    /// approve on the user's behalf.
    @discardableResult
    func decide(_ request: ApprovalRequest, approve: Bool, note: String? = nil) async -> String? {
        do {
            let result = try await engine.act(.decideApproval(id: request.id, approve: approve,
                                                              note: note))
            guard let decided = result.approval else { return "That request is gone." }
            switch decided.effectiveState() {
            case .expired:
                return "This sat too long to act on safely. Ask the agent to request it again."
            case .pending:
                return "It wasn't decided."
            case .approved where decided.runId == nil:
                return decided.note ?? "Approved, but it didn't start."
            default:
                return nil
            }
        } catch {
            // Left pending on purpose, so the reason can be fixed and the same
            // decision made again.
            return "\(error)"
        }
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

    /// Tracks a directory as a project.
    ///
    /// The app could not do this at all: a project appeared only when a session
    /// happened to run in it, or when `mtm projects add` was run in a terminal.
    /// For an app whose primary unit is the project, "you cannot add one" is a
    /// hole rather than a simplification.
    ///
    /// Mirrors the CLI: an already-tracked directory is reported, not duplicated
    /// under a second id.
    @discardableResult
    func trackProject(at url: URL) -> String? {
        let path = FileSupport.normalise(url.path)
        if let existing = projects.first(where: {
            $0.path.map { FileSupport.pathsEqual($0, path) } ?? false
        }) {
            return "Already tracking \(existing.name)."
        }
        let record = ProjectRecord(
            id: ProjectRecord.identifier(forPath: url.path),
            name: FileSupport.lastComponent(of: path),
            path: url.path,
            // Marked, so the cleanup that removes vanished *discovered* projects
            // can never remove one the user chose.
            origin: "manual"
        )
        projectStore.save(record)
        refresh()
        return nil
    }

    /// Archived and parked projects, so they can be brought back from the app.
    /// `unarchive` existed but nothing could reach it, because the only rows
    /// drawn are the active ones.
    var restorableProjects: [Project] {
        projects.filter { !$0.record.lifecycle.isActive }
    }

    /// Removes a project from the board entirely.
    ///
    /// Distinct from archiving, which keeps it. This is for a row that should
    /// never have existed — a directory that was never a project, a worktree,
    /// something detection got wrong. Every rule for guessing what a project is
    /// will be wrong sometimes, and there has to be a way to say so.
    func forget(_ project: Project) {
        projectStore.forget(id: project.id)
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

    /// Brings the underlying work to the foreground.
    ///
    /// In order of how much good it does:
    ///
    /// 1. **The session's own app**, when it is a desktop app we have a pid for.
    /// 2. **The terminal running the session**, found by walking up from a
    ///    process working in the project directory. This is the case that
    ///    matters: a CLI session carries no pid, so this used to fall straight
    ///    through to Finder — which answers "where does this project live"
    ///    when the question was "where is the thing that needs me".
    /// 3. **The project folder in Finder**, when nothing is running any more.
    ///    Still the right answer then, just not the first one.
    @discardableResult
    func activate(_ session: Session) -> Bool {
        if let pid = session.pid, let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateAllWindows])
            return true
        }
        if let bundleId = session.bundleId,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.open(url)
            return true
        }
        if let path = session.projectPath, focusTerminal(forProjectPath: path) {
            return true
        }
        if let path = session.projectPath { reveal(path) }
        return false
    }

    /// Brings forward the terminal running whatever is working in `path`.
    ///
    /// - Returns: whether a terminal was found *and* activated. `false` means
    ///   nothing recognisable is running there, and the caller should fall back.
    @discardableResult
    func focusTerminal(forProjectPath path: String) -> Bool {
        let processes = ProcessSnapshot.current()
        guard let (terminal, process) = TerminalResolver.terminal(forProjectPath: path,
                                                                  among: processes) else {
            return false
        }

        // Activate the process we actually walked to, not a fresh launch of the
        // bundle: with two Warp windows open for two projects, launching the app
        // would raise whichever was last used, which is the wrong one half the
        // time.
        if let running = NSRunningApplication(processIdentifier: process.pid) {
            running.activate(options: [.activateAllWindows])
            return true
        }

        // The process we found is a helper rather than the app itself — common
        // for Electron-based editors. Fall back to the bundle.
        for bundleId in terminal.bundleIds {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                NSWorkspace.shared.open(url)
                return true
            }
        }
        return false
    }

    /// Goes to where the project's work is happening.
    ///
    /// Same order as a session, and for the same reason: a project row is a way
    /// into the work, and the work is in a terminal. Revealing the folder was the
    /// only behaviour here, which answered "where does this live" rather than
    /// "take me to it".
    @discardableResult
    func activate(_ project: Project) -> Bool {
        guard let path = project.path else { return false }
        if focusTerminal(forProjectPath: path) { return true }

        // Nothing is running there. Finder is the right answer now — but only if
        // the directory still exists: revealing a path that has been moved or
        // deleted opens something arbitrary, which is how a stale row ended up
        // opening ~/Applications.
        guard FileSupport.isDirectory(URL(fileURLWithPath: path)) else { return false }
        reveal(path)
        return true
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Brings the app forward when a notification about a decision is tapped.
    ///
    /// **It cannot open the popover, and doesn't pretend to.** `MenuBarExtra`
    /// exposes no supported way to present its own window, and the unsupported
    /// routes — synthesising a click on the status item, or replacing it with a
    /// hand-built `NSStatusItem` — trade a working menu bar for one click. So
    /// the notification's job ends at telling you there is a decision; the badge
    /// carries the count, and the request is the first thing in the popover when
    /// you open it.
    func requestPopover() {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Focuses the session a notification was about.
    func focus(sessionId: String) {
        if let session = sessions.first(where: { $0.id == sessionId }) { activate(session) }
    }
}
