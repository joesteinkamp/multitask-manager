import Foundation

/// Filesystem and path helpers shared by every reader in the core.
///
/// Deliberately free of `NSString` bridging and of any Darwin-only API: the core
/// is built and tested on Linux in CI even though the app it serves is macOS-only,
/// and a bridging cast that quietly behaves differently across the two would make
/// the tests worth less than they look.
public enum FileSupport {
    public static let fileManager = FileManager.default

    public static var homeDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// True on platforms whose paths use `\` and compare case-insensitively.
    public static var isWindows: Bool {
        #if os(Windows)
        return true
        #else
        return false
        #endif
    }

    /// Both separators, always. A Windows path can legally contain either, and a
    /// `\`-only or `/`-only split is wrong on exactly the platform it matters on.
    static func isSeparator(_ character: Character) -> Bool {
        character == "/" || character == "\\"
    }

    /// Last path component of a plain string path, without bridging to `NSString`.
    ///
    /// Handles both separators: given `C:\Users\joe\projects\app` a `/`-only
    /// split returns the entire string, which would make every project name on
    /// Windows the full path.
    public static func lastComponent(of path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.count > 1, let last = trimmed.last, isSeparator(last) {
            trimmed = trimmed.dropLast()
        }
        guard let slash = trimmed.lastIndex(where: isSeparator) else { return String(trimmed) }
        return String(trimmed[trimmed.index(after: slash)...])
    }

    /// Compares two paths for equality the way the host filesystem would.
    ///
    /// Case-insensitively on Windows, and with separators normalised, so
    /// `C:/work/app` and `C:\Work\App` are one project rather than two.
    public static func pathsEqual(_ a: String, _ b: String) -> Bool {
        let left = normalise(a), right = normalise(b)
        return isWindows ? left.compare(right, options: .caseInsensitive) == .orderedSame
                         : left == right
    }

    /// Whether `path` is `root` or sits inside it.
    public static func path(_ path: String, isInside root: String) -> Bool {
        let normalisedRoot = normalise(root)
        let normalisedPath = normalise(path)
        if pathsEqual(normalisedPath, normalisedRoot) { return true }
        let prefix = normalisedRoot.hasSuffix("/") ? normalisedRoot : normalisedRoot + "/"
        return isWindows
            ? normalisedPath.lowercased().hasPrefix(prefix.lowercased())
            : normalisedPath.hasPrefix(prefix)
    }

    /// Separators unified and any trailing one dropped, for comparison only —
    /// never for handing back to the filesystem.
    public static func normalise(_ path: String) -> String {
        var result = path.replacingOccurrences(of: "\\", with: "/")
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }

