import Foundation

/// A next step an agent proposed, waiting for a person to accept or dismiss it.
///
/// **The app does no reasoning to produce these.** It cannot — `MultiTaskCore`
/// calls no models, by design. What it does instead is notice that the reasoning
/// already happened: an agent that finishes a turn almost always writes down what
/// it thinks comes next, in its closing message or in a roadmap it just ticked.
/// That text is sitting in a transcript on disk, addressed to a person who has
/// since closed the terminal and moved to another project. Harvesting it is
/// reading, not inference, and it is the only honest sense in which this app can
/// offer a suggestion.
public struct SuggestedStep: Codable, Hashable, Sendable, Identifiable {
    /// Stable across refreshes so an accepted or dismissed step stays decided.
    public var id: String
    public var text: String
    public var projectPath: String
    /// Which agent proposed it, for attribution in the row.
    public var agent: String?
    public var sessionId: String?
    /// Where it was read from — "Claude Code", "ROADMAP.md". Shown to the user so
    /// a suggestion is never anonymous.
    public var source: String
    public var capturedAt: Date

    public init(text: String, projectPath: String, agent: String? = nil,
                sessionId: String? = nil, source: String, capturedAt: Date) {
        self.text = text
        self.projectPath = projectPath
        self.agent = agent
        self.sessionId = sessionId
        self.source = source
        self.capturedAt = capturedAt
        self.id = SuggestedStep.identity(projectPath: projectPath, text: text)
    }

    /// Project plus normalised text. Deliberately excludes the session and the
    /// timestamp: the same step proposed again by a later session is the *same*
    /// step, and re-offering one the user already dismissed is the fastest way to
    /// make this feature annoying enough to turn off.
    public static func identity(projectPath: String, text: String) -> String {
        let normalised = text.lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == " " }
            .split(separator: " ").joined(separator: " ")
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array("\(projectPath)\u{0}\(normalised)".utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

/// Pulls agent-proposed next steps out of transcripts and roadmaps.
public enum NextStepHarvester {
    /// How far back into a transcript to look for the closing message.
    public static let transcriptTailBytes: UInt64 = 96 * 1024

    /// Never offer more than this from one session. An agent that lists twelve
    /// follow-ups has written a document, not a queue, and pasting all twelve into
    /// the board buries the two that matter.
    public static let maxPerSession = 4

    /// Headings that introduce a list of things still to do. Matched against a
    /// line with markdown and punctuation stripped.
    static let cues = [
        "next step", "next up", "suggested next", "recommended next",
        "what's next", "whats next", "remaining", "still to do", "to do next",
        "follow up", "follow-up", "outstanding", "not done", "left to do",
        "optional next step", "possible next step"
    ]

    /// Lines that look like a step but are really the agent narrating its own
    /// finished work, or asking a question. These produce tasks nobody wants.
    static let rejects = [
        "let me know", "want me to", "shall i", "should i", "would you like",
        "no further", "nothing further", "nothing else", "none", "n/a"
    ]

    // MARK: Transcripts

    /// Reads the newest assistant message in a transcript and extracts the next
    /// steps it proposed.
    public static func steps(fromTranscript path: String,
                             projectPath: String,
                             agent: String?,
                             sessionId: String?,
                             capturedAt: Date) -> [SuggestedStep] {
        guard let message = latestAssistantMessage(fromTranscript: path) else { return [] }
        let label = agent.map { $0 == "claude" ? "Claude Code" : $0 } ?? "agent session"
        return extract(from: message).prefix(maxPerSession).map {
            SuggestedStep(text: $0, projectPath: projectPath, agent: agent,
                          sessionId: sessionId, source: label, capturedAt: capturedAt)
        }
    }

    /// The last thing the agent said, as plain text. Mirrors
    /// `ProjectContextReader.latestUserPrompt` but for the other side of the
    /// conversation, and keeps newlines — the list structure is the whole point.
    public static func latestAssistantMessage(fromTranscript path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let text = FileSupport.readTail(of: url, limit: transcriptTailBytes) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let body = assistantText(from: obj) else { continue }
            return body
        }
        return nil
    }

    /// Extracts assistant prose from one transcript record, in either the Claude
    /// Code or the Codex shape. Returns `nil` for user turns, tool calls, and
    /// reasoning blocks.
    static func assistantText(from obj: [String: Any]) -> String? {
        if obj["isMeta"] as? Bool == true { return nil }
        if let type = obj["type"] as? String,
           type == "user" || type == "system" || type == "tool_result" { return nil }

        let message = (obj["message"] as? [String: Any])
            ?? (obj["payload"] as? [String: Any])
            ?? obj
        // Codex rollouts carry the role on the payload; Claude Code on the message.
        if let role = message["role"] as? String, role != "assistant" { return nil }
        if message["role"] == nil, obj["type"] as? String != "assistant" { return nil }

        let content = message["content"] ?? message["text"]
        if let str = content as? String { return str.isEmpty ? nil : str }
        if let blocks = content as? [[String: Any]] {
            let prose = blocks.compactMap { block -> String? in
                // Skip tool_use and thinking — a tool call is not advice.
                if let t = block["type"] as? String, t != "text" && t != "output_text" { return nil }
                return block["text"] as? String
            }.joined(separator: "\n")
            return prose.isEmpty ? nil : prose
        }
        return nil
    }

    // MARK: Extraction

    /// Finds the next-steps section of a message and returns its items.
    ///
    /// Scans for a cue line, then takes the list that follows. A message with no
    /// cue yields nothing — guessing which of an agent's closing sentences was a
    /// recommendation produces noise, and a queue that fills with noise stops
    /// being read.
    public static func extract(from message: String) -> [String] {
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var found: [String] = []
        var collecting = false
        var seenItem = false

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if !collecting {
                guard isCue(line) else { continue }
                collecting = true
                seenItem = false
                // "Next step: run the generator" carries the step on the cue
                // line itself. Treating the whole line as a heading swallows the
                // only content there was.
                if let inline = inlineStep(in: line), let cleaned = clean(inline) {
                    found.append(cleaned)
                    seenItem = true
                }
                continue
            }

            if line.isEmpty {
                // A blank before any item is the gap under a heading; after items,
                // it ends the list.
                if seenItem { collecting = false }
                continue
            }
            if let item = listItem(in: line) {
                seenItem = true
                if let cleaned = clean(item) { found.append(cleaned) }
                continue
            }
            // A cue can introduce a single sentence rather than a list.
            if !seenItem, let cleaned = clean(line) {
                found.append(cleaned)
                seenItem = true
                continue
            }
            collecting = false
        }
        // De-duplicate while keeping order — agents repeat themselves across a
        // summary and a list.
        var seen = Set<String>()
        return found.filter { seen.insert($0.lowercased()).inserted }
    }

