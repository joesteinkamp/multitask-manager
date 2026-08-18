import Foundation

/// Turns everything the detectors found into projects, and decides what each
/// one needs from you.
///
/// This is where the app stops being a session monitor. Sessions, waves and
/// repositories are all *evidence about* a project; the project is the unit a
/// person manages, and it exists whether or not anything is currently running
/// in it.
public struct ProjectAssembler: Sendable {
    /// A project with no activity for longer than this, and nothing ready to
    /// pick up, is dormant.
    public static let dormancyWindow: TimeInterval = 7 * 24 * 60 * 60

    private let briefReader: BriefReader
    private let contextReader: ProjectContextReader

    public init(briefReader: BriefReader = BriefReader(),
                contextReader: ProjectContextReader = ProjectContextReader()) {
        self.briefReader = briefReader
        self.contextReader = contextReader
    }

    /// - Parameters:
    ///   - records: persisted projects, including ones with no activity at all.
    ///   - sessions: already merged and classified.
    public func assemble(records: [ProjectRecord],
                         sessions: [Session],
                         tasks: [TaskRecord] = [],
                         waves: [Wave],
                         repositories: [RepositoryState],
                         config: Configuration,
                         now: Date = Date()) -> [Project] {

        var byId: [String: ProjectRecord] = [:]
        var pathToId: [String: String] = [:]
        for record in records {
            byId[record.id] = record
            if let path = record.path { pathToId[path] = record.id }
        }

        // Sessions in a directory nobody has recorded create the project, which
        // is how discovery worked before records existed and still has to work.
        for session in sessions {
            guard let path = session.projectPath, pathToId[path] == nil,
                  Self.canBeAProject(path) else { continue }
            let id = ProjectRecord.identifier(forPath: path)
            pathToId[path] = id
            byId[id] = ProjectRecord(id: id,
                                     name: FileSupport.lastComponent(of: path),
                                     path: path,
                                     createdAt: now)
        }

        // Group the evidence.
        var sessionsById: [String: [Session]] = [:]
        for session in sessions {
            guard let path = session.projectPath, let id = pathToId[path] else { continue }
            sessionsById[id, default: []].append(session)
        }
        var wavesById: [String: [Wave]] = [:]
        for wave in waves {
            guard let path = wave.projectPath, let id = pathToId[path] else { continue }
            wavesById[id, default: []].append(wave)
        }
        var reposById: [String: RepositoryState] = [:]
        for repo in repositories {
            if let id = pathToId[repo.path] { reposById[id] = repo }
        }

        var tasksById: [String: [TaskRecord]] = [:]
        for task in tasks {
            guard let projectId = task.projectId else { continue }
            tasksById[projectId, default: []].append(task)
        }

        return byId.values.map { record in
            build(record: record.withLifecycleResolved(now: now),
                  sessions: sessionsById[record.id] ?? [],
                  tasks: tasksById[record.id] ?? [],
                  waves: wavesById[record.id] ?? [],
                  repository: reposById[record.id],
                  config: config,
                  now: now)
        }
        .sorted(by: Self.ordering)
    }

    private func build(record: ProjectRecord,
                       sessions: [Session],
                       tasks: [TaskRecord],
                       waves: [Wave],
                       repository: RepositoryState?,
                       config: Configuration,
                       now: Date) -> Project {

        var brief: ProductBrief?
        var briefs = BriefSet()
        var progress: ProjectProgress?
        var nextSteps: [String] = []
        var scrapedGoal: String?

        if let path = record.path {
            (brief, briefs) = briefReader.read(projectPath: path)
            (progress, nextSteps) = Self.readRoadmap(projectPath: path)
            // Only pay for the scraped fallback when the brief didn't answer.
            if brief?.oneLiner == nil {
                scrapedGoal = contextReader.context(forProjectPath: path, transcriptPath: nil)?.goal
            }
        }

        let lastActivity = ([record.createdAt]
                            + sessions.map(\.lastActivity)
                            + waves.map(\.updatedAt)).max() ?? record.createdAt

        let verdict = Self.status(record: record,
                                  sessions: sessions,
                                  tasks: tasks,
                                  repository: repository,
                                  briefs: briefs,
                                  nextStepCount: nextSteps.count,
                                  lastActivity: lastActivity,
                                  now: now)

        return Project(
            record: record,
            status: verdict.status,
            statusReason: verdict.reason,
            brief: brief,
            briefs: briefs,
            progress: progress,
            nextSteps: nextSteps,
            sessions: DetectionEngine.sortSessions(sessions),
            tasks: tasks.sorted { $0.updatedAt > $1.updatedAt },
            waves: waves.sorted { $0.updatedAt > $1.updatedAt },
            repository: repository,
            lastActivity: lastActivity,
            oneLiner: brief?.oneLiner ?? scrapedGoal
        )
    }