    /// Writes `data` to `url`, preferring an atomic replace but never losing the
    /// write to one.
    ///
    /// **Why this exists.** An atomic write is a temp file plus a rename, and on
    /// Windows that rename loses to a transient sharing violation whenever
    /// something else has the new file open for a moment — a virus scanner on a
    /// CI runner, an indexer on a desktop. The failure is intermittent and
    /// surfaces far from the write, as a file that simply is not there. Three
    /// separate Windows CI failures traced back to exactly this, each looking
    /// like a different bug.
    ///
    /// So: try atomic, retry briefly, then write directly. The fallback gives up
    /// crash-atomicity, which is the right trade here — every reader in this
    /// package already tolerates a truncated or interleaved record, and none of
    /// them tolerates a file that never appeared.
    public static func write(_ data: Data, to url: URL) throws {
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                try data.write(to: url, options: .atomic)
                return
            } catch {
                lastError = error
                // Short, and not on the last pass: whatever holds the file is
                // holding it for milliseconds, not seconds.
                if attempt < 2 { Thread.sleep(forTimeInterval: 0.05) }
            }
        }
        do {
            try data.write(to: url)
        } catch {
            throw lastError ?? error
        }
    }

    public static func write(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }

    /// Root for everything this app owns: projects, tasks, runs, the socket.
    ///
    /// `$MTM_HOME` overrides it, which is what lets tests and demos run against a
    /// throwaway directory instead of the real one. Without an escape hatch, the
    /// only way to try something is to write into the state you actually rely on.
    public static var stateDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["MTM_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: expandingTilde(override), isDirectory: true)
        }
        // A test that constructs a store without passing a directory would
        // otherwise write into the state the user actually relies on — and it
        // did: the decision log accumulated 70KB of test fixtures in a real home
        // before this guard existed. Relying on every test to remember an
        // override is a convention, and conventions are exactly what leaks.
        if isRunningTests {
            return temporaryTestStateDirectory
        }
        return homeDirectory.appendingPathComponent(".multitaskmanager", isDirectory: true)
    }

    /// True when this process is a test bundle rather than the app or the CLI.
    ///
    /// Reads the executable path, which SwiftPM and Xcode both name distinctively,
    /// rather than a variable a test could forget to set.
    static let isRunningTests: Bool = {
        let executable = CommandLine.arguments.first ?? ""
        return executable.hasSuffix(".xctest")
            || executable.contains(".xctest/")
            || lastComponent(of: executable).hasSuffix("PackageTests")
    }()

    /// One throwaway root per test process, so tests still share state with each
    /// other within a run — which some of them rely on — while sharing none of it
    /// with the user.
    private static let temporaryTestStateDirectory: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mtm-tests-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Files that mark a directory as somebody's project rather than somewhere a
    /// command happened to run.
    ///
    /// Deliberately broad — a false negative hides a real project, which is worse
    /// than an extra row — but every entry is something a person puts in a
    /// repository on purpose.
    public static let projectMarkers: Set<String> = [
        ".git", ".hg", ".svn",
        "package.json", "Package.swift", "pyproject.toml", "setup.py", "requirements.txt",
        "Cargo.toml", "go.mod", "Gemfile", "pom.xml", "build.gradle", "build.gradle.kts",
        "composer.json", "mix.exs", "Makefile", "CMakeLists.txt",
        "AGENTS.md", "CLAUDE.md", "PRODUCT.md", "README.md"
    ]

    /// Whether a directory *looks like* a project, as opposed to merely being one
    /// a session ran in.
    ///
    /// Auto-discovery used to accept any working directory, which produced rows
    /// for a scratch folder under `/tmp` and for a skills sub-directory six
    /// levels inside `~/.hermes` — neither of which anyone manages, and one of
    /// which stopped existing the moment the session ended.
    ///
    /// Applies to *discovery only*. A project the user added by hand is a project
    /// because they said so, and is never subject to this.
    public static func looksLikeProject(_ path: String) -> Bool {
        guard isPlausibleProjectPath(path) else { return false }
        let normalised = normalise(path)

        // No special case for temp directories. It was tempting — a scratchpad
        // under /tmp was one of the rows that prompted this — but the marker
        // rule below already rejects a scratchpad, and a repository cloned to
        // /tmp is a real project. An arbitrary location ban would have banned
        // that too, and made this rule untestable besides.

        // Inside a dot-directory: tool state — `.hermes`, `.cache`, `.local` —
        // rather than work. The project's *own* dot-directories are not the
        // question here; this asks whether the path passes *through* one.
        let home = normalise(homeDirectory.path)
        let relative = self.path(normalised, isInside: home)
            ? String(normalised.dropFirst(home.count))
            : normalised
        if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return false }

        return projectMarkers.contains { marker in
            fileManager.fileExists(atPath: normalised + "/" + marker)
        }
    }

    /// Whether a directory is specific enough to be somebody's *project*.
    ///
    /// The home directory becomes a candidate the moment a session runs there,
    /// and so does `/` — but neither is a project, and treating them as one
    /// produces a row nobody can ever satisfy. Note the rule excludes the home
    /// directory and its *ancestors* only: a project living at `/opt/work/repo`
    /// or on an external volume is perfectly normal and must not be filtered out.
    public static func isPlausibleProjectPath(_ candidate: String) -> Bool {
        let trimmed = normalise(candidate)
        guard trimmed != "/", !trimmed.isEmpty else { return false }
        // A bare Windows drive root is the same kind of thing as "/".
        if trimmed.count <= 3, trimmed.dropFirst().hasPrefix(":") { return false }
        let home = normalise(homeDirectory.path)
        if pathsEqual(trimmed, home) { return false }
        // An ancestor of home is a filesystem location, not a project.
        return !Self.path(home, isInside: trimmed)
    }

    /// Expands a leading `~` against the real home directory.
    public static func expandingTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let home = NSHomeDirectory()
        return path == "~" ? home : home + String(path.dropFirst(1))
    }

    /// Modification date of a file, or `.distantPast` when it can't be read.
    ///
    /// Uses `FileManager` attributes rather than `URL.resourceValues` because the
    /// latter's caching semantics differ between Darwin and corelibs Foundation,
    /// and this value feeds the staleness heuristics that decide what the user sees.
    public static func modificationDate(of url: URL) -> Date {
        modificationDate(ofPath: url.path)
    }

    public static func modificationDate(ofPath path: String) -> Date {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date
        else { return .distantPast }
        return date
    }

    public static func fileSize(ofPath path: String) -> UInt64 {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber
        else { return 0 }
        return size.uint64Value
    }

    /// An identity for a file that changes when the file is replaced.
    ///
    /// `(device, inode)` where the platform has them. Windows does not, so this
    /// falls back to `(creationDate, size)` — a rotated log gets a new creation
    /// date, which is the signal the audit reader actually needs. Without the
    /// fallback, rotation would never be detected there and the reader would
    /// hold a stale offset forever.
    public static func fileIdentity(ofPath path: String) -> (device: UInt64, inode: UInt64) {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path) else { return (0, 0) }
        let device = (attrs[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        if device != 0 || inode != 0 { return (device, inode) }

        let created = (attrs[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        return (UInt64(max(0, created)), size)
    }

    /// Directory contents (non-recursive), newest first.
    public static func contents(of dir: URL) -> [URL] {
        guard let items = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items.sorted { modificationDate(of: $0) > modificationDate(of: $1) }
    }

    public static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }

    public static func exists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    /// Reads up to `limit` bytes from the start of a file as UTF-8 text.
    public static func readHead(of url: URL, limit: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limit)) ?? Data()
        return String(data: data, encoding: .utf8)
    }

    /// Reads up to `limit` bytes from the *end* of a file as UTF-8 text. A leading
    /// partial UTF-8 sequence is dropped by the lossy conversion rather than
    /// failing the whole read.
    public static func readTail(of url: URL, limit: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > limit ? size - limit : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

extension String {
    /// The string, unless it is empty — so a blank field falls through to the
    /// next option in a `??` chain rather than showing as nothing at all.
    var nonEmpty: String? { isEmpty ? nil : self }
}
