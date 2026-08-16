import Foundation
import AppKit
import Combine

/// Central view model. Periodically runs the enabled detectors on a background
/// queue, merges results with persisted user overrides, classifies each session
/// with the stagnation heuristic, and publishes a sorted list for the UI.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var lastRefresh: Date = .distantPast

    /// Audit log health, surfaced in Settings. Nil until the reader has run.
    @Published private(set) var auditHealth: AuditLogReader.Health?

    private let prefs = Preferences.shared
    private let overridesStore = OverridesStore.shared
    private var overrides: UserOverrides

    private let auditReader = AuditLogReader.shared
    private let notifier = AttentionNotifier()
    private let notifications = NotificationManager.shared

    private var timer: Timer?
    private let work = DispatchQueue(label: "com.multitaskmanager.detect", qos: .utility)
    private var isRefreshing = false
    private var cancellables = Set<AnyCancellable>()

    /// Count of sessions currently flagged as needing attention. Drives the badge.
    var needsAttentionCount: Int {
        sessions.filter { $0.status == .needsAttention }.count
    }

    init() {
        overrides = overridesStore.load()

        // Restart the timer whenever the cadence preference changes.
        prefs.$refreshInterval
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.startTimer() }
            }
            .store(in: &cancellables)

        // Re-prime the audit reader when the configured path changes, so it
        // doesn't read a different file at a stale offset.
        prefs.$auditLogPath
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.auditReader.reset() }
            }
            .store(in: &cancellables)

        // Turning notifications back on shouldn't replay the transitions that
        // happened while they were off.
        prefs.$enableNotifications
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.notifier.reset() }
            }
            .store(in: &cancellables)

        // The delegate has to exist before the first notification is scheduled,
        // or the "Open" action won't be attached to it.
        notifications.bootstrap()
        notifications.onOpen = { [weak self] id in
            Task { @MainActor in self?.activate(id: id) }
        }

        // Begin detecting at launch so the menu bar badge is live before the user
        // ever opens the popover.
        start()
    }

    // MARK: Lifecycle

    func start() {
        startTimer()
        refresh()
    }

    private func startTimer() {
        timer?.invalidate()
        let interval = max(1.0, prefs.refreshInterval)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: Refresh pipeline

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        let detectors = makeDetectors()
        let snapshot = overrides
        let contextEnabled = prefs.enableProjectContext
        let auditEnabled = prefs.enableAuditLog
        let auditPath = AuditLogReader.resolvePath(override: prefs.auditLogPath)
        let reader = auditReader

        work.async { [weak self] in
            let raw = detectors.flatMap { $0.detect() }
            // Read project briefings (goal/now/next) off the main thread so the file
            // I/O never blocks the UI. Cached by file mtime inside the reader.
            var enriched = contextEnabled ? ProjectContextReader.shared.attach(to: raw) : raw

            // Tail whatever the harness appended since last pass. Reads only new
            // bytes, so this stays cheap on the refresh path.
            var health: AuditLogReader.Health?
            if auditEnabled {
                let index = reader.refresh(path: auditPath)
                enriched = reader.attach(to: enriched, index: index)
                health = reader.currentHealth
            }

            let finalSessions = enriched
            let finalHealth = health
            Task { @MainActor in
                guard let self else { return }
                self.sessions = self.merge(raw: finalSessions, overrides: snapshot)
                self.auditHealth = finalHealth
                self.lastRefresh = Date()
                self.isRefreshing = false
                self.notifyIfNeeded()
            }
        }
    }

    /// Feeds the freshly-classified list to the notifier and delivers whatever
    /// survives its filters. Runs on every refresh — the notifier needs to see
    /// each pass to detect edges and debounce them, even when notifications are
    /// switched off.
    private func notifyIfNeeded() {
        notifier.policy.cooldown = max(60, prefs.notificationCooldown)
        let alerts = notifier.evaluate(
            sessions: sessions,
            isMuted: { [overrides] session in overrides.isMuted(session) },
            isQuiet: prefs.isWithinQuietHours
        )
        guard prefs.enableNotifications else { return }
        notifications.deliver(alerts)
    }

    /// Builds the active detector set from preferences.
    private func makeDetectors() -> [SessionDetector] {
        var detectors: [SessionDetector] = []
        if prefs.enableClaudeCode { detectors.append(ClaudeCodeDetector()) }
        if prefs.enableCodex { detectors.append(CodexDetector()) }
        if prefs.enableRunningApps {
            detectors.append(RunningAppsDetector(
                bundleAllowlist: prefs.bundleAllowlist,
                nameKeywords: prefs.appNameKeywords
            ))
        }
        if prefs.enableDevFolders {
            detectors.append(DevFolderDetector(roots: prefs.devFolders))
        }
        if prefs.enableHooks { detectors.append(HookStatusReader()) }
        return detectors
    }

    /// Dedupe detected sessions, fold in hook overrides, drop hidden ones, append
    /// manual entries, apply renames/pins, classify, and sort.
    private func merge(raw: [Session], overrides: UserOverrides) -> [Session] {
        // Split hook records from regular detections.
        let hookRecords = raw.filter { $0.id.hasPrefix("hook:") }
        let detected = raw.filter { !$0.id.hasPrefix("hook:") }

        // Dedupe regular detections by id, keeping the most recent activity.
        var byId: [String: Session] = [:]
        for session in detected {
            if let existing = byId[session.id], existing.lastActivity >= session.lastActivity { continue }
            byId[session.id] = session
        }

        // Apply hook statuses: match by projectPath; otherwise keep standalone.
        for record in hookRecords {
            if let path = record.projectPath,
               let matchKey = byId.first(where: { $0.value.projectPath == path })?.key {
                byId[matchKey]?.hookStatus = record.hookStatus
                // v2 fields ride along. All nil for a v1 hook, which is what
                // makes the old contract keep working unchanged.
                byId[matchKey]?.waiting = record.waiting
                byId[matchKey]?.statusReason = record.statusReason
                if let sessionID = record.harnessSessionID, !sessionID.isEmpty {
                    byId[matchKey]?.harnessSessionID = sessionID
                }
                byId[matchKey]?.lastActivity = max(byId[matchKey]!.lastActivity, record.lastActivity)
            } else {
                byId[record.id] = record
            }
        }

        var result = Array(byId.values)

        // Remove user-hidden sessions.
        result.removeAll { overrides.hidden.contains($0.id) }

        // Append manual sessions (not subject to hidden — removing deletes them).
        result.append(contentsOf: overrides.manual)

        // Apply renames, pins, and classify.
        let now = Date()
        result = result.map { session in
            var s = session
            if let renamed = overrides.renames[s.id] { s.title = renamed }
            s.isPinned = overrides.pinned.contains(s.id)
            s.status = classify(s, now: now)
            return s
        }

        if prefs.hideIdle {
            result.removeAll { $0.status == .idle && !$0.isPinned }
        }

        return sortSessions(result)
    }

    /// Resolves status from the best signal available, in this order:
    ///
    /// 1. **Hook status file.** The only source that knows *why* a session
    ///    stopped, because the harness told it.
    /// 2. **Audit `SessionEnd`.** A record that the run finished — a fact, not
    ///    an inference. Everything below this line is guesswork about silence.
    /// 3. **Audit last-event age.** Tool calls are a truer pulse than a file's
    ///    mtime, which also moves for reasons that aren't the agent working.
    /// 4. **Transcript mtime.** Always present, so it stays at the bottom of the
    ///    stack and the list never degrades below what shipped (ground rule 1).
    private func classify(_ session: Session, now: Date) -> SessionStatus {
        if let hook = session.hookStatus { return hook }

        if let audit = session.audit {
            if let endedAt = audit.endedAt {
                // Finished. Still worth your attention until it goes stale, at
                // which point it's just history.
                return now.timeIntervalSince(endedAt) >= prefs.idleThreshold ? .idle : .needsAttention
            }
            if !audit.matchedByWorkingDirectory {
                return classify(gap: now.timeIntervalSince(audit.lastEventAt))
            }
        }

        // A working-directory match identifies the project, not the session, so
        // it only ever moves the clock forward — it never decides on its own.
        let activity = max(session.lastActivity, session.audit?.lastEventAt ?? .distantPast)
        return classify(gap: now.timeIntervalSince(activity))
    }

    private func classify(gap: TimeInterval) -> SessionStatus {
        if gap >= prefs.idleThreshold { return .idle }
        if gap >= prefs.attentionThreshold { return .needsAttention }
        return .working
    }

    private func sortSessions(_ sessions: [Session]) -> [Session] {
        sessions.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            if a.status.sortRank != b.status.sortRank { return a.status.sortRank < b.status.sortRank }
            return a.lastActivity > b.lastActivity
        }
    }

    /// Sessions grouped by project for sectioned display.
    var groupedByProject: [(project: String, sessions: [Session])] {
        let groups = Dictionary(grouping: sessions) { $0.projectName }
        return groups
            .map { (project: $0.key, sessions: $0.value) }
            .sorted { lhs, rhs in
                let l = lhs.sessions.map(\.status.sortRank).min() ?? Int.max
                let r = rhs.sessions.map(\.status.sortRank).min() ?? Int.max
                if l != r { return l < r }
                return lhs.project.localizedCaseInsensitiveCompare(rhs.project) == .orderedAscending
            }
    }

    // MARK: User actions

    func addManual(title: String, projectPath: String?) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let session = Session(
            id: "manual:\(UUID().uuidString)",
            title: trimmed,
            projectName: trimmed,
            projectPath: projectPath,
            source: .manual,
            lastActivity: Date(),
            isManual: true
        )
        overrides.manual.append(session)
        persistAndRefresh()
    }

    func remove(_ session: Session) {
        if session.isManual {
            overrides.manual.removeAll { $0.id == session.id }
        } else {
            overrides.hidden.insert(session.id)
        }
        overrides.renames[session.id] = nil
        overrides.pinned.remove(session.id)
        persistAndRefresh()
    }

    func rename(_ session: Session, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if session.isManual, let idx = overrides.manual.firstIndex(where: { $0.id == session.id }) {
            overrides.manual[idx].title = trimmed
        } else {
            overrides.renames[session.id] = trimmed
        }
        persistAndRefresh()
    }

    func togglePin(_ session: Session) {
        if overrides.pinned.contains(session.id) {
            overrides.pinned.remove(session.id)
        } else {
            overrides.pinned.insert(session.id)
        }
        persistAndRefresh()
    }

    /// Silences notifications for a session's whole project. The row, the badge,
    /// and the count all keep working — mute is about interruption, not about
    /// hiding the work.
    func toggleMute(_ session: Session) {
        let key = UserOverrides.muteKey(for: session)
        if overrides.mutedProjects.contains(key) {
            overrides.mutedProjects.remove(key)
        } else {
            overrides.mutedProjects.insert(key)
        }
        persistAndRefresh()
    }

    func isMuted(_ session: Session) -> Bool { overrides.isMuted(session) }

    var mutedProjectKeys: [String] { overrides.mutedProjects.sorted() }

    func unmute(key: String) {
        overrides.mutedProjects.remove(key)
        persistAndRefresh()
    }

    /// Restores everything the user previously removed.
    func clearHidden() {
        overrides.hidden.removeAll()
        persistAndRefresh()
    }

    var hiddenCount: Int { overrides.hidden.count }

    /// Brings the underlying work to the foreground: activates the app for desktop
    /// sessions, or reveals the project folder in Finder for file-based ones.
    func activate(_ session: Session) {
        if let pid = session.pid,
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateAllWindows])
            return
        }
        if let bundleId = session.bundleId,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.open(url)
            return
        }
        if let path = session.projectPath {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    /// Entry point for a notification's "Open" action. The session may have been
    /// reclassified — or have disappeared — between the notification firing and
    /// the user clicking it, so this fails quietly rather than guessing.
    func activate(id: String) {
        NSApp.activate(ignoringOtherApps: true)
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        activate(session)
    }

    private func persistAndRefresh() {
        overridesStore.save(overrides)
        refresh()
    }
}
