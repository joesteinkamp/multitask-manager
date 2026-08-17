import Foundation
import Testing
@testable import MultiTaskCore

@Suite("Launcher — invocations")
struct LauncherCommandTests {

    @Test("Each delegate gets the playbook's headless form")
    func templates() throws {
        #expect(try Launcher.command(delegate: "claude", prompt: "do it") == ["claude", "-p", "do it"])
        #expect(try Launcher.command(delegate: "codex", prompt: "do it") == ["codex", "exec", "--json", "do it"])
        #expect(try Launcher.command(delegate: "agy", prompt: "do it") == ["agy", "-p", "do it"])
        #expect(try Launcher.command(delegate: "lm", prompt: "do it") == ["lm", "-p", "do it"])
    }

    @Test("A context directory is granted the way each tool expects")
    func extraDirectories() throws {
        let command = try Launcher.command(delegate: "claude", prompt: "go",
                                           extraDirectories: ["/ctx"])
        #expect(command.contains("--add-dir"))
        #expect(command.contains("/ctx"))
    }

    @Test("An unknown delegate is refused rather than guessed at")
    func unknownDelegate() {
        #expect(throws: LaunchError.self) {
            _ = try Launcher.command(delegate: "hal9000", prompt: "open the doors")
        }
    }

    @Test("Full-bypass flags are never produced, and are refused if supplied")
    func bannedFlags() throws {
        // The rule the whole project rests on: gates are inherited. A flag that
        // disables them would make this app a way around every other rule.
        for command in ["claude", "codex", "agy", "agent", "lm"].map({
            try! Launcher.command(delegate: $0, prompt: "go")
        }) {
            #expect(!command.contains { Launcher.bannedFlags.contains($0) })
        }
        #expect(Launcher.bannedFlags.contains("--dangerously-skip-permissions"))
        #expect(Launcher.bannedFlags.contains("--yolo"))
    }

    @Test("The confirmation says what would happen, including the target")
    func confirmationIsSpecific() {
        let run = RunRecord(id: "run-1", delegate: "claude",
                            command: ["claude", "-p", "go"],
                            workingDirectory: "/home/user/projects/app")
        var task = TaskRecord(id: "t", title: "Ship it")
        task.acceptance = "Signed and notarised"

        let confirmation = Launcher.confirmation(for: run, task: task)
        #expect(confirmation.summary.contains("Ship it"))
        #expect(confirmation.details.contains { $0.contains("/home/user/projects/app") })
        #expect(confirmation.details.contains { $0.contains("Signed and notarised") })
        // Deliberately *not* the run id. Tying the token to the id made it
        // change on every call, which quietly made the gate unpassable; it must
        // describe the request instead.
        #expect(confirmation.token != run.id)
        #expect(confirmation.token == Launcher.token(for: run))
    }

    @Test("A multi-paragraph prompt is collapsed, so the confirmation stays readable")
    func confirmationIsReadable() {
        // A gate nobody can read is a gate everybody waves through.
        let brief = "# Do the thing\n\nRead TASK.md first.\n\n## Done when\n\nIt works.\n"
        let run = RunRecord(id: "run-1", delegate: "claude",
                            command: ["claude", "-p", brief, "--add-dir", "/ctx"],
                            workingDirectory: "/p")
        let line = run.shortCommand
        #expect(!line.contains("\n"))
        #expect(line.count < 160)
        #expect(line.hasPrefix("claude -p"))
        #expect(line.hasSuffix("--add-dir /ctx"))
        // The whole command is still recorded, just not shown.
        #expect(run.command[2] == brief)
    }

    @Test("Spending with no target to hit is said out loud")
    func missingAcceptanceIsFlaggedAtSpendTime() {
        let run = RunRecord(id: "run-1", delegate: "claude", command: ["claude"], workingDirectory: "/p")
        let confirmation = Launcher.confirmation(for: run, task: TaskRecord(id: "t", title: "Vague"))
        #expect(confirmation.details.contains { $0.contains("not specified") })
    }
}

@Suite("The confirmation gate")
struct ConfirmationGateTests {

