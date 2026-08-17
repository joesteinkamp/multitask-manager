import Foundation
import ArgumentParser
import MultiTaskCore

/// `mtm` — the command-line face of the same engine the menu-bar app runs.
///
/// Building this immediately after the core is the cheapest way to find out
/// whether the engine's API is actually usable by something that isn't the
/// popover. It runs the engine in-process; when the daemon lands, this becomes a
/// client of it without the commands changing.
@main
struct MTM: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mtm",
        abstract: "See every AI coding session you have running.",
        subcommands: [Status.self, Next.self, Tasks.self, Projects.self, Show.self,
                      Log.self, List.self, Watch.self, Waves.self, Roster.self, Doctor.self],
        defaultSubcommand: Status.self
    )
}

/// Options shared by the commands that run a detection pass.
struct EngineOptions: ParsableArguments {
    @Option(name: .long, help: "Path to the harness audit log.")
    var auditLog: String?

    @Flag(name: .long, help: "Skip the git scan, which shells out per repository.")
    var noGit = false

    @Option(name: .long, help: "Seconds of quiet before a session counts as needing attention.")
    var attentionThreshold: Double?

    func configuration() -> Configuration {
        var config = Configuration()
        if let auditLog { config.auditLogPath = FileSupport.expandingTilde(auditLog) }
        if let attentionThreshold { config.attentionThreshold = attentionThreshold }
        if noGit { config.enableWorktrees = false }
        // The CLI is invoked from a shell, so unlike the app it inherits a real
        // environment — including $AI_TOOL_LOG.
        return config
    }

    /// The engine this invocation talks to.
    ///
    /// Everything below goes through `EngineClient` rather than reaching for
    /// `DetectionEngine` directly, so the day a daemon exists this becomes a
    /// connect-or-fall-back and not one line of command code changes.
    func client() -> some EngineClient {
        InProcessEngine(configuration: StaticConfiguration(configuration()))
    }
}

// MARK: - status

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "What needs you right now, in triage order."
    )

    @OptionGroup var options: EngineOptions

    func run() async throws {
        let snapshot = try await options.client().list()
        let projects = snapshot.activeProjects

        guard !projects.isEmpty else {
            print("No projects tracked yet. Start a session in one, or add it with `mtm projects add`.")
            return
        }

        let needing = projects.filter { $0.status == .needsYou }
        if needing.isEmpty {
            print("Nothing is waiting on you across \(projects.count) project\(projects.count == 1 ? "" : "s").")
        } else {
            print("\(needing.count) project\(needing.count == 1 ? "" : "s") need you:\n")
            for project in needing { Render.projectLine(project) }
            print("")
        }

        // Everything else, so one command answers "what's the state of things".
        let rest = projects.filter { $0.status != .needsYou }
        if !rest.isEmpty {
            for project in rest { Render.projectLine(project) }
        }

        let dormant = snapshot.dormantProjects
        if !dormant.isEmpty {
            print("\n\(dormant.count) project\(dormant.count == 1 ? "" : "s") have gone quiet — a stuck project shouts, a forgotten one doesn't.")
        }

        for reason in snapshot.degraded {
            FileHandle.standardError.write(Data("note: \(reason.message)\n".utf8))
        }
    }
}

// MARK: - projects

struct Projects: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Every project, with what each one needs.",
        subcommands: [ProjectsAdd.self, ProjectsArchive.self, ProjectsPark.self]
    )

    @OptionGroup var options: EngineOptions

    @Flag(name: .long, help: "Include archived and parked projects.")
    var all = false

    @Flag(name: .long, help: "Emit JSON. Versioned, and meant for scripts and agents.")
    var json = false

    func run() async throws {
        let snapshot = try await options.client().list()
        let projects = all ? snapshot.projects : snapshot.activeProjects

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(ProjectListPayload(projects: projects,
                                                             refreshedAt: snapshot.refreshedAt))
            print(String(decoding: data, as: UTF8.self))
            return
        }

        guard !projects.isEmpty else {
            print("No projects tracked yet.")
            return
        }
        for project in projects {
            Render.projectLine(project)
            if let one = project.oneLiner { print("      \(ProjectContextReader.truncate(one, to: 88))") }
        }
    }
}

