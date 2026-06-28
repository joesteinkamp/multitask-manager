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

    private let prefs = Preferences.shared
    private let overridesStore = OverridesStore.shared
    private var overrides: UserOverrides

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

        work.async { [weak self] in
            let raw = detectors.flatMap { $0.detect() }
            // Read project briefings (goal/now/next) off the main thread so the file
            // I/O never blocks the UI. Cached by file mtime inside the reader.
            let enriched = contextEnabled ? ProjectContextReader.shared.attach(to: raw) : raw
            Task { @MainActor in
                guard let self else { return }
                self.sessions = self.merge(raw: enriched, overrides: snapshot)
                self.lastRefresh = Date()
                self.isRefreshing = false
            }
        }
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

    /// The stagnation heuristic. Hook status wins when present; otherwise classify
    /// by how long since the last activity signal.
    private func classify(_ session: Session, now: Date) -> SessionStatus {
        if let hook = session.hookStatus { return hook }
        let gap = now.timeIntervalSince(session.lastActivity)
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

    private func persistAndRefresh() {
        overridesStore.save(overrides)
        refresh()
    }
}
