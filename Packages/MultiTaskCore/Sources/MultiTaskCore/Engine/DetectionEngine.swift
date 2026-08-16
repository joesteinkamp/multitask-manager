import Foundation

/// Everything one refresh produced.
public struct EngineSnapshot: Sendable {
    public var sessions: [Session] = []
    public var waves: [Wave] = []
    public var repositories: [RepositoryState] = []
    /// Detectors and readers that couldn't do their job this pass. Shown in the UI
    /// so "nothing is running" and "I can't see anything" read differently.
    public var degraded: [DegradedReason] = []
    /// Cumulative count of audit-log lines that failed to parse.
    public var malformedAuditLines: Int = 0
    public var refreshedAt: Date = .distantPast

    public init() {}

    public var needsAttentionCount: Int {
        sessions.filter { $0.status == .needsAttention }.count
            + repositories.filter(\.needsAttention).count
    }

    /// Waiting sessions in triage order.
    public func triageQueue(now: Date = Date()) -> [Session] {
        AttentionTriage.waitingSessions(sessions, now: now)
    }

    /// Sessions grouped by project for sectioned display.
    public var groupedByProject: [(project: String, sessions: [Session])] {
        Dictionary(grouping: sessions) { $0.projectName }
            .map { (project: $0.key, sessions: $0.value) }
            .sorted { lhs, rhs in
                let l = lhs.sessions.map(\.status.sortRank).min() ?? Int.max
                let r = rhs.sessions.map(\.status.sortRank).min() ?? Int.max
                if l != r { return l < r }
                return lhs.project.localizedCaseInsensitiveCompare(rhs.project) == .orderedAscending
            }
    }

    public var activeWaves: [Wave] { waves.filter { !$0.isStale } }
    public var pastWaves: [Wave] { waves.filter(\.isStale) }
}