struct ProjectListPayload: Encodable {
    var payloadVersion = 1
    var projects: [Project]
    var refreshedAt: Date
}

struct ProjectsAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Track a project — including one that has no repository yet."
    )

    @Argument(help: "Project name.")
    var name: String

    @Option(name: .long, help: "Repository or working directory, if it has one.")
    var path: String?

    @Option(name: .long, help: "External reference, e.g. linear:ENG-412.")
    var ref: String?

    func run() throws {
        let store = ProjectStore()
        let resolved = path.map { FileSupport.expandingTilde($0) }
        let id = resolved.map(ProjectRecord.identifier(forPath:))
            ?? ProjectRecord.identifier(forName: name)

        store.save(ProjectRecord(id: id, name: name, path: resolved, externalRef: ref))
        print("Tracking \(name) (\(id))")
        if resolved == nil {
            print("No path set — this is an idea, not a checkout. That's allowed.")
        }
    }
}

struct ProjectsArchive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "archive",
        abstract: "Stop a project competing for attention, without deleting it."
    )

    @OptionGroup var options: EngineOptions

    @Argument(help: "Project id or name, or any unique prefix.")
    var id: String

    func run() async throws {
        guard var record = try await Render.resolveRecord(id, options: options) else { return }
        record.lifecycle = .archived
        ProjectStore().save(record)
        print("Archived \(record.name).")
    }
}

struct ProjectsPark: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "park",
        abstract: "Quiet a project until a date, then let it come back on its own."
    )

    @OptionGroup var options: EngineOptions

    @Argument(help: "Project id or name, or any unique prefix.")
    var id: String

    @Option(name: .long, help: "Days to stay quiet.")
    var days: Int = 7

    func run() async throws {
        guard var record = try await Render.resolveRecord(id, options: options) else { return }
        let until = Date().addingTimeInterval(Double(days) * 86_400)
        record.lifecycle = .parked(until: until)
        ProjectStore().save(record)
        print("Parked \(record.name) until \(Format.day(until)).")
    }
}

// MARK: - show

struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Everything about one project."
    )

    @OptionGroup var options: EngineOptions

    @Argument(help: "Project id or name, or any unique prefix.")
    var id: String

    func run() async throws {
        let snapshot = try await options.client().list()
        let matches = snapshot.projects.filter {
            $0.id.hasPrefix(id) || $0.name.lowercased().hasPrefix(id.lowercased())
        }
        guard let project = matches.first, matches.count == 1 else {
            print(matches.isEmpty ? "No project matching \"\(id)\"."
                                  : "\"\(id)\" matches \(matches.count) projects.")
            return
        }

        print(project.name)
        if let one = project.oneLiner { print(one) }
        print("")
        print("Status     \(project.status.label) — \(project.statusReason)")
        if let progress = project.progress {
            print("Progress   \(progress.summary) (\(Int(progress.fraction * 100))%) from \(progress.source)")
        }
        if let path = project.path { print("Path       \(path)") }
        if !project.briefs.meetsMinimum {
            print("Briefs     missing \(project.briefs.missing.joined(separator: ", "))")
        }

        if !project.sessions.isEmpty {
            print("\nSessions")
            for session in project.sessions {
                let age = Format.duration(Date().timeIntervalSince(session.lastActivity))
                print("  \(session.status.label.padded(to: 16)) \(age) ago  \(session.source.label)")
                if let did = session.activity?.summary { print("      \(did)") }
                if let now = session.context?.now { print("      \(ProjectContextReader.truncate(now, to: 88))") }
            }
        }

        if !project.nextSteps.isEmpty {
            print("\nNext")
            for step in project.nextSteps.prefix(5) { print("  · \(step)") }
        }

        if let brief = project.brief, !brief.successMetrics.isEmpty {
            print("\nSuccess metrics")
            for metric in brief.successMetrics.prefix(4) { print("  · \(ProjectContextReader.truncate(metric, to: 88))") }
        }

        if !project.waves.isEmpty {
            print("\nWaves")
            for wave in project.waves {
                print("  \(wave.id) — \(wave.doneCount)/\(wave.delegates.count) delegates done")
            }
        }
    }
}