    /// An engine wired to throwaway stores, with a project that has a directory.
    private func engine(_ dir: TempDir) throws -> (InProcessEngine, TaskStore, String) {
        let projectStore = ProjectStore(directory: dir.url.appendingPathComponent("projects"))
        let taskStore = TaskStore(directory: dir.url.appendingPathComponent("tasks"))
        let runStore = RunStore(directory: dir.url.appendingPathComponent("runs"))

        let projectPath = dir.makeDirectory("app").path
        let record = ProjectRecord(id: "app-1", name: "app", path: projectPath)
        projectStore.save(record)

        let engine = InProcessEngine(
            configuration: StaticConfiguration(.fixtureOnly),
            engine: DetectionEngine(configuration: StaticConfiguration(.fixtureOnly),
                                    projectStore: projectStore, taskStore: taskStore),
            overridesStore: OverridesStore(directory: dir.url.appendingPathComponent("state")),
            taskStore: taskStore,
            decisions: DecisionLog(directory: dir.url),
            runStore: runStore,
            launcher: Launcher(runStore: runStore),
            auditWriter: AuditWriter(path: dir.path("audit.jsonl"))
        )
        return (engine, taskStore, "app-1")
    }

    @Test("Running without confirmation does nothing and explains what it would do")
    func unconfirmedRunIsInert() async throws {
        let dir = TempDir()
        let (engine, taskStore, projectId) = try engine(dir)
        _ = try taskStore.save(TaskRecord(id: "t1", title: "Ship it", projectId: projectId,
                                          assignee: .agent("claude"), state: .ready,
                                          acceptance: "Signed"))

        let result = try await engine.act(.runTask(taskId: "t1", delegate: nil, confirm: nil))

        #expect(result.ok == false)
        #expect(result.needsConfirmation)
        #expect(result.confirmation?.summary.contains("Ship it") == true)
        // Nothing was spawned, and nothing was recorded as a run.
        #expect(await engine.runs().isEmpty)
        // The task was not claimed either.
        #expect(taskStore.task(id: "t1")?.state == .ready)
    }

    @Test("A wrong token is refused, so the gate can't be waved through")
    func wrongTokenRefused() async throws {
        let dir = TempDir()
        let (engine, taskStore, projectId) = try engine(dir)
        _ = try taskStore.save(TaskRecord(id: "t1", title: "Ship it", projectId: projectId,
                                          assignee: .agent("claude"), state: .ready))

        let result = try await engine.act(.runTask(taskId: "t1", delegate: nil,
                                                    confirm: "not-the-token"))
        #expect(result.needsConfirmation)
        #expect(await engine.runs().isEmpty)
    }

