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
        subcommands: [Status.self, List.self, Watch.self, Waves.self, Roster.self, Doctor.self],
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
        let client = options.client()
        let all = try await client.list()
        let waiting = all.triageQueue()

        if waiting.isEmpty {
            print("Nothing is waiting on you. \(all.sessions.count) session(s) tracked.")
        } else {
            print("\(waiting.count) waiting on you:\n")
            for session in waiting {
                let age = Format.duration(Date().timeIntervalSince(session.lastActivity))
                let why = session.waiting?.label ?? "Quiet"
                print("  \(session.projectName.padded(to: 24)) \(why.padded(to: 18)) \(age) ago")
                if let reason = session.reason, !reason.isEmpty {
                    print("  \(String(repeating: " ", count: 24))\(reason)")
                }
            }
        }

        let stalled = all.repositories.filter(\.needsAttention)
        if !stalled.isEmpty {
            print("\nConverge stalled:")
            for repo in stalled {
                print("  \(repo.name): \(repo.conflictMarkers.joined(separator: ", "))")
            }
        }

        for reason in all.degraded {
            FileHandle.standardError.write(Data("note: \(reason.message)\n".utf8))
        }
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
