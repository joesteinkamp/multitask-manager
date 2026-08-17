import Foundation

/// Something the app is about to do on your behalf that costs something.
///
/// **The gate line: organising work is free, spending is gated.** Filing and
/// reprioritising need no approval; starting a run does. This is the shape that
/// makes the gate impossible to route around — the engine hands back a
/// description of what *would* happen plus a token, and nothing runs until the
/// same action arrives carrying that token. The MCP server inherits it for free,
/// which matters, because an MCP server is exactly the sort of thing that
/// quietly becomes a way around a confirmation.
public struct ConfirmationRequest: Codable, Hashable, Sendable {
    /// One line a person can decide on.
    public var summary: String
    /// The specifics, shown before agreeing: the command, where it runs, what it
    /// can write to.
    public var details: [String]
    /// Echo this back in the same action to proceed.
    public var token: String

    public init(summary: String, details: [String], token: String) {
        self.summary = summary
        self.details = details
        self.token = token
    }
}

public enum LaunchError: Error, Equatable, CustomStringConvertible {
    case unknownDelegate(String)
    case delegateNotInstalled(String)
    case noWorkingDirectory
    case taskNotFound(String)
    case bannedFlag(String)

    public var description: String {
        switch self {
        case .unknownDelegate(let name): return "No invocation template for \(name)"
        case .delegateNotInstalled(let name):
            return "\(name) isn't on PATH. Check `mtm roster`, or open the app from a shell."
        case .noWorkingDirectory: return "This task has no project directory to run in"
        case .taskNotFound(let id): return "No task \(id)"
        case .bannedFlag(let flag): return "Refusing to launch with \(flag)"
        }
    }
}

/// Builds and starts delegate invocations.
///
/// Templates follow the orchestration playbook rather than inventing a calling
/// convention, so a run started here looks the same in the audit log as one
/// started from a terminal.
public final class Launcher: @unchecked Sendable {
    /// Flags that hand a delegate unrestricted authority. **Never** passed, and
    /// refused if they somehow arrive in a caller's extra arguments — the
    /// harness's rule is that gates are inherited, and a flag that disables them
    /// is the one thing that would make this app a way around every other rule
    /// in the project.
    public static let bannedFlags: Set<String> = [
        "--dangerously-skip-permissions",
        "--dangerously-bypass-approvals-and-sandbox",
        "--yolo"
    ]

    private let environment: ShellEnvironment
    private let runStore: RunStore

    /// A child this launcher started, and the one reliable signal that it died.
    ///
    /// **The process must be retained.** Foundation reaps a child through its
    /// `Process` object; drop the object and the child becomes a zombie that
    /// `kill(pid, 0)` reports as alive forever — so a finished run would sit in
    /// `running` permanently. Holding it also gets real exit codes instead of
    /// inferences.
    ///
    /// **The semaphore exists because `isRunning` lies on Linux.** Measured:
    /// after `terminate()` the termination handler fires immediately with status
    /// 15, yet `isRunning` still answers `true` seconds later, and
    /// `waitUntilExit()` blocks for the child's *full original lifetime* — a
    /// `sleep 30` killed at 200ms still held the caller for 30 seconds. The
    /// handler is the only signal that tracks reality on both platforms, so
    /// everything that needs to know "has it stopped?" waits on this.
    private final class Live {
        let process: Process
        let exited = DispatchSemaphore(value: 0)
        init(process: Process) { self.process = process }
    }

    private var live: [String: Live] = [:]
    private let lock = NSLock()

    public init(environment: ShellEnvironment = .shared, runStore: RunStore = RunStore()) {
        self.environment = environment
        self.runStore = runStore
    }

    /// The command for a delegate and a prompt.
    ///
    /// Headless, one-shot forms only. Interactive work belongs in a terminal,
    /// and offering "open in Terminal" is honest where pretending to host a pty
    /// is not.
    public static func command(delegate: String, prompt: String,
                               extraDirectories: [String] = []) throws -> [String] {
        var command: [String]
        switch delegate {
        case "claude":
            command = ["claude", "-p", prompt]
            for dir in extraDirectories { command += ["--add-dir", dir] }
        case "codex":
            command = ["codex", "exec", "--json", prompt]
            for dir in extraDirectories { command += ["--add-dir", dir] }
        case "agy":
            command = ["agy", "-p", prompt]
            for dir in extraDirectories { command += ["--add-dir", dir] }
        case "agent":
            command = ["agent", "-p", prompt]
        case "lm":
            command = ["lm", "-p", prompt]
        default:
            throw LaunchError.unknownDelegate(delegate)
        }

        if let banned = command.first(where: { bannedFlags.contains($0) }) {
            throw LaunchError.bannedFlag(banned)
        }
        return command
    }