    @Test("A task with no project directory can't be run at all")
    func noDirectory() async throws {
        let dir = TempDir()
        let (engine, taskStore, _) = try engine(dir)
        _ = try taskStore.save(TaskRecord(id: "loose", title: "Nowhere", state: .ready))

        await #expect(throws: LaunchError.self) {
            _ = try await engine.act(.runTask(taskId: "loose", delegate: nil, confirm: nil))
        }
    }

    @Test("Provisioning is gated too, and preflights before it asks")
    func provisionGated() async throws {
        let dir = TempDir()
        let (engine, taskStore, projectId) = try engine(dir)
        _ = try taskStore.save(TaskRecord(id: "t1", title: "Port it", projectId: projectId))

        // The fixture project isn't a git repository, so preflight must refuse —
        // there is no point confirming something that cannot happen.
        await #expect(throws: ProvisionError.self) {
            _ = try await engine.act(.provisionIsolation(taskId: "t1", agent: "claude", confirm: nil))
        }
    }

    // MARK: The token itself
    //
    // The gate was silently broken: the token was a freshly minted run id, so it
    // changed between the describe pass and the do pass and could never match.
    // Every confirmed run was refused, and the CLI exited 0 saying nothing. The
    // suite above passed throughout, because it only ever tested refusal — which
    // is what a broken gate does perfectly.

    @Test("The same request always produces the same token")
    func tokenIsStable() {
        let first = Launcher.token(delegate: "claude", command: ["claude", "-p", "go"],
                                   workingDirectory: "/repo")
        let second = Launcher.token(delegate: "claude", command: ["claude", "-p", "go"],
                                    workingDirectory: "/repo")
        #expect(first == second)
        #expect(!first.isEmpty)
    }

    @Test("A token is bound to its command, delegate, and directory")
    func tokenIsBound() {
        let base = Launcher.token(delegate: "claude", command: ["claude", "-p", "go"],
                                  workingDirectory: "/repo")
        // Approving one run must never authorise a different one.
        #expect(base != Launcher.token(delegate: "codex", command: ["claude", "-p", "go"],
                                       workingDirectory: "/repo"))
        #expect(base != Launcher.token(delegate: "claude", command: ["claude", "-p", "rm -rf /"],
                                       workingDirectory: "/repo"))
        #expect(base != Launcher.token(delegate: "claude", command: ["claude", "-p", "go"],
                                       workingDirectory: "/somewhere-else"))
    }

    /// Fields are NUL-separated so regrouping the same characters across
    /// arguments cannot collide — otherwise `["a", "bc"]` and `["ab", "c"]` would
    /// share a token, and an argument split is exactly how an injected flag
    /// would arrive.
    @Test("Regrouping the same characters across arguments changes the token")
    func tokenResistsRegrouping() {
        #expect(Launcher.token(delegate: "x", command: ["a", "bc"], workingDirectory: "/r")
                != Launcher.token(delegate: "x", command: ["ab", "c"], workingDirectory: "/r"))
    }

    @Test("Describing a run twice offers the same token, so it can be confirmed")
    func gateRoundTrips() async throws {
        let dir = TempDir()
        let (engine, taskStore, projectId) = try engine(dir)
        _ = try taskStore.save(TaskRecord(id: "t1", title: "Ship it", projectId: projectId,
                                          assignee: .agent("claude"), state: .ready))

        let first = try await engine.act(.runTask(taskId: "t1", delegate: "claude", confirm: nil))
        let second = try await engine.act(.runTask(taskId: "t1", delegate: "claude", confirm: nil))

        let token = try #require(first.confirmation?.token)
        // The bug: these differed, so the token was already stale by the time the
        // user had finished reading what they were agreeing to.
        #expect(second.confirmation?.token == token)
        #expect(await engine.runs().isEmpty)
    }

    @Test("A token for one delegate does not authorise another")
    func tokenIsNotTransferable() async throws {
        let dir = TempDir()
        let (engine, taskStore, projectId) = try engine(dir)
        _ = try taskStore.save(TaskRecord(id: "t1", title: "Ship it", projectId: projectId,
                                          assignee: .agent("claude"), state: .ready))

        let claude = try await engine.act(.runTask(taskId: "t1", delegate: "claude", confirm: nil))
        let borrowed = try #require(claude.confirmation?.token)
        let attempt = try await engine.act(.runTask(taskId: "t1", delegate: "codex", confirm: borrowed))

        #expect(attempt.needsConfirmation)
        #expect(await engine.runs().isEmpty)
    }

    @Test("The literal “yes” is not a password")
    func literalYesIsNotAPassword() async throws {
        let dir = TempDir()
        let (engine, taskStore, projectId) = try engine(dir)
        _ = try taskStore.save(TaskRecord(id: "t1", title: "Ship it", projectId: projectId,
                                          assignee: .agent("claude"), state: .ready))

        // It used to be, in both gated paths — a literal that always passes is a
        // bypass, and an MCP server is exactly the caller that would find it.
        let result = try await engine.act(.runTask(taskId: "t1", delegate: "claude", confirm: "yes"))
        #expect(result.needsConfirmation)
        #expect(await engine.runs().isEmpty)
    }

}

@Suite("Provisioner")
struct ProvisionerTests {

    @Test("Worktree paths follow the sibling convention")
    func worktreePaths() {
        #expect(Provisioner.worktreePath(repository: "/home/joe/projects/app", agent: "claude")
                == "/home/joe/projects/app-claude")
        #expect(Provisioner.branchName(for: "codex") == "ai/codex")
    }

    @Test("Preflight refuses a directory that isn't a repository")
    func notARepo() {
        let dir = TempDir()
        dir.makeDirectory("plain")
        #expect(throws: ProvisionError.self) {
            try Provisioner().preflight(repository: dir.path("plain"), agent: "claude")
        }
    }

    @Test("The ownership marker is what lets the app write into a context dir")
    func ownershipMarker() {
        let dir = TempDir()
        let provisioner = Provisioner(contextRoot: dir.url)
        dir.makeDirectory("someone-elses")
        // Without the marker the app must not claim the directory — otherwise it
        // would fight a live orchestrating session for STATE.md.
        #expect(!provisioner.owns(contextDirectory: dir.path("someone-elses")))

        dir.write("created by mtm\n", to: "ours/\(Provisioner.ownershipMarker)")
        #expect(provisioner.owns(contextDirectory: dir.path("ours")))
    }

    @Test("The brief opens and closes the way the playbook tells delegates to expect")
    func briefFollowsThePlaybook() {
        var task = TaskRecord(id: "t", title: "Port the engine")
        task.body = "Make it build on Windows."
        task.acceptance = "swift test passes on windows-latest"

        let brief = Provisioner.brief(task: task, agent: "codex", contextDirectory: "/ctx")
        #expect(brief.contains("Read `TASK.md` and `STATE.md`"))
        #expect(brief.contains("write your full results".lowercased())
                || brief.contains("Write your full results"))
        #expect(brief.contains("agents/codex.md"))
        #expect(brief.contains("swift test passes"))
    }
}