    // MARK: The ladder

    public struct StatusVerdict: Equatable, Sendable {
        public var status: ProjectStatus
        public var reason: String
    }

    /// First match wins, most urgent first. Every branch returns the reason it
    /// fired, so the UI can always explain itself.
    public static func status(record: ProjectRecord,
                              sessions: [Session],
                              tasks: [TaskRecord] = [],
                              repository: RepositoryState?,
                              briefs: BriefSet,
                              nextStepCount: Int,
                              lastActivity: Date,
                              now: Date) -> StatusVerdict {

        // 1 — blocked on you specifically.
        if let repository, repository.needsAttention {
            let count = repository.conflictMarkers.count
            return StatusVerdict(status: .needsYou,
                                 reason: "Converge stalled — \(count) conflict\(count == 1 ? "" : "s")")
        }
        // A task explicitly waiting on a human outranks a merely quiet session:
        // one is a request, the other is an inference.
        let waitingTasks = TaskQueue.needingAHuman(tasks: tasks, now: now)
        if let first = waitingTasks.first {
            let more = waitingTasks.count > 1 ? " (+\(waitingTasks.count - 1) more)" : ""
            let why = first.waitingReason ?? first.waiting?.label ?? "Waiting on you"
            return StatusVerdict(status: .needsYou, reason: "\(why)\(more)")
        }

        let waiting = sessions.filter { $0.status == .needsAttention }
        if !waiting.isEmpty {
            let ranked = AttentionTriage.rank(waiting, now: now)
            // The session's own words first. It used to reach only for the
            // waiting *kind* and fall back to "Quiet and waiting" — so a project
            // row read "Quiet and waiting" directly above a session row saying
            // "Remove uncommitted work. I'm going to fix it on remote". The two
            // disagreed, and the useless one was on top.
            let why = ranked.first?.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
                ?? ranked.first?.waiting?.label
                ?? "Waiting on you"
            let more = waiting.count > 1 ? " (+\(waiting.count - 1) more)" : ""
            return StatusVerdict(status: .needsYou,
                                 reason: "\(ProjectContextReader.truncate(why, to: 70))\(more)")
        }

        // 2 — something is running.
        let live = sessions.filter { $0.status == .working }
        if !live.isEmpty {
            let tool = live.compactMap(\.lastToolName).first
            let detail = tool.map { "running \($0)" } ?? "session active"
            return StatusVerdict(status: .working,
                                 reason: live.count == 1 ? detail : "\(live.count) sessions active")
        }

        // 3 — something you could pick up. Real tasks answer this once they
        //     exist; the roadmap's unchecked items are the stand-in until then.
        let readyTasks = TaskQueue.ready(for: nil, tasks: tasks, now: now)
        if !readyTasks.isEmpty {
            let mine = readyTasks.filter { $0.assignee == .me }.count
            let detail = mine > 0 && mine != readyTasks.count
                ? "\(readyTasks.count) ready, \(mine) yours"
                : "\(readyTasks.count) task\(readyTasks.count == 1 ? "" : "s") ready"
            return StatusVerdict(status: .ready, reason: detail)
        }
        if nextStepCount > 0 {
            return StatusVerdict(status: .ready,
                                 reason: "\(nextStepCount) item\(nextStepCount == 1 ? "" : "s") ready to pick up")
        }

        // 4 — work exists but is waiting on something else.
        let blockedTasks = TaskQueue.blocked(tasks: tasks, now: now)
        if !blockedTasks.isEmpty {
            return StatusVerdict(status: .blocked,
                                 reason: "\(blockedTasks.count) task\(blockedTasks.count == 1 ? "" : "s") waiting on dependencies")
        }
        if let repository, let behind = repository.agentWorktrees.map(\.behind).max(), behind > 0 {
            return StatusVerdict(status: .blocked,
                                 reason: "Agent branches \(behind) commit\(behind == 1 ? "" : "s") behind integration")
        }

        // 5 — quiet, with nothing ready. The failure this app exists to catch.
        let quiet = now.timeIntervalSince(lastActivity)
        if quiet > dormancyWindow {
            let days = Int(quiet / 86_400)
            return StatusVerdict(status: .dormant, reason: "No activity for \(days) days")
        }

        // 6 — nothing above applied, and there's no brief to work from.
        if !briefs.meetsMinimum {
            return StatusVerdict(status: .unbriefed, reason: "No PRODUCT.md — add one to get suggestions")
        }

        return StatusVerdict(status: .ready, reason: "Nothing blocked")
    }