// MARK: - shared rendering

enum Render {
    static func projectLine(_ project: Project) {
        let badge = project.status.label.padded(to: 12)
        let progress = project.progress.map { " \($0.summary)" } ?? ""
        print("  \(badge) \(project.name.padded(to: 26)) \(project.statusReason)\(progress)")
    }

    /// Resolves a project from the *live snapshot* rather than only from the
    /// store, so a project discovered from a running session can be archived or
    /// parked like any other. The record is written on that action — the refresh
    /// path itself stays read-only.
    ///
    /// Accepts any unique id or name prefix: people and agents alike type what
    /// they were shown, which is rarely the whole id.
    static func resolveRecord(_ prefix: String, options: EngineOptions) async throws -> ProjectRecord? {
        let projects = try await options.client().list().projects
        let needle = prefix.lowercased()
        let matches = projects.filter {
            $0.id.hasPrefix(prefix) || $0.name.lowercased().hasPrefix(needle)
        }
        if matches.count == 1 { return matches[0].record }
        if matches.isEmpty {
            print("No project matching \"\(prefix)\".")
        } else {
            print("\"\(prefix)\" matches \(matches.count): \(matches.map(\.name).joined(separator: ", "))")
        }
        return nil
    }
}

// MARK: - ls

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "Every tracked session."
    )

    @OptionGroup var options: EngineOptions

    @Flag(name: .long, help: "Emit JSON. This output is an API — see payloadVersion.")
    var json = false

    func run() async throws {
        let snapshot = try await options.client().list()

        guard json else {
            for session in snapshot.sessions {
                let age = Format.duration(Date().timeIntervalSince(session.lastActivity))
                print("\(session.status.rawValue.padded(to: 15)) \(session.projectName.padded(to: 24)) \(age) ago  \(session.source.label)")
            }
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let payload = SessionListPayload(sessions: snapshot.sessions,
                                         degraded: snapshot.degraded,
                                         refreshedAt: snapshot.refreshedAt)
        let data = try encoder.encode(payload)
        print(String(decoding: data, as: UTF8.self))
    }
}

/// The `--json` payload is consumed by hooks, scripts and agents, which makes it
/// an interface rather than a debug dump. It carries its own version so a
/// consumer can tell what it is looking at, and the shape doesn't change casually.
struct SessionListPayload: Encodable {
    var payloadVersion = 1
    var sessions: [Session]
    var degraded: [DegradedReason]
    var refreshedAt: Date
}

// MARK: - waves

struct Waves: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Orchestration waves under ~/.ai-context."
    )

    @OptionGroup var options: EngineOptions

    @Flag(name: .long, help: "Include waves untouched for more than a week.")
    var all = false

    func run() async throws {
        let snapshot = try await options.client().list()
        let waves = all ? snapshot.waves : snapshot.activeWaves

        guard !waves.isEmpty else {
            print(all ? "No orchestration waves." : "No active waves. Pass --all to include past ones.")
            return
        }

        for wave in waves {
            let attribution = wave.projectName.map { " (\($0))" } ?? ""
            print("\(wave.id)\(attribution)\(wave.isStale ? "  [past]" : "")")
            if let title = wave.title { print("  \(title)") }
            if let progress = wave.progress { print("  progress: \(progress)") }
            if !wave.delegates.isEmpty {
                print("  delegates: \(wave.doneCount) done, \(wave.activeCount) writing")
                for delegate in wave.delegates {
                    print("    \(delegate.name.padded(to: 14)) \(delegate.state.label)")
                }
            }
            if !wave.artifacts.isEmpty {
                print("  artifacts: \(wave.artifacts.joined(separator: ", "))")
            }
            print("")
        }
    }
}

