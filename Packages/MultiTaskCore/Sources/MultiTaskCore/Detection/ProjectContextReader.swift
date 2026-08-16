import Foundation

/// Builds a `ProjectContext` for a session by reading plain markdown/transcript
/// files — no intelligence, just parsing. Results are cached and only rebuilt when
/// one of the underlying files changes (compared by modification time), so it's
/// cheap to call every refresh tick.
///
/// Intended to run off the main thread (it does file I/O); the cache is guarded by
/// a lock so it's safe to share.
public final class ProjectContextReader: @unchecked Sendable {
    public static let shared = ProjectContextReader()

    /// Candidate files for the project GOAL, in priority order. The first one that
    /// yields a usable paragraph wins.
    public static let goalFiles = ["README.md", "CLAUDE.md", "AGENTS.md", "PROJECT.md", "PRODUCT.md", "GOAL.md"]

    /// Candidate files for NEXT steps, scanned in order for unchecked tasks.
    public static let nextFiles = ["ROADMAP.md", "TODO.md"]

    /// How many upcoming tasks to surface under "Next".
    public static let maxNextItems = 3

    /// Cap on bytes read from any single doc so a huge file can't stall a tick.
    static let maxDocBytes = 64 * 1024
    /// Window read from the tail of a transcript when hunting for the last prompt.
    static let transcriptTailBytes: UInt64 = 128 * 1024

