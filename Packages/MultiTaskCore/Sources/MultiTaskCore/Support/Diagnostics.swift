import Foundation

/// A rolling record of the decisions this app made, meant to be pasted to
/// someone who is trying to work out why it behaved as it did.
///
/// **Why decisions rather than events.** Every hard bug in this project so far
/// has been a wrong *conclusion* from correct data: a quiet transcript read as
/// "needs attention", a scratch directory accepted as a project, a worktree
/// treated as its own repository. A log of what happened would have shown none
/// of them. A log of what was concluded, and from which evidence, shows all
/// four immediately.
///
/// So the unit here is a verdict and its reason, and the categories are the
/// places verdicts get made.
///
/// **What it deliberately does not contain:** prompt text, tool inputs, tool
/// results, file contents, or anything from the audit log's `input` and
/// `response` fields. Paths and project names are included, because they are
/// usually the bug. It is written to be shareable without reading it first —
/// though `redacting` still takes the home directory out.
public final class Diagnostics: @unchecked Sendable {
    public static let shared = Diagnostics()

    /// Where a decision was made.
    public enum Category: String, Sendable, CaseIterable {
        /// Which directories became projects, and which were turned away.
        case projects
        /// How a session's status was decided, and from what evidence.
        case status
        /// What the detectors found, and what they could not read.
        case detection
        /// Hook status files: found, parsed, ignored.
        case hooks
        /// Finding the terminal a session runs in.
        case terminal
        /// Starting, cancelling, and approving runs.
        case control
    }

    public struct Entry: Sendable {
        public var at: Date
        public var category: Category
        public var message: String
    }

    /// Kept small on purpose. This is for "what just happened", and a buffer big
    /// enough to hold a week is one nobody will read or paste.
    public static let capacity = 500

    private let lock = NSLock()
    private var entries: [Entry] = []
    /// Off under a test bundle: a suite would otherwise fill the buffer with
    /// several hundred reports about its own fixtures, and the one real entry
    /// anyone wanted would have scrolled away.
    private var enabled = !FileSupport.isRunningTests
    private var handle: FileHandle?
    private var written: UInt64 = 0

    /// Where the log is kept between launches.
    ///
    /// **In memory is not enough.** The buffer holds the last few hundred
    /// decisions, which is the wrong window for the actual workflow: a bug is
    /// noticed, the app runs on for an hour, and by the time anyone looks the
    /// evidence has rolled out — or the app was restarted and it is gone
    /// entirely. A file survives both, and can simply be sent.
    public static var defaultFile: URL {
        FileSupport.stateDirectory.appendingPathComponent("diagnostics.log")
    }

    /// Beyond this the file rotates. Small enough to attach to a message, large
    /// enough to hold a day of ordinary use.
    public static let maxFileBytes: UInt64 = 2 * 1024 * 1024

    public init() {}

    /// Records a decision and the reason for it.
    ///
    /// - Parameter message: written to be read by someone who did not write the
    ///   code — "accepted /Users/joe/dev/app (has .git)", not "ensure: ok".
    public func record(_ category: Category, _ message: @autoclosure () -> String,
                       at: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }
        let entry = Entry(at: at, category: category, message: message())
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        appendToFile(entry)
    }

    /// Appends one line, so the log survives a quit and outlives the buffer.
    ///
    /// Failures are swallowed deliberately: a diagnostics log that can break the
    /// app it is diagnosing is worse than no log.
    private func appendToFile(_ entry: Entry) {
        guard let file = fileHandle() else { return }
        let line = "\(Self.stamp(entry.at))  \(entry.category.rawValue.padded(to: 9))  \(entry.message)\n"
        guard let data = Self.redacting(line).data(using: .utf8) else { return }
        try? file.write(contentsOf: data)
        written += UInt64(data.count)
        if written >= Self.maxFileBytes { rotate() }
    }

    private func fileHandle() -> FileHandle? {
        if let handle { return handle }
        let url = Self.defaultFile
        try? FileSupport.fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
        if !FileSupport.fileManager.fileExists(atPath: url.path) {
            _ = FileSupport.fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let opened = try? FileHandle(forWritingTo: url) else { return nil }
        written = (try? opened.seekToEnd()) ?? 0
        handle = opened
        return opened
    }

    /// Keeps one previous file, so a rotation mid-investigation does not destroy
    /// the thing being investigated.
    private func rotate() {
        try? handle?.close()
        handle = nil
        written = 0
        let current = Self.defaultFile
        let previous = current.deletingLastPathComponent().appendingPathComponent("diagnostics.1.log")
        try? FileSupport.fileManager.removeItem(at: previous)
        try? FileSupport.fileManager.moveItem(at: current, to: previous)
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    public var recent: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }

    /// Turned off for tests, so a suite does not accumulate half a million
    /// entries reporting on its own fixtures.
    public func setEnabled(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        enabled = value
    }

    /// The whole log as text, ready to paste.
    ///
    /// - Parameter header: a few lines of context — versions, counts, what is
    ///   configured. A log without them produces a round of "and what does
    ///   `mtm doctor` say", which is the round this exists to remove.
    public func export(header: [String] = [], only: Category? = nil,
                       now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"

        var out = ["# MultiTask Manager diagnostics", "# \(now)"]
        out += header.map { "# \($0)" }
        out.append("#")
        out.append("# Decisions, newest last. No prompt text, tool input, or file")
        out.append("# contents are recorded; paths are, because they are usually the bug.")
        out.append("")

        let all = only.map { category in recent.filter { $0.category == category } } ?? recent
        if all.isEmpty {
            out.append("(nothing recorded yet — open the app and let it refresh once)")
        }
        for entry in all {
            out.append("\(Self.stamp(entry.at))  \(entry.category.rawValue.padded(to: 9))  \(entry.message)")
        }
        out.append("")
        out.append("# Full history, including previous launches: \(Self.defaultFile.path)")
        return Self.redacting(out.joined(separator: "\n"))
    }

    /// Replaces the home directory with `~`.
    ///
    /// Not security — the paths themselves are the point — but a log pasted into
    /// a chat should not lead with someone's account name on every line.
    public static func redacting(_ text: String) -> String {
        let home = FileSupport.normalise(FileSupport.homeDirectory.path)
        guard home.count > 1 else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }
}

extension String {
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