// MARK: - roster

struct Roster: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delegates this machine can dispatch to, and how they're ranked."
    )

    func run() throws {
        let roster = RosterReader().read()

        print("Delegates:")
        for delegate in roster.delegates {
            let detail = delegate.localModel.map { " — \($0.backend) \($0.model) (\($0.tier))" } ?? ""
            print("  \(delegate.name)\(delegate.isLocal ? " [local]" : "")\(detail)")
        }

        if let updated = roster.routingUpdatedAt {
            let stale = roster.isRoutingStale() ? "  ⚠ older than two months — consider /update-model-routing" : ""
            print("\nRouting table updated \(Format.day(updated))\(stale)")
        }
        for section in roster.routingSections {
            let ranked = section.rankedCLIs
            print("  \(section.title): \(ranked.isEmpty ? "no clear winner" : ranked.joined(separator: " > "))")
        }
        for note in roster.notes {
            FileHandle.standardError.write(Data("note: \(note)\n".utf8))
        }
    }
}

// MARK: - doctor

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "What this machine can and can't see."
    )

    @OptionGroup var options: EngineOptions

    func run() async throws {
        let client = options.client()
        let snapshot = try await client.list()
        let health = try await client.health()

        print("Audit log:      \(health.auditLogPath)")
        print("                \(health.auditRecordsRead) records read, \(health.auditSessionsIndexed) live session(s), \(health.auditMalformedLines) malformed line(s)")
        print("Sessions:       \(health.sessionCount)")
        print("Waiting on you: \(snapshot.needsAttentionCount)")
        print("Waves:          \(snapshot.activeWaves.count) active, \(snapshot.pastWaves.count) past")
        print("Repositories:   \(snapshot.repositories.count) scanned")
        // How many sessions joined the audit log by session id rather than by
        // directory — the number that decides whether status is a fact or a guess.
        print("Precise joins:  \(health.preciseJoins) of \(health.sessionCount)")

        if health.degraded.isEmpty {
            print("\nNo degraded sources.")
        } else {
            print("\nDegraded:")
            for reason in health.degraded { print("  \(reason.detectorId): \(reason.message)") }
        }
    }
}

// MARK: - watch

struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stream status changes until interrupted."
    )

    @OptionGroup var options: EngineOptions

    func run() async throws {
        // A streaming command's output is worthless block-buffered: piped into
        // `grep` or redirected to a file, nothing appears until the buffer fills,
        // and a command that only ever ends by being interrupted never flushes at
        // all. Line buffering is what makes `mtm watch | grep app` behave.
        setvbuf(stdout, nil, _IOLBF, 0)

        let engine = InProcessEngine(configuration: StaticConfiguration(options.configuration()))
        await engine.primeNotifications()
        await engine.start()

        // Only changes arrive here — the engine suppresses a push when the new
        // snapshot matches the last one sent, so a quiet machine stays quiet.
        for await event in engine.subscribe() {
            switch event {
            case .snapshot(let snapshot):
                let stamp = Format.time(snapshot.refreshedAt)
                let waiting = snapshot.needsAttentionCount
                print("\(stamp)  \(snapshot.sessions.count) session(s), \(waiting) waiting")
                for session in snapshot.triageQueue() {
                    print("          \(session.projectName.padded(to: 24)) \(session.waiting?.label ?? "Quiet")")
                }
            case .notify(let notification):
                print("\(Format.time(Date()))  🔔 \(notification.title) — \(notification.body)")
            }
        }
    }
}

// MARK: - formatting