    private struct CacheEntry {
        var signature: String
        var context: ProjectContext
    }

    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]

    public init() {}

    // MARK: Public API

    /// Returns copies of `sessions` with `context` populated. Sessions without a
    /// project path or transcript get an unchanged copy.
    public func attach(to sessions: [Session]) -> [Session] {
        sessions.map { session in
            var copy = session
            copy.context = context(forProjectPath: session.projectPath,
                                   transcriptPath: session.transcriptPath)
            return copy
        }
    }

    /// Builds (or returns a cached) context for a project folder + optional
    /// transcript. Returns `nil` when nothing useful could be read.
    public func context(forProjectPath path: String?, transcriptPath: String?) -> ProjectContext? {
        guard path != nil || transcriptPath != nil else { return nil }

        // A signature over the mtimes of every file we'd read. If unchanged since
        // last time, the cached context is still valid.
        var sigParts: [String] = []
        var goalCandidates: [URL] = []
        var nextCandidates: [URL] = []

        if let dir = path {
            let base = URL(fileURLWithPath: dir, isDirectory: true)
            for name in Self.goalFiles {
                let url = base.appendingPathComponent(name)
                if FileSupport.exists(url) {
                    goalCandidates.append(url)
                    sigParts.append(signaturePart(url))
                }
            }
            for name in Self.nextFiles {
                let url = base.appendingPathComponent(name)
                if FileSupport.exists(url) {
                    nextCandidates.append(url)
                    sigParts.append(signaturePart(url))
                }
            }
        }
        if let t = transcriptPath {
            sigParts.append(signaturePart(URL(fileURLWithPath: t)))
        }

        let cacheKey = (path ?? "") + "\u{1}" + (transcriptPath ?? "")
        let signature = sigParts.joined(separator: ";")

        lock.lock()
        if let entry = cache[cacheKey], entry.signature == signature {
            let cached = entry.context
            lock.unlock()
            return cached.isEmpty ? nil : cached
        }
        lock.unlock()

        var ctx = ProjectContext.empty
        if let (goal, source) = readGoal(from: goalCandidates) {
            ctx.goal = goal
            ctx.goalSource = source
        }
        if let (items, source) = readNext(from: nextCandidates) {
            ctx.next = items
            ctx.nextSource = source
        }
        if let t = transcriptPath {
            ctx.now = Self.latestUserPrompt(fromTranscript: t)
        }

        lock.lock()
        cache[cacheKey] = CacheEntry(signature: signature, context: ctx)
        lock.unlock()

        return ctx.isEmpty ? nil : ctx
    }

    // MARK: Goal

    private func readGoal(from candidates: [URL]) -> (String, String)? {
        for url in candidates {
            guard let text = FileSupport.readHead(of: url, limit: Self.maxDocBytes) else { continue }
            if let goal = Self.extractGoal(from: text) {
                return (goal, url.lastPathComponent)
            }
        }
        return nil
    }

    /// First real paragraph of a markdown doc, cleaned to a single line. Skips
    /// headings, badges, blockquotes, HTML, tables and code fences.
    public static func extractGoal(from text: String) -> String? {
        var paragraph: [String] = []
        var insideCodeFence = false
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Fence state has to be tracked, not just matched per line: the fence
            // markers themselves look skippable but their *contents* don't, so a
            // README opening with a shell block would otherwise present the
            // commands inside it as the project's goal.
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                insideCodeFence.toggle()
                if !paragraph.isEmpty { break }
                continue
            }
            if insideCodeFence { continue }

            if line.isEmpty {
                if !paragraph.isEmpty { break }   // end of the first paragraph
                continue
            }
            if isSkippableProseLine(line) {
                if !paragraph.isEmpty { break }
                continue
            }
            paragraph.append(line)
        }
        guard !paragraph.isEmpty else { return nil }
        let joined = cleanMarkdown(paragraph.joined(separator: " "))
        return joined.isEmpty ? nil : truncate(joined, to: 240)
    }

    private static func isSkippableProseLine(_ line: String) -> Bool {
        let prefixes = ["#", ">", "<", "![", "[![", "---", "===", "|", "```", "<!--"]
        return prefixes.contains(where: { line.hasPrefix($0) })
    }

    // MARK: Next steps

    private func readNext(from candidates: [URL]) -> ([String], String)? {
        for url in candidates {
            guard let text = FileSupport.readHead(of: url, limit: Self.maxDocBytes) else { continue }
            let items = Self.extractNextSteps(from: text, limit: Self.maxNextItems)
            if !items.isEmpty { return (items, url.lastPathComponent) }
        }
        return nil
    }

    /// Unchecked markdown task items (`- [ ] …`, `* [ ] …`, `1. [ ] …`), in file
    /// order, up to `limit`. Pass `nil` for no limit — the task importer wants
    /// every item, not just the three the popover shows.
    public static func extractNextSteps(from text: String, limit: Int?) -> [String] {
        var items: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let task = uncheckedTask(in: line) else { continue }
            let cleaned = cleanMarkdown(task)
            guard !cleaned.isEmpty else { continue }
            items.append(truncate(cleaned, to: 160))
            if let limit, items.count >= limit { break }
        }
        return items
    }

    /// If `line` is an unchecked task list item, returns its text; else `nil`.
    static func uncheckedTask(in line: String) -> String? {
        var s = Substring(line)
        // Bullet marker: -, *, +, or "<digits>." / "<digits>)".
        if let first = s.first, first == "-" || first == "*" || first == "+" {
            s = s.dropFirst()
        } else {
            let digits = s.prefix(while: { $0.isNumber })
            guard !digits.isEmpty, let sep = s.dropFirst(digits.count).first,
                  sep == "." || sep == ")" else { return nil }
            s = s.dropFirst(digits.count + 1)
        }
        guard s.first == " " || s.first == "\t" else { return nil }
        s = s.drop(while: { $0 == " " || $0 == "\t" })
        // Checkbox: "[ ]" unchecked only (any whitespace inside the brackets).
        guard s.first == "[" else { return nil }
        s = s.dropFirst()
        guard let close = s.firstIndex(of: "]") else { return nil }
        let inside = s[s.startIndex..<close]
        guard inside.allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil } // "[x]" is done
        let rest = s[s.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    // MARK: Now (latest transcript prompt)

    /// Most recent user-typed prompt in a JSONL transcript (Claude Code or Codex),
    /// read from the tail so large files stay cheap.
    public static func latestUserPrompt(fromTranscript path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let text = FileSupport.readTail(of: url, limit: transcriptTailBytes) else { return nil }

        // Walk lines newest-first; first one that parses to user text wins.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let obj = jsonObject(from: line) else { continue }
            if let prompt = userText(from: obj) { return truncate(prompt, to: 200) }
        }
        return nil
    }

    private static func jsonObject(from line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Extracts a user's typed message from one transcript record, tolerating both
    /// the Claude Code and Codex shapes. Returns `nil` for assistant turns, tool
    /// results, and injected/meta entries.
    static func userText(from obj: [String: Any]) -> String? {
        if obj["isMeta"] as? Bool == true { return nil }
        if let type = obj["type"] as? String,
           type == "assistant" || type == "system" || type == "tool_result" {
            return nil
        }

        // Message may be at the top level, under "message", or under "payload".
        let message = (obj["message"] as? [String: Any])
            ?? (obj["payload"] as? [String: Any])
            ?? obj

        if let role = message["role"] as? String, role != "user" { return nil }

        let content = message["content"] ?? message["text"]
        if let str = content as? String {
            return sanitizePrompt(str)
        }
        if let blocks = content as? [[String: Any]] {
            for block in blocks {
                // Skip tool_result / image blocks — we want the typed text.
                if let t = block["type"] as? String, t != "text" { continue }
                if let txt = block["text"] as? String, let cleaned = sanitizePrompt(txt) {
                    return cleaned
                }
            }
        }
        return nil
    }

    /// Collapses a raw prompt to a single clean line, dropping injected meta blocks
    /// and tool/command noise. Returns `nil` if nothing human-readable remains.
    static func sanitizePrompt(_ raw: String) -> String? {
        var s = raw
        // Claude Code injects <system-reminder>…</system-reminder> and similar; keep
        // only what follows the last closing reminder tag.
        if let r = s.range(of: "</system-reminder>", options: .backwards) {
            s = String(s[r.upperBound...])
        }
        s = s.replacingOccurrences(of: "\r", with: " ")
             .replacingOccurrences(of: "\n", with: " ")
        s = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
             .trimmingCharacters(in: .whitespaces)
        // Drop entries that are purely a wrapped command/tag, or empty.
        guard !s.isEmpty, !s.hasPrefix("<"), !s.hasPrefix("Caveat:") else { return nil }
        return s
    }

    // MARK: Shared helpers

    private func signaturePart(_ url: URL) -> String {
        "\(url.lastPathComponent)@\(FileSupport.modificationDate(of: url).timeIntervalSince1970)"
    }

    /// Strips common inline markdown so a line reads cleanly as plain text.
    public static func cleanMarkdown(_ input: String) -> String {
        var s = input
        // Links / images: [text](url) -> text, ![alt](url) -> alt
        s = replaceLinks(in: s)
        // Emphasis & code markers.
        for token in ["**", "__", "`", "*", "_", "~~"] {
            s = s.replacingOccurrences(of: token, with: "")
        }
        // Leading list/heading markers left over.
        while let first = s.first, first == "#" || first == "-" || first == ">" || first == " " {
            s.removeFirst()
        }
        return s.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
    }

    /// Replaces `[text](url)` and `![alt](url)` with just the bracketed text.
    private static func replaceLinks(in input: String) -> String {
        var result = ""
        var rest = Substring(input)
        while let open = rest.firstIndex(of: "[") {
            result.append(contentsOf: rest[rest.startIndex..<open])
            // Drop a leading "!" of an image link already copied into result.
            if result.last == "!" { result.removeLast() }
            guard let close = rest[open...].firstIndex(of: "]") else {
                result.append(contentsOf: rest[open...])
                return result
            }
            let label = rest[rest.index(after: open)..<close]
            let afterClose = rest.index(after: close)
            // If followed by "(…)", swallow the URL part.
            if afterClose < rest.endIndex, rest[afterClose] == "(",
               let paren = rest[afterClose...].firstIndex(of: ")") {
                result.append(contentsOf: label)
                rest = rest[rest.index(after: paren)...]
            } else {
                result.append("[")
                result.append(contentsOf: label)
                result.append("]")
                rest = rest[afterClose...]
            }
        }
        result.append(contentsOf: rest)
        return result
    }

    /// Truncates to `limit` characters on a word boundary, adding an ellipsis.
    public static func truncate(_ s: String, to limit: Int) -> String {
        guard s.count > limit else { return s }
        let slice = s.prefix(limit)
        if let lastSpace = slice.lastIndex(of: " "), slice.distance(from: slice.startIndex, to: lastSpace) > limit / 2 {
            return slice[slice.startIndex..<lastSpace].trimmingCharacters(in: .whitespaces) + "…"
        }
        return slice.trimmingCharacters(in: .whitespaces) + "…"
    }
}