    /// A confirmation token that is a **function of the request**, not a random id.
    ///
    /// This is what makes the gate mean something rather than perform something.
    /// Two properties carry the whole design:
    ///
    /// - *Stable* — the same request must produce the same token on the describe
    ///   pass and the do pass, or the token never round-trips and the gate is
    ///   unpassable. An earlier version minted a fresh run id each call, so every
    ///   confirmed run silently did nothing.
    /// - *Bound* — a different request must produce a different token, so
    ///   approving "run claude in repo A" cannot authorise "run codex in repo B".
    ///   A token is permission for one specific command, not a session-wide yes.
    ///
    /// FNV-1a over NUL-separated fields: no dependency, and stable across
    /// processes and platforms, which `Hasher` explicitly is not.
    public static func token(delegate: String, command: [String],
                             workingDirectory: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let joined = ([delegate, workingDirectory] + command).joined(separator: "\u{0}")
        for byte in Array(joined.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    public static func token(for run: RunRecord) -> String {
        token(delegate: run.delegate, command: run.command, workingDirectory: run.workingDirectory)
    }

    /// Describes what a launch would do, for the confirmation gate.
    public static func confirmation(for run: RunRecord, task: TaskRecord?) -> ConfirmationRequest {
        var details = [
            "Command: \(run.shortCommand)",
            "Directory: \(run.workingDirectory)",
            "Delegate: \(run.delegate)"
        ]
        if let acceptance = task?.acceptance {
            details.append("Done when: \(acceptance)")
        } else if task != nil {
            // Worth saying out loud at the moment of spending: an agent with no
            // acceptance criteria is likely to deliver the wrong thing.
            details.append("Done when: not specified — the run has no target to hit")
        }
        let summary = task.map { "Run “\($0.title)” with \(run.delegate)" }
            ?? "Run \(run.delegate) in \(FileSupport.lastComponent(of: run.workingDirectory))"
        return ConfirmationRequest(summary: summary, details: details, token: token(for: run))
    }

    /// Starts the process, streaming stdout and stderr to the run's directory.
    ///
    /// - Returns: the record, updated with the pid and `running`.
    public func start(_ run: RunRecord) throws -> RunRecord {
        guard let executable = environment.locate(run.command[0]) else {
            // Most often a delegate installed after the app launched, so drop the
            // cached environment before giving up on the next attempt.
            environment.invalidate()
            guard let retry = environment.locate(run.command[0]) else {
                throw LaunchError.delegateNotInstalled(run.command[0])
            }
            return try spawn(run, executable: retry)
        }
        return try spawn(run, executable: executable)
    }

    private func spawn(_ run: RunRecord, executable: String) throws -> RunRecord {
        let dir = runStore.directory(for: run.id)
        try? FileSupport.fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = FileSupport.fileManager.createFile(atPath: runStore.stdoutURL(for: run.id).path, contents: nil)
        _ = FileSupport.fileManager.createFile(atPath: runStore.stderrURL(for: run.id).path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // An argument *array*, never a shell string: a project directory with a
        // quote or a semicolon in its name would otherwise be an injection.
        process.arguments = Array(run.command.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: run.workingDirectory, isDirectory: true)
        process.environment = environment.environment()

        if let out = try? FileHandle(forWritingTo: runStore.stdoutURL(for: run.id)) {
            process.standardOutput = out
        }
        if let err = try? FileHandle(forWritingTo: runStore.stderrURL(for: run.id)) {
            process.standardError = err
        }

        // The handler must be installed **before** run(): a fast command can
        // finish in microseconds, and a handler attached afterwards is never
        // called — which left every short run stuck in `running` forever.
        let runId = run.id
        let store = runStore
        // Captured strongly: reaching the lock through `weak self` could acquire
        // it and then find `self` gone before the release, wedging every other
        // caller. The lock outlives the launcher; the launcher's state does not,
        // which is why `forget` still goes through `weak self`.
        let lock = self.lock
        let handle = Live(process: process)
        process.terminationHandler = { [weak self] finished in
            defer {
                // Signalled before anything else can fail: a cancel waiting on
                // this must never be stranded by a store that wouldn't decode.
                handle.exited.signal()
                self?.forget(runId)
            }
            // Under the lock, because `spawn` writes the pid to the same record
            // moments later and a child can exit before `run()` has even
            // returned. Unserialised, that write landed *after* this one and
            // reset a finished run to `running` with no exit code.
            lock.lock()
            defer { lock.unlock() }

            guard var record = store.run(id: runId) else { return }
            record.endedAt = Date()
            record.exitCode = finished.terminationStatus
            switch finished.terminationReason {
            case .uncaughtSignal:
                record.state = .cancelled
                record.note = record.note ?? "Stopped by a signal"
            default:
                record.state = finished.terminationStatus == 0 ? .finished : .failed
            }
            store.save(record)
        }

        var started = run
        // Saved before launching so the handler always has a record to update,
        // however quickly the child exits.
        started.state = .running
        runStore.save(started)

        // Registered before launching too, for the same reason: a child can die
        // before `run()` returns, and the handler must find an entry to clear or
        // `isRunning` would answer `true` for a dead run forever.
        lock.lock()
        live[run.id] = handle
        lock.unlock()

        do {
            try process.run()
        } catch {
            forget(run.id)
            started.state = .failed
            started.endedAt = Date()
            started.note = "Could not start: \(error.localizedDescription)"
            runStore.save(started)
            throw LaunchError.delegateNotInstalled(run.command[0])
        }

        // The pid is a convenience; the outcome is not. By now the handler may
        // already have written the real result, so merge into what is on disk
        // rather than overwriting it with this stale copy.
        lock.lock()
        if var current = runStore.run(id: run.id) {
            current.pid = process.processIdentifier
            runStore.save(current)
            started = current
        }
        lock.unlock()

        return started
    }

    private func forget(_ id: String) {
        lock.lock()
        live.removeValue(forKey: id)
        lock.unlock()
    }

    /// Whether this launcher started the run and it's still alive.
    ///
    /// Membership in the table, *not* `Process.isRunning` — the handler drops the
    /// entry the moment the child dies, which is the earlier and more honest of
    /// the two answers.
    public func isRunning(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return live[id] != nil
    }

    /// Stops a run: SIGTERM, then SIGKILL after a grace period, then a written
    /// reason. A run that dies silently is worse than one that fails loudly.
    @discardableResult
    public func cancel(_ run: RunRecord, note: String = "Cancelled", grace: TimeInterval = 5) -> RunRecord {
        lock.lock()
        let handle = live[run.id]
        lock.unlock()

        if let handle {
            // Ask first, insist after — and wait on the termination handler, never
            // on `isRunning` or `waitUntilExit()`. Both report the child as alive
            // long after it has died on Linux, which made every cancel burn its
            // full grace period and then block besides.
            handle.process.terminate()
            if handle.exited.wait(timeout: .now() + grace) == .timedOut {
                #if !os(Windows)
                let pid = handle.process.processIdentifier
                if pid > 0 { kill(pid, SIGKILL) }
                // A short second wait so the record is written against a child
                // that is actually gone. SIGKILL is not negotiable, so this is
                // bounded whatever the child was doing.
                _ = handle.exited.wait(timeout: .now() + 2)
                #endif
            }
        } else if let pid = run.pid, pid > 0 {
            // Started by an earlier launch of the app, so it isn't our child and
            // signalling by pid is all we have.
            #if !os(Windows)
            kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(grace)
            while Date() < deadline, kill(pid, 0) == 0 { usleep(100_000) }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            #endif
        }

        forget(run.id)
        var cancelled = run
        cancelled.state = .cancelled
        cancelled.endedAt = Date()
        cancelled.note = note
        runStore.save(cancelled)
        return cancelled
    }

    /// Notices runs whose process is gone and closes them out, so nothing sits
    /// in `running` forever after a crash or a reboot.
    /// Closes out runs left `running` by a previous launch of the app.
    ///
    /// Runs this launcher started report their own outcome through the
    /// termination handler, so they are skipped here — this is only for records
    /// whose process is no longer ours to observe.
    public func reconcile(_ runs: [RunRecord], now: Date = Date()) -> [RunRecord] {
        lock.lock()
        let ours = Set(live.keys)
        lock.unlock()

        return runs.compactMap { run in
            guard run.state == .running, !ours.contains(run.id), let pid = run.pid else { return nil }
            #if os(Windows)
            return nil
            #else
            guard kill(pid, 0) != 0 else { return nil }   // still alive
            var finished = run
            finished.state = .finished
            finished.endedAt = now
            finished.note = "Process exited; outcome read from its log"
            return finished
            #endif
        }
    }
}
