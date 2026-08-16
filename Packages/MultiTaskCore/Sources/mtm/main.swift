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
        subcommands: [Status.self, Projects.self, Show.self, List.self, Watch.self,
                      Waves.self, Roster.self, Doctor.self],
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