/// The detection engine: runs detectors, enriches with every signal available, and
/// produces a merged, classified, sorted snapshot.
///
/// UI-free and platform-neutral on purpose — the popover, a window, the `mtm` CLI
/// and the daemon are all supposed to be different faces of *this*, not four
/// re-implementations of it. The app keeps a thin `SessionStore` that owns the
/// timer and the `@Published` properties and subscribes to this.
public actor DetectionEngine {
    private let configurationProvider: ConfigurationProviding
    private let contextReader: ProjectContextReader
    private let auditReader: AuditLogReader
    private let waveReader: WaveReader
    private let worktreeReader: WorktreeReader
    /// Detectors the host supplies — `RunningAppsDetector` needs AppKit, so it
    /// lives in the app and is injected here.
    private let additionalDetectors: [SessionDetector]

    /// Cached git results, refreshed on their own slower cadence.
    private var repositories: [RepositoryState] = []
    private var lastGitScan: Date = .distantPast

    public init(configuration: ConfigurationProviding,
                additionalDetectors: [SessionDetector] = [],
                contextReader: ProjectContextReader = ProjectContextReader(),
                auditReader: AuditLogReader? = nil,
                waveReader: WaveReader = WaveReader(),
                worktreeReader: WorktreeReader = WorktreeReader()) {
        self.configurationProvider = configuration
        self.additionalDetectors = additionalDetectors
        self.contextReader = contextReader
        self.auditReader = auditReader ?? AuditLogReader(configuration: configuration.configuration)
        self.waveReader = waveReader
        self.worktreeReader = worktreeReader
    }

    // MARK: Refresh

    public func refresh(overrides: UserOverrides = .empty, now: Date = Date()) async -> EngineSnapshot {
        let config = configurationProvider.configuration
        var snapshot = EngineSnapshot()

        // Detectors run concurrently: the slowest one no longer sets the pace, and
        // each is independently cancellable.
        let detectors = makeDetectors(config: config)
        var raw: [Session] = []
        await withTaskGroup(of: DetectionOutcome.self) { group in
            for detector in detectors {
                group.addTask { await detector.detect() }
            }
            for await outcome in group {
                raw.append(contentsOf: outcome.sessions)
                if let degraded = outcome.degraded { snapshot.degraded.append(degraded) }
            }
        }

        let auditIndex = config.enableAuditLog ? auditReader.refresh(now: now) : AuditIndex()
        if let degraded = auditIndex.degraded { snapshot.degraded.append(degraded) }
        snapshot.malformedAuditLines = auditIndex.malformedLines

        let enriched = config.enableProjectContext ? contextReader.attach(to: raw) : raw
        snapshot.sessions = merge(raw: enriched, overrides: overrides, audit: auditIndex,
                                  config: config, now: now)

        let knownProjects = snapshot.sessions.compactMap(\.projectPath)
        if config.enableWaves {
            snapshot.waves = waveReader.read(knownProjects: Array(Set(knownProjects)), now: now)
        }

        // Shelling out to git per repo is far too expensive for the 5s tick, so it
        // keeps its own cadence and serves the cached result in between.
        if config.enableWorktrees {
            if now.timeIntervalSince(lastGitScan) >= config.gitRefreshInterval {
                let repos = config.trackedRepositories.isEmpty
                    ? Array(Set(knownProjects))
                    : config.trackedRepositories
                repositories = worktreeReader.read(repositories: repos, now: now)
                lastGitScan = now
            }
            snapshot.repositories = repositories
        }

        snapshot.refreshedAt = now
        return snapshot
    }

    /// Builds the active detector set from configuration.
    private func makeDetectors(config: Configuration) -> [SessionDetector] {
        var detectors: [SessionDetector] = []
        if config.enableClaudeCode { detectors.append(ClaudeCodeDetector()) }
        if config.enableCodex { detectors.append(CodexDetector()) }
        if config.enableDevFolders && !config.devFolders.isEmpty {
            detectors.append(DevFolderDetector(roots: config.devFolders))
        }
        if config.enableHooks { detectors.append(HookStatusReader()) }
        detectors.append(contentsOf: additionalDetectors)
        return detectors
    }

    // MARK: Merge

    /// Dedupe detected sessions, fold in hook records and audit activity, drop
    /// hidden ones, append manual entries, apply renames/pins, classify, and sort.
    ///
    /// Exposed for tests: this is where nearly all of the app's behaviour lives, and
    /// it is pure given its inputs.
    public static func merge(raw: [Session],
                             overrides: UserOverrides,
                             audit: AuditIndex,
                             config: Configuration,
                             now: Date) -> [Session] {
        // Split hook records from regular detections.
        let hookRecords = raw.filter { $0.id.hasPrefix("hook:") }
        let detected = raw.filter { !$0.id.hasPrefix("hook:") }

        // Dedupe regular detections by id, keeping the most recent activity.
        var byId: [String: Session] = [:]
        for session in detected {
            if let existing = byId[session.id], existing.lastActivity >= session.lastActivity { continue }
            byId[session.id] = session
        }

        // Apply hook records. Matching by the harness's session id is exact, so it
        // is tried first; matching by project path is the fallback, and misattributes
        // when one project has several sessions running — which is precisely why the
        // v2 contract added `sessionId`.
        for record in hookRecords {
            let matchKey: String?
            if let sessionId = record.harnessSessionId,
               let key = byId.first(where: { $0.value.harnessSessionId == sessionId })?.key {
                matchKey = key
            } else if let path = record.projectPath,
                      let key = byId.first(where: { $0.value.projectPath == path })?.key {
                matchKey = key
            } else {
                matchKey = nil
            }

            if let matchKey, var match = byId[matchKey] {
                match.hookStatus = record.hookStatus
                match.waiting = record.waiting
                match.reason = record.reason
                match.lastActivity = max(match.lastActivity, record.lastActivity)
                byId[matchKey] = match
            } else {
                byId[record.id] = record
            }
        }

        var result = Array(byId.values)

        // Remove user-hidden sessions.
        result.removeAll { overrides.hidden.contains($0.id) }

        // Append manual sessions (not subject to hidden — removing deletes them).
        result.append(contentsOf: overrides.manual)

        // Apply renames, pins, audit enrichment, and classify.
        result = result.map { session in
            var s = session
            if let renamed = overrides.renames[s.id] { s.title = renamed }
            s.isPinned = overrides.pinned.contains(s.id)

            let activity = audit.activity(sessionId: s.harnessSessionId, projectPath: s.projectPath)
            if let activity {
                s.lastActivity = max(s.lastActivity, activity.lastEventAt)
                s.lastToolName = activity.lastToolName
            }

            let verdict = classify(s, activity: activity, config: config, now: now)
            s.status = verdict.status
            s.evidence = verdict.evidence
            if s.waiting == nil { s.waiting = verdict.waiting }
            if s.reason == nil { s.reason = verdict.reason }
            return s
        }

        if config.hideIdle {
            result.removeAll { $0.status == .idle && !$0.isPinned }
        }

        return sortSessions(result)
    }

    /// The status verdict for one session, with what it was based on.
    public struct Verdict: Sendable, Equatable {
        public var status: SessionStatus
        public var evidence: StatusEvidence
        public var waiting: WaitingReason?
        public var reason: String?
    }

    /// Resolves status by precedence, strongest signal first:
    ///
    /// 1. **Hook status file** — the harness told us outright.
    /// 2. **Audit-log `SessionEnd`** — the run is definitively over. This is the
    ///    first time "finished" is a fact rather than an inference.
    /// 3. **Audit-log last-event age** — the agent's own tool calls, which keep
    ///    ticking during a long operation that never touches the transcript.
    /// 4. **Transcript mtime** — the original heuristic, still the floor so that a
    ///    machine with no harness logging behaves exactly as it did before.
    public static func classify(_ session: Session,
                                activity: AuditActivity?,
                                config: Configuration,
                                now: Date) -> Verdict {
        if let hook = session.hookStatus {
            return Verdict(status: hook, evidence: .hook,
                           waiting: session.waiting, reason: session.reason)
        }

        if let activity, let endedAt = activity.endedAt {
            let sinceEnd = now.timeIntervalSince(endedAt)
            // A run that finished days ago isn't asking for anything; age it out the
            // same way a quiet session ages out.
            let status: SessionStatus = sinceEnd >= config.idleThreshold ? .idle : .needsAttention
            return Verdict(status: status, evidence: .sessionEnd,
                           waiting: status == .needsAttention ? .done : nil,
                           reason: activity.endReason)
        }

        if let activity {
            return Verdict(status: status(forGap: now.timeIntervalSince(activity.lastEventAt), config: config),
                           evidence: .auditActivity, waiting: nil, reason: nil)
        }

        guard session.lastActivity > .distantPast else {
            return Verdict(status: .unknown, evidence: .none, waiting: nil, reason: nil)
        }
        return Verdict(status: status(forGap: now.timeIntervalSince(session.lastActivity), config: config),
                       evidence: .fileActivity, waiting: nil, reason: nil)
    }

    private static func status(forGap gap: TimeInterval, config: Configuration) -> SessionStatus {
        if gap >= config.idleThreshold { return .idle }
        if gap >= config.attentionThreshold { return .needsAttention }
        return .working
    }

    public static func sortSessions(_ sessions: [Session]) -> [Session] {
        sessions.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            if a.status.sortRank != b.status.sortRank { return a.status.sortRank < b.status.sortRank }
            return a.lastActivity > b.lastActivity
        }
    }

    /// Instance shim so callers don't have to thread configuration through.
    func merge(raw: [Session], overrides: UserOverrides, audit: AuditIndex,
               config: Configuration, now: Date) -> [Session] {
        Self.merge(raw: raw, overrides: overrides, audit: audit, config: config, now: now)
    }
}
