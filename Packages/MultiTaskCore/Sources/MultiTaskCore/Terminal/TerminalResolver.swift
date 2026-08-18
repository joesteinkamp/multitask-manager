import Foundation

/// One process, as much of it as this resolution needs.
///
/// Gathered per-platform (Darwin's `sysctl` and `proc_pidinfo` on macOS) and
/// passed in, so everything below is pure and testable on Linux — the same split
/// the detectors use between reading the machine and deciding what it means.
public struct RunningProcess: Sendable, Hashable {
    public var pid: Int32
    public var parentPid: Int32
    /// Absolute path to the executable, when it could be read.
    public var executablePath: String
    /// The process's current working directory, when it could be read.
    public var workingDirectory: String?

    public init(pid: Int32, parentPid: Int32, executablePath: String,
                workingDirectory: String? = nil) {
        self.pid = pid
        self.parentPid = parentPid
        self.executablePath = executablePath
        self.workingDirectory = workingDirectory
    }

    var executableName: String {
        FileSupport.lastComponent(of: executablePath).lowercased()
    }
}

/// Finds the terminal a session is running in.
///
/// **Why a search rather than a stored handle.** A CLI session carries no pid:
/// it is detected from a transcript file, and the harness audit log records a
/// working directory and a session id but no process. So the terminal cannot be
/// remembered when the session is found — it has to be located when you ask to
/// go there, from the processes running at that moment.
public enum TerminalResolver {
    /// Executable names that indicate an agent rather than an ordinary shell.
    ///
    /// Matched on the file name so a version manager's shim path does not defeat
    /// it. `node` is deliberately absent: too many things are node.
    public static let agentExecutables: Set<String> = [
        "claude", "codex", "agy", "agent", "aider", "cursor-agent"
    ]

    /// The agent process working in `projectPath`, if one is running.
    ///
    /// Prefers a recognised agent; falls back to *any* process whose working
    /// directory matches, because a shell sitting in the project is still the
    /// right terminal to send someone to — the session may simply be between
    /// tool calls, or run under a name this list has not learned yet.
    public static func agentProcess(forProjectPath projectPath: String,
                                    among processes: [RunningProcess]) -> RunningProcess? {
        let matches = processes.filter { process in
            guard let cwd = process.workingDirectory else { return false }
            return FileSupport.pathsEqual(cwd, projectPath)
        }
        return matches.first { agentExecutables.contains($0.executableName) } ?? matches.first
    }

    /// Walks up the parent chain from `pid` to the first process the catalog
    /// recognises as a terminal.
    ///
    /// Bounded rather than trusting the tree: a cycle in reported parentage —
    /// which a racing snapshot can produce, since processes exit while it is
    /// being taken — would otherwise loop forever inside a click handler.
    public static func terminal(owning pid: Int32,
                                among processes: [RunningProcess]) -> (TerminalApp, RunningProcess)? {
        var byPid: [Int32: RunningProcess] = [:]
        for process in processes { byPid[process.pid] = process }

        var current = byPid[pid]
        var seen: Set<Int32> = []
        while let process = current, !seen.contains(process.pid) {
            seen.insert(process.pid)
            if let terminal = TerminalCatalog.terminal(forExecutablePath: process.executablePath) {
                return (terminal, process)
            }
            guard process.parentPid > 1 else { break }   // launchd; nothing above it
            current = byPid[process.parentPid]
        }
        return nil
    }

    /// Both steps: the terminal hosting whatever is working in `projectPath`.
    public static func terminal(forProjectPath projectPath: String,
                                among processes: [RunningProcess]) -> (TerminalApp, RunningProcess)? {
        guard let agent = agentProcess(forProjectPath: projectPath, among: processes) else { return nil }
        return terminal(owning: agent.pid, among: processes)
    }
}
