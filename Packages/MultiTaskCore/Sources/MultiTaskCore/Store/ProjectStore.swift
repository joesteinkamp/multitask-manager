import Foundation

/// Minimal YAML-ish front matter: a `---` fenced block of flat `key: value`
/// pairs at the top of a markdown file, followed by a free-text body.
///
/// Deliberately not a YAML parser. The format exists so these files are
/// git-friendly, readable without the app, and editable by an agent with the
/// tools it already has — which means the parser has to be forgiving about
/// whitespace and quoting and strict about nothing else. Anything needing
/// nested structure is a sign the field belongs somewhere else.
public enum FrontMatter {
    public static func parse(_ text: String) -> (fields: [String: String], body: String) {
        let lines = Markdown.lines(of: text)
        guard let first = lines.first, Markdown.trim(first) == "---" else {
            return ([:], text)
        }

        var fields: [String: String] = [:]
        var index = 1
        while index < lines.count {
            let line = Markdown.trim(lines[index])
            index += 1
            if line == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = Markdown.trim(String(line[line.startIndex..<colon]))
            var value = Markdown.trim(String(line[line.index(after: colon)...]))
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty else { continue }
            fields[key] = value
        }

        let body = lines[min(index, lines.count)...].joined(separator: "\n")
        return (fields, body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func render(fields: [(String, String)], body: String) -> String {
        var out = "---\n"
        for (key, value) in fields where !value.isEmpty {
            // Quote only when the value could otherwise be misread.
            let needsQuotes = value.contains(":") || value.hasPrefix(" ") || value.hasSuffix(" ")
            out += needsQuotes ? "\(key): \"\(value)\"\n" : "\(key): \(value)\n"
        }
        out += "---\n"
        if !body.isEmpty { out += "\n" + body + "\n" }
        return out
    }
}

/// Reads and writes project records as one markdown file each under
/// `~/.multitaskmanager/projects/`.
///
/// Files rather than a database, for the same reasons the task store will use
/// them: git-friendly, readable without the app, editable by the agents
/// themselves with the tools they already have, and they survive the app being
/// uninstalled.
public final class ProjectStore: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileSupport.homeDirectory
            .appendingPathComponent(".multitaskmanager", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        try? FileSupport.fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public var path: String { directory.path }

    public func load() -> [ProjectRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard FileSupport.isDirectory(directory) else { return [] }
        return FileSupport.contents(of: directory)
            .filter { $0.pathExtension == "md" }
            .compactMap { url in
                guard let text = FileSupport.readHead(of: url, limit: 64 * 1024) else { return nil }
                return Self.decode(text)
            }
            .sorted { $0.id < $1.id }
    }

    public func save(_ record: ProjectRecord) {
        lock.lock()
        defer { lock.unlock() }
        let url = directory.appendingPathComponent("\(record.id).md")
        // Preserve whatever notes the file already carried — the body belongs to
        // whoever wrote it, and this app only owns the front matter.
        var body = ""
        if let existing = FileSupport.readHead(of: url, limit: 64 * 1024) {
            body = FrontMatter.parse(existing).body
        }
        let text = Self.encode(record, body: body)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    public func delete(id: String) {
        lock.lock()
        defer { lock.unlock() }
        try? FileSupport.fileManager.removeItem(at: directory.appendingPathComponent("\(id).md"))
    }

    /// Records the project a session was found in, if it isn't recorded already.
    /// Returns the record either way.
    @discardableResult
    public func ensure(path projectPath: String, name: String? = nil, now: Date = Date()) -> ProjectRecord {
        let id = ProjectRecord.identifier(forPath: projectPath)
        if let existing = load().first(where: { $0.id == id }) { return existing }
        let record = ProjectRecord(
            id: id,
            name: name ?? FileSupport.lastComponent(of: projectPath),
            path: projectPath,
            createdAt: now
        )
        save(record)
        return record
    }

    // MARK: Coding

    static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func encode(_ record: ProjectRecord, body: String) -> String {
        var fields: [(String, String)] = [
            ("id", record.id),
            ("name", record.name)
        ]
        if let path = record.path { fields.append(("path", path)) }
        if let ref = record.externalRef { fields.append(("externalRef", ref)) }
        fields.append(("lifecycle", encodeLifecycle(record.lifecycle)))
        fields.append(("created", formatter.string(from: record.createdAt)))
        if let origin = record.origin { fields.append(("origin", origin)) }
        if record.isPinned { fields.append(("pinned", "true")) }
        return FrontMatter.render(fields: fields, body: body)
    }

    static func decode(_ text: String) -> ProjectRecord? {
        let (fields, _) = FrontMatter.parse(text)
        guard let id = fields["id"], !id.isEmpty,
              let name = fields["name"], !name.isEmpty
        else { return nil }

        return ProjectRecord(
            id: id,
            name: name,
            path: fields["path"],
            externalRef: fields["externalRef"],
            lifecycle: decodeLifecycle(fields["lifecycle"]),
            createdAt: fields["created"].flatMap(formatter.date(from:)) ?? Date(),
            origin: fields["origin"],
            isPinned: fields["pinned"] == "true"
        )
    }

    static func encodeLifecycle(_ lifecycle: ProjectLifecycle) -> String {
        switch lifecycle {
        case .active: return "active"
        case .archived: return "archived"
        case .parked(let until): return "parked:\(formatter.string(from: until))"
        }
    }

    static func decodeLifecycle(_ raw: String?) -> ProjectLifecycle {
        guard let raw else { return .active }
        if raw == "archived" { return .archived }
        if raw.hasPrefix("parked:"),
           let date = formatter.date(from: String(raw.dropFirst("parked:".count))) {
            return .parked(until: date)
        }
        return .active
    }
}