enum Format {
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

extension String {
    /// Pads for column alignment without truncating anything the user needs. An
    /// over-long value keeps a single trailing space so the next column doesn't
    /// run into it.
    func padded(to width: Int) -> String {
        count >= width ? self + " " : self + String(repeating: " ", count: width - count)
    }
}

// MARK: - next

struct Next: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "What to do next — ranked, with the reason."
    )

    @OptionGroup var options: EngineOptions

    @Option(name: .long, help: "Whose queue: me, or a delegate name like claude.")
    var who: String = "me"

    @Option(name: .long, help: "How many to show.")
    var limit: Int = 5

    func run() async throws {
        let snapshot = try await options.client().list()
        let assignee = who == "any" ? nil : Assignee(encoded: who)

        // Blocked-on-a-human comes first: it's a request, not a suggestion.
        let waiting = snapshot.tasksNeedingYou()
        if !waiting.isEmpty {
            print("Waiting on you:")
            for task in waiting.prefix(limit) {
                let why = task.waitingReason ?? task.waiting?.label ?? "Waiting"
                print("  \(String(task.id.prefix(20)).padded(to: 22)) \(task.title)")
                print("  \(String(repeating: " ", count: 22)) \(why)")
            }
            print("")
        }

        let next = snapshot.whatNext(for: assignee, limit: limit)
        guard !next.isEmpty else {
            let owner = assignee?.label ?? "anyone"
            print("Nothing ready for \(owner).")
            if snapshot.tasks.isEmpty {
                print("No tasks yet — `mtm task add \"…\"` to start, or let an agent file them over MCP.")
            } else {
                let blocked = TaskQueue.blocked(tasks: snapshot.tasks).count
                if blocked > 0 { print("\(blocked) task(s) blocked on dependencies.") }
            }
            return
        }

        print("Next for \(assignee?.label ?? "anyone"):")
        for (index, item) in next.enumerated() {
            let marker = index == 0 ? "→" : " "
            print("  \(marker) \(item.task.title)")
            print("     \(item.reason) · \(item.task.state.label) · \(item.task.id)")
            if let acceptance = item.task.acceptance {
                print("     done when: \(ProjectContextReader.truncate(acceptance, to: 80))")
            }
        }
    }
}

// MARK: - tasks

struct Tasks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "task",
        abstract: "The work — yours and your agents'.",
        subcommands: [TaskList.self, TaskAdd.self, TaskShow.self, TaskDone.self,
                      TaskClaim.self, TaskSnooze.self, TaskBlock.self, TaskDelete.self],
        defaultSubcommand: TaskList.self
    )
}

struct TaskList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "Every open task."
    )

    @OptionGroup var options: EngineOptions

    @Option(name: .long, help: "Filter by state.")
    var state: String?

    @Option(name: .long, help: "Filter by assignee: me, or a delegate name.")
    var who: String?

    @Flag(name: .long, help: "Include completed tasks.")
    var all = false

    @Flag(name: .long, help: "Emit JSON for scripts and agents.")
    var json = false

    func run() async throws {
        let snapshot = try await options.client().list()
        var tasks = snapshot.tasks
        if !all { tasks = tasks.filter { $0.state.isOpen } }
        if let state, let parsed = TaskState(rawValue: state) { tasks = tasks.filter { $0.state == parsed } }
        if let who { tasks = tasks.filter { $0.assignee == Assignee(encoded: who) } }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(TaskListPayload(tasks: tasks)), as: UTF8.self))
            return
        }

        guard !tasks.isEmpty else {
            print("No tasks. `mtm task add \"…\"` to start one.")
            return
        }
        let names = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0.name) })
        for task in tasks.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let project = task.projectId.flatMap { names[$0] } ?? "—"
            print("  \(task.state.label.padded(to: 9)) \(task.assignee.label.padded(to: 10)) \(project.padded(to: 20)) \(task.title)")
            if task.waiting != nil {
                print("  \(String(repeating: " ", count: 41))↳ \(task.waitingReason ?? task.waiting!.label)")
            }
        }
    }
}

