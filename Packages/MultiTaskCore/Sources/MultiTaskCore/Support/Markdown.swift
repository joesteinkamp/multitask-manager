import Foundation

/// Markdown reading shared by every reader that parses a document rather than a
/// log: project briefs, roadmaps, wave state files.
///
/// It exists because "split into lines and look for a heading" has three details
/// that are wrong by default, and getting them wrong is silent rather than loud.
public enum Markdown {

    /// Splits text into lines, treating `\r\n`, `\n` and a lone `\r` as one
    /// break each.
    ///
    /// `components(separatedBy: .newlines)` treats `\r\n` as **two** separators
    /// and yields a spurious empty line between every real one. Since an empty
    /// line ends a paragraph, a Windows-authored document read that way loses
    /// everything after its first line — silently, with no error anywhere.
    public static func lines(of text: String) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar?

        while let scalar = pending ?? iterator.next() {
            pending = nil
            if scalar == "\r" {
                // Swallow the \n of a \r\n pair; a lone \r is still a break.
                if let next = iterator.next() {
                    if next != "\n" { pending = next }
                }
                result.append(String(current))
                current = String.UnicodeScalarView()
            } else if scalar == "\n" {
                result.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        result.append(String(current))
        return result
    }

    /// A line trimmed of surrounding whitespace *including* carriage returns.
    ///
    /// `.whitespaces` does not contain `\r` — it's in `.whitespacesAndNewlines` —
    /// so a naive trim leaves a stray CR riding on the end of every value read
    /// from a CRLF file.
    public static func trim(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Heading level of a line (`## Foo` → 2), or `nil` if it isn't a heading.
    /// Lines inside a fenced code block are not headings; callers that care use
    /// `sections(in:)`, which tracks fences.
    public static func headingLevel(_ line: String) -> Int? {
        let trimmed = trim(line)
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard hashes <= 6 else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        return hashes
    }

    public static func headingTitle(_ line: String) -> String? {
        guard let level = headingLevel(line) else { return nil }
        return trim(String(trim(line).dropFirst(level)))
    }

    /// Body of the section with the given heading, up to the next heading at the
    /// same or higher level. Matching is case- and level-insensitive, so a brief
    /// that renders "Success metrics" as `###` still resolves.
    public static func section(_ name: String, in text: String) -> String? {
        var capturing = false
        var capturedLevel = 0
        var body: [String] = []
        var inFence = false

        for line in lines(of: text) {
            let trimmed = trim(line)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                if capturing { body.append(line) }
                continue
            }
            if inFence {
                if capturing { body.append(line) }
                continue
            }

            if let level = headingLevel(line) {
                if capturing {
                    if level <= capturedLevel { break }
                    body.append(line)
                    continue
                }
                if let title = headingTitle(line),
                   title.compare(name, options: .caseInsensitive) == .orderedSame {
                    capturing = true
                    capturedLevel = level
                }
                continue
            }
            if capturing { body.append(line) }
        }

        guard capturing else { return nil }
        let joined = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// First prose paragraph of a block, cleaned to one line. Skips headings,
    /// blockquotes, HTML, tables, images and fenced code.
    public static func firstParagraph(of text: String) -> String? {
        var paragraph: [String] = []
        var inFence = false

        for raw in lines(of: text) {
            let line = trim(raw)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                if !paragraph.isEmpty { break }
                continue
            }
            if inFence { continue }
            if line.isEmpty {
                if !paragraph.isEmpty { break }
                continue
            }
            if isChrome(line) {
                if !paragraph.isEmpty { break }
                continue
            }
            paragraph.append(line)
        }

        guard !paragraph.isEmpty else { return nil }
        let cleaned = ProjectContextReader.cleanMarkdown(paragraph.joined(separator: " "))
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Lines that carry no prose of their own.
    static func isChrome(_ line: String) -> Bool {
        ["#", ">", "<", "![", "[![", "---", "===", "|", "<!--"].contains { line.hasPrefix($0) }
    }

    /// Plain bullet items (`-`, `*`, `+`) in a block, cleaned. Checkbox items are
    /// included with their marker stripped, because a brief's bullets are often
    /// written either way.
    public static func bullets(in text: String) -> [String] {
        var items: [String] = []
        var inFence = false
        for raw in lines(of: text) {
            let line = trim(raw)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence { continue }
            guard let first = line.first, first == "-" || first == "*" || first == "+" else { continue }
            var rest = Substring(line.dropFirst())
            guard rest.first == " " || rest.first == "\t" else { continue }
            rest = rest.drop(while: { $0 == " " || $0 == "\t" })
            // Strip a leading checkbox if present.
            if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                rest = rest[rest.index(after: close)...].drop(while: { $0 == " " || $0 == "\t" })
            }
            let cleaned = ProjectContextReader.cleanMarkdown(String(rest))
            if !cleaned.isEmpty { items.append(cleaned) }
        }
        return items
    }

    /// One markdown task-list item.
    public struct TaskItem: Equatable, Sendable {
        public var text: String
        public var isChecked: Bool
    }

    /// Every task-list item in a document, checked and unchecked alike.
    ///
    /// The unchecked ones are the "Next" list; the ratio of checked to total is
    /// the cheapest honest progress signal a project has, and until now the
    /// checked ones were parsed and thrown away.
    public static func taskItems(in text: String) -> [TaskItem] {
        var items: [TaskItem] = []
        var inFence = false
        for raw in lines(of: text) {
            let line = trim(raw)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence { continue }
            guard let item = taskItem(in: line) else { continue }
            items.append(item)
        }
        return items
    }

    static func taskItem(in line: String) -> TaskItem? {
        var s = Substring(line)
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
        guard s.first == "[" else { return nil }
        s = s.dropFirst()
        guard let close = s.firstIndex(of: "]") else { return nil }
        let inside = s[s.startIndex..<close]
        guard inside.count == 1 || inside.allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }

        let checked: Bool
        if inside.allSatisfy({ $0 == " " || $0 == "\t" }) {
            checked = false
        } else if let mark = inside.first, mark == "x" || mark == "X" {
            checked = true
        } else {
            return nil
        }

        let rest = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = ProjectContextReader.cleanMarkdown(rest)
        guard !cleaned.isEmpty else { return nil }
        return TaskItem(text: cleaned, isChecked: checked)
    }
}