    /// The text after the colon on a cue line, when there is any. `nil` when the
    /// line is a bare heading.
    static func inlineStep(in line: String) -> String? {
        let cleaned = ProjectContextReader.cleanMarkdown(line)
        guard let colon = cleaned.firstIndex(of: ":") else { return nil }
        let rest = cleaned[cleaned.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// Whether a line introduces a next-steps list.
    static func isCue(_ line: String) -> Bool {
        var s = ProjectContextReader.cleanMarkdown(line).lowercased()
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "#*_-:. "))
        guard s.count <= 60 else { return false }
        return cues.contains { s == $0 || s.hasPrefix($0) || s.hasSuffix($0) }
    }

    /// The body of a bullet or numbered item, or `nil` if the line isn't one.
    static func listItem(in line: String) -> String? {
        if let task = ProjectContextReader.uncheckedTask(in: line) { return task }
        for marker in ["- ", "* ", "• ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        // "1. ", "2) " …
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 2 {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return String(rest.dropFirst(2))
            }
        }
        return nil
    }

    /// Normalises an item to a task title, or rejects it.
    static func clean(_ raw: String) -> String? {
        var s = ProjectContextReader.cleanMarkdown(raw).trimmingCharacters(in: .whitespaces)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-–—•*: "))
        guard s.count >= 8, s.count <= 200 else { return nil }
        let lower = s.lowercased()
        if rejects.contains(where: { lower.hasPrefix($0) || lower == $0 }) { return nil }
        // A question is a request for direction, not a step.
        if s.hasSuffix("?") { return nil }
        return ProjectContextReader.truncate(s, to: 140)
    }
}
