import Foundation

/// A pluggable source of sessions. Implementations scan some part of the system
/// (files, running apps, processes) and return the sessions they find.
///
/// Detectors must be cheap and non-blocking enough to run on a background queue
/// every refresh tick. They should fail soft: if their backing path/app is absent,
/// return an empty array rather than throwing.
protocol SessionDetector {
    /// Stable identifier for the detector, used for enable/disable preferences.
    var id: String { get }

    /// Human-readable name shown in Settings.
    var displayName: String { get }

    /// Scan and return currently-known sessions. Called off the main thread.
    func detect() -> [Session]
}

/// Shared filesystem helpers used by the file-based detectors.
enum DetectorSupport {
    static let fileManager = FileManager.default

    static var homeDirectory: URL {
        // Resolve the *real* home dir even when run from a sandboxed-looking context.
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// Modification date of a file URL, or `.distantPast` if unavailable.
    static func modificationDate(of url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
    }

    /// Contents of a directory (non-recursive), sorted by modification date desc.
    static func contents(of dir: URL) -> [URL] {
        guard let items = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items.sorted { modificationDate(of: $0) > modificationDate(of: $1) }
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
}