struct TaskListPayload: Encodable {
    var payloadVersion = 1
    var tasks: [TaskRecord]
}

struct TaskAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add", abstract: "Capture a piece of work."
    )

    @OptionGroup var options: EngineOptions

    @Argument(help: "What needs doing.")
    var title: String

    @Option(name: .long, help: "Project id or name prefix.")
    var project: String?

    @Option(name: .long, help: "me, or a delegate name like claude.")
    var who: String = "me"

    @Option(name: .long, help: "What done means. Strongly recommended.")
    var acceptance: String?

    @Option(name: .long, help: "Task ids this depends on, comma-separated.")
    var deps: String?

    @Option(name: .long, help: "External reference, e.g. linear:ENG-412.")
    var ref: String?

    func run() async throws {
        let client = options.client()
        let snapshot = try await client.list()

        var projectId: String?
        if let project {
            let needle = project.lowercased()
            let matches = snapshot.projects.filter {
                $0.id.hasPrefix(project) || $0.name.lowercased().hasPrefix(needle)
            }
            guard matches.count == 1 else {
                print(matches.isEmpty ? "No project matching \"\(project)\"."
                                      : "\"\(project)\" matches \(matches.count) projects.")
                return
            }
            projectId = matches[0].id
        }

        let result = try await client.act(.createTask(.init(
            title: title,
            projectId: projectId,
            assignee: who,
            acceptance: acceptance,
            deps: deps?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? [],
            externalRef: ref,
            state: "ready"
        )))

        if let created = result.snapshot?.tasks.first(where: { $0.title == title }) {
            print("Added \(created.id)")
            if created.acceptance == nil {
                // Not a failure, but the omission that most reliably produces
                // work delivered wrong and rejected.
                print("No acceptance criteria — consider --acceptance \"…\" so it's clear when this is done.")
            }
        }
    }
}

struct TaskShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "One task in full."
    )

    @OptionGroup var options: EngineOptions

    @Argument(help: "Task id or any unique prefix.")
    var id: String

    func run() async throws {
        let snapshot = try await options.client().list()
        guard let task = resolve(id, in: snapshot.tasks) else { return }

        print(task.title)
        print("")
        print("Id         \(task.id)")
        print("State      \(task.state.label)")
        print("Assignee   \(task.assignee.label)")
        if let project = snapshot.projects.first(where: { $0.id == task.projectId }) {
            print("Project    \(project.name)")
        }
        if let acceptance = task.acceptance { print("Done when  \(acceptance)") }
        if let waiting = task.waiting {
            print("Waiting    \(task.waitingReason ?? waiting.label)")
        }
        if !task.deps.isEmpty {
            let index = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })
            print("Depends on")
            for dep in task.deps {
                let state = index[dep]?.state.label ?? "missing"
                let title = index[dep]?.title ?? dep
                print("  · \(state.padded(to: 9)) \(title)")
            }
        }
        let dependents = snapshot.tasks.filter { $0.deps.contains(task.id) && $0.state.isOpen }
        if !dependents.isEmpty {
            print("Blocks")
            for dep in dependents { print("  · \(dep.title)") }
        }
        if !task.body.isEmpty { print("\n\(task.body)") }
    }
}

struct TaskDone: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "done", abstract: "Mark a task finished."
    )

    @OptionGroup var options: EngineOptions

    @Argument(help: "Task id or any unique prefix.")
    var id: String

    @Option(name: .long, help: "A closing note, appended to the task body.")
    var note: String?

    func run() async throws {
        let client = options.client()
        guard let task = resolve(id, in: try await client.list().tasks) else { return }
        let result = try await client.act(.completeTask(taskId: task.id, note: note))

        print("Done: \(task.title)")
        // Finishing something usually frees something else — say so, because
        // that is the moment the next action is most obvious.
        if let snapshot = result.snapshot {
            if let next = snapshot.whatNext(for: task.assignee, limit: 1).first {
                print("Next: \(next.task.title) — \(next.reason)")
            } else {
                print("Nothing else ready for \(task.assignee.label).")
            }
        }
    }
}