@Suite("AuditWriter")
struct AuditWriterTests {

    @Test("Records use the harness's exact field names")
    func recordShape() throws {
        let dir = TempDir()
        let writer = AuditWriter(path: dir.path("tool-calls.jsonl"))
        let run = RunRecord(id: "run-1", taskId: "t1", delegate: "claude",
                            command: ["claude", "-p", "go"], workingDirectory: "/home/user/app")
        writer.recordStart(run)

        let text = try String(contentsOf: dir.url.appendingPathComponent("tool-calls.jsonl"),
                              encoding: .utf8)
        let record = try #require(try JSONSerialization.jsonObject(
            with: Data(text.split(separator: "\n")[0].utf8)) as? [String: Any])

        // A near-miss on these names produces records that parse but never
        // display, which is worse than failing outright.
        #expect(record["tool"] as? String == "mtm")
        #expect(record["event"] as? String == "PreToolUse")
        #expect(record["tool_name"] as? String == "run")
        #expect(record["session"] as? String == "run-1")
        #expect(record["cwd"] as? String == "/home/user/app")
        #expect(record["ts"] != nil)
    }

    @Test("The app's own reader can parse what its writer produced")
    func roundTripsThroughOurOwnReader() throws {
        let dir = TempDir()
        let path = dir.path("tool-calls.jsonl")
        let writer = AuditWriter(path: path)
        var run = RunRecord(id: "run-2", delegate: "codex", command: ["codex"],
                            workingDirectory: "/home/user/app")
        writer.recordStart(run)
        run.state = .finished
        run.exitCode = 0
        writer.recordEnd(run)

        // The strongest check available: the reader that consumes the harness's
        // log accepts these as ordinary records.
        let index = AuditLogReader(path: path).refresh()
        #expect(index.malformedLines == 0)
        #expect(index.recordsRead == 2)
        #expect(index.bySession["run-2"]?.eventCount == 2)
        #expect(index.bySession["run-2"]?.tool == "mtm")
    }

    @Test("A missing log is created rather than losing the record")
    func createsLog() {
        let dir = TempDir()
        let path = dir.path("nested/deep/tool-calls.jsonl")
        AuditWriter(path: path).record(event: "PreToolUse", toolName: "run",
                                       session: "s", cwd: nil, input: "x")
        #expect(FileManager.default.fileExists(atPath: path))
    }
}

@Suite("RunStore")
struct RunStoreTests {

    @Test("A run round-trips, command included, so it can be explained later")
    func roundTrip() throws {
        let dir = TempDir()
        let store = RunStore(directory: dir.url)
        var run = RunRecord(id: "run-1", taskId: "t1", delegate: "claude",
                            command: ["claude", "-p", "go"], workingDirectory: "/p")
        run.state = .finished
        run.exitCode = 0
        store.save(run)

        let loaded = try #require(store.load().first)
        #expect(loaded.command == ["claude", "-p", "go"])
        #expect(loaded.state == .finished)
        #expect(loaded.displayCommand == "claude -p go")
    }

    @Test("Output goes to files in the run's own directory")
    func outputPaths() {
        let dir = TempDir()
        let store = RunStore(directory: dir.url)
        #expect(store.stdoutURL(for: "run-1").lastPathComponent == "stdout.log")
        #expect(store.stderrURL(for: "run-1").lastPathComponent == "stderr.log")
        #expect(store.stdoutURL(for: "run-1").path.contains("run-1"))
    }

    @Test("Run ids are unique and sortable")
    func identifiers() {
        let a = RunRecord.identifier()
        let b = RunRecord.identifier()
        #expect(a.hasPrefix("run-"))
        #expect(a != b)
    }
}

@Suite("ShellEnvironment")
struct ShellEnvironmentTests {

    @Test("Resolves an environment with a PATH, one way or another")
    func resolves() {
        // On this machine the login shell works; where it doesn't, the fallback
        // to the current process's environment must still yield something usable
        // rather than an empty dictionary.
        let env = ShellEnvironment().environment()
        #expect(env["PATH"] != nil)
    }

    @Test("Locates an executable that exists, and doesn't invent one that doesn't")
    func locate() {
        let shell = ShellEnvironment()
        #expect(shell.locate("sh") != nil || shell.locate("ls") != nil)
        #expect(shell.locate("definitely-not-a-real-binary-xyz") == nil)
    }
}

@Suite("Launcher — spawning for real")
struct LauncherSpawnTests {

