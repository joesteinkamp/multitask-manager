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

    /// Last path component of a plain string path, without bridging to `NSString`.
    /// Trailing slashes are ignored, so `/a/b/` and `/a/b` both yield `b`.
    public static func lastComponent(of path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
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

    /// `(deviceId, inode)` for a path, used to notice log rotation. Zeroes when
    /// unavailable, which callers treat as "can't tell" rather than "changed".
    public static func fileIdentity(ofPath path: String) -> (device: UInt64, inode: UInt64) {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path) else { return (0, 0) }
        let device = (attrs[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return (device, inode)
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
