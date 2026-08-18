import Foundation

/// How much the audit log contributed to this pass. Carried on the snapshot so a
/// remote client can report health without a second round-trip and without
/// needing its own reader — the reader is stateful, and two of them would each
/// hold a partial view.
public struct AuditSummary: Codable, Sendable, Equatable {
    public var path: String = ""
    public var recordsRead: Int = 0
    /// Cumulative count of lines that failed to parse. Rising means concurrent
    /// appends are interleaving.
    public var malformedLines: Int = 0
    public var sessionsIndexed: Int = 0
    /// Sessions matched by harness session id rather than by directory — the
    /// number that decides whether status is a fact or a guess.
    public var preciseJoins: Int = 0

    public init() {}
}

/// Everything one refresh produced.
public struct EngineSnapshot: Codable, Sendable, Equatable {
    /// **The primary unit.** Sessions, waves and repositories are evidence about
    /// these; a project is what a person actually manages, and it appears here
    /// whether or not anything is running in it.
    public var projects: [Project] = []
    /// Every task, across every project. Projects carry their own slice; this is
    /// the flat view the queue and the MCP server work from.
    public var tasks: [TaskRecord] = []
    public var sessions: [Session] = []
    public var waves: [Wave] = []
    public var repositories: [RepositoryState] = []
    /// Detectors and readers that couldn't do their job this pass. Shown in the UI
    /// so "nothing is running" and "I can't see anything" read differently.
    public var degraded: [DegradedReason] = []
    public var audit = AuditSummary()
    /// Delegate runs, newest first.
    public var runs: [RunRecord] = []
    /// Requests from agents for permission to spend something. Carried in the
    /// snapshot because "an agent is asking you something" is exactly the kind of
    /// thing this app exists to put in front of you, rather than something you
    /// have to go looking for.
    public var approvals: [ApprovalRequest] = []
    public var refreshedAt: Date = .distantPast

    public init() {}

    /// Requests still awaiting a person, newest first.
    public var pendingApprovals: [ApprovalRequest] {
        approvals.filter { $0.effectiveState() == .pending }
    }

    public var needsAttentionCount: Int {
        sessions.filter { $0.status == .needsAttention }.count
            + repositories.filter(\.needsAttention).count
            + pendingApprovals.count
    }

    /// Projects competing for attention — archived and parked ones excluded.
    public var activeProjects: [Project] {
        projects.filter { $0.record.lifecycle.isActive }
    }

    /// Which projects need you, most urgent first. The answer to the question
    /// this app leads with.
    public var projectsNeedingYou: [Project] {
        activeProjects.filter { $0.status == .needsYou }
    }

    /// Quiet with nothing ready — the failure a many-project week produces, and
    /// the one nothing else in the app would surface.
    public var dormantProjects: [Project] {
        activeProjects.filter { $0.status == .dormant }
    }

    /// What to do next, ranked and explained. The question the product is for.
    public func whatNext(for assignee: Assignee? = .me,
                         now: Date = Date(),
                         limit: Int? = nil) -> [ReadyItem] {
        let pinned = Set(projects.filter(\.record.isPinned).map(\.id))
        return TaskQueue.next(for: assignee, tasks: tasks,
                              pinnedProjectIds: pinned, now: now, limit: limit)
    }

    /// Tasks blocked on a human, most urgent first.
    public func tasksNeedingYou(now: Date = Date()) -> [TaskRecord] {
        TaskQueue.needingAHuman(tasks: tasks, now: now)
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

    /// The parts of a snapshot whose change is worth waking a subscriber for.
    ///
    /// Plain equality is the wrong test: `lastActivity` advances on almost every
    /// tick as files are touched, so two snapshots describing an identical
    /// situation compare unequal and every subscriber gets pushed a full snapshot
    /// every five seconds forever. A client renders "3m ago" from the
    /// `lastActivity` it already holds and needs no new snapshot for its clock to
    /// move; what it genuinely needs to hear about is a session appearing or
    /// leaving, a status or wait-reason changing, a wave advancing, or a converge
    /// breaking.
    public var changeDigest: SnapshotDigest {
        SnapshotDigest(
            projects: projects.map {
                "\($0.id)|\($0.status.rawValue)|\($0.statusReason)|\($0.progress?.summary ?? "")|\($0.nextSteps.count)"
            },
            tasks: tasks.map {
                "\($0.id)|\($0.state.rawValue)|\($0.assignee.encoded)|\($0.waiting?.rawValue ?? "")|\($0.deps.joined(separator: ","))"
            },
            sessions: sessions.map {
                "\($0.activity?.touched.count ?? 0)|\($0.id)|\($0.status.rawValue)|\($0.waiting?.rawValue ?? "")|\($0.reason ?? "")|\($0.isPinned)|\($0.title)|\($0.evidence.rawValue)"
            },
            waves: waves.map {
                "\($0.id)|\($0.progress ?? "")|\($0.doneCount)/\($0.delegates.count)|\($0.isStale)"
            },
            repositories: repositories.map {
                "\($0.path)|\($0.conflictMarkers.joined(separator: ","))|"
                + $0.worktrees.map { "\($0.branch ?? "-"):\($0.ahead)/\($0.behind)" }.joined(separator: ",")
            },
            degraded: degraded.map { "\($0.detectorId)|\($0.message)" },
            runs: runs.map { "\($0.id)|\($0.state.rawValue)|\($0.exitCode.map(String.init) ?? "")" },
            approvals: approvals.map { "\($0.id)|\($0.effectiveState().rawValue)" }
        )
    }
}

/// A snapshot reduced to the facts a subscriber reacts to.
public struct SnapshotDigest: Equatable, Sendable {
    public var projects: [String]
    public var tasks: [String]
    public var sessions: [String]
    public var waves: [String]
    public var repositories: [String]
    public var degraded: [String]
    /// Runs and approvals participate in the digest so a new request from an
    /// agent actually reaches the app. Leaving them out would suppress the push
    /// that puts the decision in front of a person, which is the one thing that
    /// must not be optimised away.
    public var runs: [String]
    public var approvals: [String]
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
    private let projectStore: ProjectStore
    private let taskStore: TaskStore
    private let projectAssembler: ProjectAssembler
    private let activityReader = SessionActivityReader()
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
                worktreeReader: WorktreeReader = WorktreeReader(),
                projectStore: ProjectStore = ProjectStore(),
                taskStore: TaskStore = TaskStore(),
                projectAssembler: ProjectAssembler? = nil) {
        self.configurationProvider = configuration
        self.additionalDetectors = additionalDetectors
        self.contextReader = contextReader
        self.auditReader = auditReader ?? AuditLogReader(configuration: configuration.configuration)
        self.waveReader = waveReader
        self.worktreeReader = worktreeReader
        self.projectStore = projectStore
        self.taskStore = taskStore
        self.projectAssembler = projectAssembler ?? ProjectAssembler(contextReader: contextReader)
    }