struct TaskClaim: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "claim", abstract: "Take a task, with an expiring lease."
    )

    @OptionGroup var options: EngineOptions

    @Argument(help: "Task id or any unique prefix.")
    var id: String

    @Option(name: .long, help: "Who is taking it.")
    var owner: String = "me"

    func run() async throws {
        let client = options.client()
        guard let task = resolve(id, in: try await client.list().tasks) else { return }
        _ = try await client.act(.claimTask(taskId: task.id, owner: owner))
        print("Claimed \(task.title) for \(owner).")
    }
}

struct TaskSnooze: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snooze", abstract: "Put a task out of the way for a while."
    )

    @OptionGroup var options: EngineOptions

    @Argument(help: "Task id or any unique prefix.")
    var id: String

    @Option(name: .long, help: "Days to stay quiet.")
    var days: Int = 7

    func run() async throws {
        let client = options.client()
        guard let task = resolve(id, in: try await client.list().tasks) else { return }
        _ = try await client.act(.snoozeTask(taskId: task.id, days: days))
        print("Snoozed \(task.title) for \(days) day\(days == 1 ? "" : "s").")
    }
}

struct TaskBlock: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "needs", abstract: "Say a task is waiting on a human."
    )

    @OptionGroup var options: EngineOptions

    @Argument(help: "Task id or any unique prefix.")
    var id: String

    @Argument(help: "approval | question | done | error, or 'none' to clear.")
    var kind: String

    @Option(name: .long, help: "Why, in a few words.")
    var why: String?

    func run() async throws {
        let client = options.client()
        guard let task = resolve(id, in: try await client.list().tasks) else { return }
        _ = try await client.act(.updateTask(.init(
            taskId: task.id,
            waiting: kind == "none" ? "" : kind,
            waitingReason: why
        )))
        print(kind == "none" ? "Cleared: \(task.title)" : "\(task.title) now needs you: \(why ?? kind)")
    }
}

struct TaskDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm", abstract: "Remove a task."
    )

    @OptionGroup var options: EngineOptions

    @Argument(help: "Task id or any unique prefix.")
    var id: String

    func run() async throws {
        let client = options.client()
        guard let task = resolve(id, in: try await client.list().tasks) else { return }
        _ = try await client.act(.deleteTask(taskId: task.id))
        print("Removed \(task.title).")
    }
}

/// Any unique id prefix, or an exact title. People and agents type what they
/// were shown, which is rarely the whole id.
func resolve(_ needle: String, in tasks: [TaskRecord]) -> TaskRecord? {
    if let exact = tasks.first(where: { $0.id == needle }) { return exact }
    let matches = tasks.filter {
        $0.id.hasPrefix(needle) || $0.title.lowercased().hasPrefix(needle.lowercased())
    }
    if matches.count == 1 { return matches[0] }
    print(matches.isEmpty ? "No task matching \"\(needle)\"."
                          : "\"\(needle)\" matches \(matches.count): \(matches.map(\.title).joined(separator: ", "))")
    return nil
}

// MARK: - log

struct Log: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "What happened, and why — the decision record."
    )

    @Option(name: .long, help: "How many entries.")
    var limit: Int = 20

    @Option(name: .long, help: "Restrict to one project id.")
    var project: String?

    func run() throws {
        let decisions = DecisionLog().recent(limit: limit, projectId: project)
        guard !decisions.isEmpty else {
            print("Nothing recorded yet. The log fills as work is filed, handed over, escalated and finished.")
            return
        }
        for decision in decisions {
            print("  \(Format.stamp(decision.at))  \(decision.category.label.padded(to: 11)) \(decision.summary)")
            if decision.actor != "me" {
                print("  \(String(repeating: " ", count: 18))by \(decision.actor)")
            }
        }
    }
}