    // MARK: Reading

    /// Progress and next steps from the project's roadmap, in one pass.
    static func readRoadmap(projectPath: String) -> (ProjectProgress?, [String]) {
        let base = URL(fileURLWithPath: projectPath, isDirectory: true)
        for name in ProjectContextReader.nextFiles {
            let url = base.appendingPathComponent(name)
            guard FileSupport.exists(url),
                  let text = FileSupport.readHead(of: url, limit: ProjectContextReader.maxDocBytes)
            else { continue }

            let items = Markdown.taskItems(in: text)
            guard !items.isEmpty else { continue }

            let completed = items.filter(\.isChecked).count
            let next = items.filter { !$0.isChecked }
                .map { ProjectContextReader.truncate($0.text, to: 160) }
            return (ProjectProgress(completed: completed, total: items.count, source: name), next)
        }
        return (nil, [])
    }

    /// Whether a directory should become a project on its own.
    ///
    /// A session run straight from the home directory is a session, not a
    /// project — and left unfiltered it becomes a permanent unbriefed row that
    /// can never be satisfied, because nobody is going to write a product brief
    /// for `~`. An explicitly-added record for such a path is still honoured;
    /// this only governs *automatic* discovery.
    public static func canBeAProject(_ path: String) -> Bool {
        FileSupport.isPlausibleProjectPath(path)
    }

    /// Pinned first, then by urgency, then by recency.
    /// Pinned first, then by what the project needs, then by recency.
    ///
    /// **Recency is compared coarsely, on purpose.** Comparing raw timestamps
    /// let the list reorder between refreshes: several idle projects sharing a
    /// status were separated by fractions of a second, and any re-read that
    /// nudged one timestamp swapped two rows. A list that rearranges itself
    /// under the cursor is unusable for glancing at, which is the only way this
    /// one is used.
    ///
    /// A minute is the granularity at which "more recent" means something here.
    /// Below that it is noise, and ties break on name — deterministic, so equal
    /// projects hold their places across refreshes.
    static func ordering(_ a: Project, _ b: Project) -> Bool {
        if a.record.isPinned != b.record.isPinned { return a.record.isPinned }
        if a.status.sortRank != b.status.sortRank { return a.status.sortRank < b.status.sortRank }

        let aMinute = (a.lastActivity.timeIntervalSince1970 / 60).rounded(.down)
        let bMinute = (b.lastActivity.timeIntervalSince1970 / 60).rounded(.down)
        if aMinute != bMinute { return aMinute > bMinute }

        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}

extension ProjectRecord {
    /// A parked project whose date has passed is active again.
    func withLifecycleResolved(now: Date) -> ProjectRecord {
        var copy = self
        copy.lifecycle = lifecycle.resolved(now: now)
        return copy
    }
}
