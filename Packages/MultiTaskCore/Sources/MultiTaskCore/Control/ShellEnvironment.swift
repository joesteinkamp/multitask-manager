import Foundation

/// The environment a delegate needs to run, as the user's shell would provide it.
///
/// **The problem this solves bites every Mac app that shells out.** An app
/// launched from Finder inherits `launchd`'s environment, not the user's shell —
/// so `claude` and `codex` are not on `PATH`, `$AI_TOOL_LOG` is unset, and every
/// launch fails with ENOENT for reasons that look like the app being broken.
/// The CLI has the opposite experience, because it was started from a shell, and
/// that difference is exactly why this is easy to miss until it ships.
///
/// So: resolve once by asking the login shell to print its environment, cache
/// the result, and re-resolve if a launch fails as though the cache were stale.
public final class ShellEnvironment: @unchecked Sendable {
    public static let shared = ShellEnvironment()

    private let lock = NSLock()
    private var cached: [String: String]?
    private var resolvedAt: Date?

    /// Ceiling on the login shell, which can be slow if the user's profile is.
    static let timeout: TimeInterval = 10

    public init() {}

    /// The environment to hand a child process.
    ///
    /// Falls back to this process's own environment when the login shell can't
    /// be read — fewer features, never a hard failure.
    public func environment(now: Date = Date()) -> [String: String] {
        lock.lock()
        if let cached { lock.unlock(); return cached }
        lock.unlock()

        let resolved = Self.readLoginShell() ?? ProcessInfo.processInfo.environment
        lock.lock()
        cached = resolved
        resolvedAt = now
        lock.unlock()
        return resolved
    }

    /// Drops the cache, so the next launch re-reads the shell. Called when a
    /// launch fails with "no such file" — the usual cause is a delegate
    /// installed after the app started.
    public func invalidate() {
        lock.lock()
        cached = nil
        resolvedAt = nil
        lock.unlock()
    }

    /// Whether a delegate is actually on the resolved `PATH`.
    public func locate(_ executable: String) -> String? {
        let env = environment()
        guard let path = Self.searchPath(in: env) else { return nil }
        let separator: Character = FileSupport.isWindows ? ";" : ":"
        for directory in path.split(separator: separator) where !directory.isEmpty {
            let candidate = String(directory) + (FileSupport.isWindows ? "\\" : "/") + executable
            if FileSupport.fileManager.isExecutableFile(atPath: FileSupport.nativePath(candidate)) { return candidate }
        }
        return nil
    }

    /// The search path, whatever the platform calls it.
    ///
    /// Windows environment variables are case-insensitive and the value is
    /// conventionally spelled `Path`, but Swift hands back a plain, case-
    /// *sensitive* dictionary — so a literal `env["PATH"]` returns nil there and
    /// every executable lookup silently fails. That is exactly what happened the
    /// first time the Windows CI job ran the suite.
    static func searchPath(in environment: [String: String]) -> String? {
        if let exact = environment["PATH"], !exact.isEmpty { return exact }
        guard let key = environment.keys.first(where: { $0.caseInsensitiveCompare("PATH") == .orderedSame })
        else { return nil }
        let value = environment[key]
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// Runs `$SHELL -l -c printenv` and parses the result.
    static func readLoginShell() -> [String: String]? {
        #if os(Windows)
        // Windows has no login-shell equivalent, and a GUI process there does
        // inherit a usable environment.
        return nil
        #else
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"
        guard FileSupport.fileManager.isExecutableFile(atPath: shell) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // `-l` for the login profile, `-i` deliberately omitted: an interactive
        // shell can print banners and prompt, and this must never block.
        process.arguments = ["-l", "-c", "printenv"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do { try process.run() } catch { return nil }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        var env: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<equals])
            let value = String(line[line.index(after: equals)...])
            guard !key.isEmpty else { continue }
            env[key] = value
        }
        return env.isEmpty ? nil : env
        #endif
    }
}