    // MARK: Refresh

    public func refresh(overrides: UserOverrides = .empty, now: Date = Date()) async -> EngineSnapshot {
        // Drop rows for directories that are gone. A project that cannot be
        // opened cannot be acted on, and leaving it there makes every count in
        // the interface wrong — the header said four projects while one of them
        // pointed at nothing.
        projectStore.forgetVanished()

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

        var enriched = config.enableProjectContext ? contextReader.attach(to: raw) : raw

        // What each session actually did — files written and edited — read from
        // the transcript already open for the "Now" line.
        if config.enableSessionActivity {
            enriched = enriched.map { session in
                guard let transcript = session.transcriptPath else { return session }
                var copy = session
                copy.activity = activityReader.activity(forTranscript: transcript,
                                                        projectPath: session.projectPath)
                return copy
            }
        }
        snapshot.sessions = merge(raw: enriched, overrides: overrides, audit: auditIndex,
                                  config: config, now: now)

        snapshot.audit.path = config.auditLogPath
        snapshot.audit.recordsRead = auditIndex.recordsRead
        snapshot.audit.malformedLines = auditIndex.malformedLines
        snapshot.audit.sessionsIndexed = auditIndex.bySession.count
        snapshot.audit.preciseJoins = snapshot.sessions.filter { session in
            guard let id = session.harnessSessionId else { return false }
            return auditIndex.bySession[id] != nil
        }.count

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

        // Reclaim any lease that expired while nobody was looking, so a crashed
        // agent's task returns to the queue instead of stranding in `running`.
        var tasks = taskStore.load()
        let reclaimed = TaskQueue.reclaimExpired(tasks, now: now)
        if !reclaimed.isEmpty {
            for task in reclaimed { _ = try? taskStore.save(task, now: now) }
            tasks = taskStore.load()
        }
        snapshot.tasks = tasks

        // Projects last: they are assembled *from* everything above, and they are
        // what the surfaces actually render.
        snapshot.projects = projectAssembler.assemble(
            records: projectStore.load(),
            sessions: snapshot.sessions,
            tasks: tasks,
            waves: snapshot.waves,
            repositories: snapshot.repositories,
            config: config,
            now: now
        )

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
            // **Finished is not the same as needing you.** This used to report a
            // completed run as `needsAttention`, so a Codex run that ended
            // cleanly lit the badge claiming it wanted a response. It wanted
            // nothing. A run that ended is `complete` until it ages out.
            let status: SessionStatus = sinceEnd >= config.idleThreshold ? .idle : .complete
            return Verdict(status: status, evidence: .sessionEnd,
                           waiting: nil, reason: activity.endReason)
        }

        if let activity {
            // Silence is not a request. Without a hook the most this can honestly
            // say is "working" or "idle" — a quiet transcript looks identical
            // whether the agent is thinking, waiting on the network, or waiting
            // on you, and only one of those should interrupt.
            return Verdict(status: status(forGap: now.timeIntervalSince(activity.lastEventAt), config: config),
                           evidence: .auditActivity, waiting: nil, reason: nil)
        }

        guard session.lastActivity > .distantPast else {
            return Verdict(status: .unknown, evidence: .none, waiting: nil, reason: nil)
        }
        return Verdict(status: status(forGap: now.timeIntervalSince(session.lastActivity), config: config),
                       evidence: .fileActivity, waiting: nil, reason: nil)
    }

    /// What a *gap in activity* can honestly be read as.
    ///
    /// **Never `needsAttention`.** A quiet transcript looks exactly the same
    /// whether the agent is thinking, waiting on a slow network call, or waiting
    /// on a person — and this used to call all three "needs attention", which
    /// produced alerts for sessions that wanted nothing and taught the badge to
    /// be ignored.
    ///
    /// `needsAttention` now comes only from something that *says so*: a hook
    /// reporting `permission_prompt` or `agent_needs_input`, or a task explicitly
    /// waiting on a human. Install the hooks (`mtm hooks install`) and attention
    /// becomes a fact; without them the app reports activity honestly and
    /// interrupts for nothing.
    private static func status(forGap gap: TimeInterval, config: Configuration) -> SessionStatus {
        gap >= config.attentionThreshold ? .idle : .working
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