    /// Exercises the actual process path — redirection, pid capture, reconcile —
    /// with a harmless command rather than a real delegate. The template layer is
    /// tested separately; this is about whether the plumbing works.
    private func harmlessRun(_ dir: TempDir, command: [String]) -> RunRecord {
        RunRecord(id: "run-test-\(UUID().uuidString.prefix(6))",
                  delegate: "test", command: command,
                  workingDirectory: dir.url.path)
    }

    @Test("Output is captured to the run's own files")
    func capturesOutput() throws {
        let dir = TempDir()
        let store = RunStore(directory: dir.url.appendingPathComponent("runs"))
        let launcher = Launcher(runStore: store)

        let started = try launcher.start(harmlessRun(dir, command: ["sh", "-c", "echo hello-from-run"]))
        #expect(started.pid != nil)
        // NOT `== .running`. `start` returns the record as it stands on disk, and
        // `echo` can be reaped before `start` returns — the termination handler
        // then has the truer answer. Asserting `.running` made this test flaky
        // roughly one run in twenty, and it was the assertion that was wrong:
        // reporting a finished child as running to win a race would be worse.
        #expect(started.state == .running || started.state.isTerminal)

        // Give the child a moment to finish and flush.
        var tail: String?
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.05)
            tail = store.tail(of: started.id)
            if tail?.contains("hello-from-run") == true { break }
        }
        #expect(tail?.contains("hello-from-run") == true)
    }

    @Test("A command that isn't installed fails with a usable message")
    func missingExecutable() {
        let dir = TempDir()
        let launcher = Launcher(runStore: RunStore(directory: dir.url))
        let run = harmlessRun(dir, command: ["definitely-not-a-real-binary-xyz"])

        let error = expectError(LaunchError.self) { _ = try launcher.start(run) }
        // The message has to say what to do, not just that something went wrong.
        #expect(error?.description.contains("PATH") == true)
    }

    @Test("A run left behind by a previous app launch is closed out")
    func reconcileClosesOrphanedRuns() {
        let dir = TempDir()
        let launcher = Launcher(runStore: RunStore(directory: dir.url))
        // A record whose pid belongs to nothing — what a crash or reboot leaves.
        var orphan = RunRecord(id: "run-old", delegate: "claude", command: ["claude"],
                               workingDirectory: dir.url.path)
        orphan.state = .running
        orphan.pid = 999_999

        let closed = launcher.reconcile([orphan])
        #expect(closed.first?.state == .finished)
        #expect(closed.first?.note?.contains("exited") == true)
    }

    @Test("Cancelling stops a long-running process")
    func cancelStops() throws {
        let dir = TempDir()
        let store = RunStore(directory: dir.url.appendingPathComponent("runs"))
        let launcher = Launcher(runStore: store)

        let started = try launcher.start(harmlessRun(dir, command: ["sh", "-c", "sleep 30"]))
        let pid = try #require(started.pid)
        let cancelled = launcher.cancel(started, note: "test", grace: 2)

        #expect(cancelled.state == .cancelled)
        #expect(cancelled.note == "test")
        // Genuinely stopped, not merely marked. `isRunning` is the honest check:
        // a reaped child's pid can linger as a zombie, which is exactly the trap
        // that made an earlier version of cancel() always burn its full grace.
        #expect(!launcher.isRunning(started.id))
        _ = pid
    }

    @Test("A finished run reports its real exit code, not an inferred one")
    func exitCodeIsReal() throws {
        let dir = TempDir()
        let store = RunStore(directory: dir.url.appendingPathComponent("runs"))
        let launcher = Launcher(runStore: store)

        let started = try launcher.start(harmlessRun(dir, command: ["sh", "-c", "exit 3"]))
        var record = try #require(store.run(id: started.id))
        for _ in 0..<80 {
            Thread.sleep(forTimeInterval: 0.05)
            record = try #require(store.run(id: started.id))
            if record.state.isTerminal { break }
        }
        #expect(record.state == .failed)
        #expect(record.exitCode == 3)
        #expect(record.endedAt != nil)
    }

    @Test("A successful run is recorded as finished")
    func successRecorded() throws {
        let dir = TempDir()
        let store = RunStore(directory: dir.url.appendingPathComponent("runs"))
        let launcher = Launcher(runStore: store)

        let started = try launcher.start(harmlessRun(dir, command: ["sh", "-c", "exit 0"]))
        for _ in 0..<80 {
            Thread.sleep(forTimeInterval: 0.05)
            if store.run(id: started.id)?.state.isTerminal == true { break }
        }
        #expect(store.run(id: started.id)?.state == .finished)
        #expect(store.run(id: started.id)?.exitCode == 0)
    }
}
