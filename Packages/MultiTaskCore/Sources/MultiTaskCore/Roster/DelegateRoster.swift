import Foundation

/// A delegate the machine can dispatch work to.
public struct Delegate: Codable, Hashable, Sendable, Identifiable {
    /// Bare CLI name as it appears in `~/.ai/clis` — "claude", "codex", "agy", …
    public var name: String
    /// True for entries backed by `~/.ai/local-models` rather than a cloud CLI.
    public var isLocal: Bool
    /// Local-model detail, absent for cloud CLIs.
    public var localModel: LocalModel?

    public var id: String { name }

    public init(name: String, isLocal: Bool = false, localModel: LocalModel? = nil) {
        self.name = name
        self.isLocal = isLocal
        self.localModel = localModel
    }
}

/// One line of `~/.ai/local-models`:
/// `name|backend|base_url|model|tier[|tok/s]`.
public struct LocalModel: Codable, Hashable, Sendable {
    public var name: String
    public var backend: String
    public var baseURL: String
    public var model: String
    public var tier: String
    /// Optional throughput hint, tokens/second.
    public var tokensPerSecond: Double?

    public init(name: String, backend: String, baseURL: String, model: String,
                tier: String, tokensPerSecond: Double? = nil) {
        self.name = name
        self.backend = backend
        self.baseURL = baseURL
        self.model = model
        self.tier = tier
        self.tokensPerSecond = tokensPerSecond
    }
}

/// One ranked row of a routing table.
public struct RoutingRow: Codable, Hashable, Sendable {
    /// Rank as written — "1", "1 (tie)", "—" for an unranked note.
    public var rank: String
    /// CLI names named in the row. A single row can list several ("`claude` / `codex`").
    public var clis: [String]
    public var evidence: String

    public init(rank: String, clis: [String], evidence: String) {
        self.rank = rank
        self.clis = clis
        self.evidence = evidence
    }
}

/// A `##` section of `~/.ai/model-routing.md` — one task type.
public struct RoutingSection: Codable, Hashable, Sendable, Identifiable {
    public var title: String
    public var rows: [RoutingRow]

    public var id: String { title }

    public init(title: String, rows: [RoutingRow]) {
        self.title = title
        self.rows = rows
    }

    /// CLI names in rank order, de-duplicated. This is what routing consumes.
    public var rankedCLIs: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for row in rows where row.rank != "—" {
            for cli in row.clis where !seen.contains(cli) {
                seen.insert(cli)
                result.append(cli)
            }
        }
        return result
    }
}

/// Everything parsed out of `~/.ai/`.
public struct Roster: Sendable {
    public var delegates: [Delegate] = []
    public var routingSections: [RoutingSection] = []
    /// The routing table's own `- **Last updated:**` date.
    public var routingUpdatedAt: Date?
    /// Notes for anything missing, shown rather than silently treated as empty.
    public var notes: [String] = []

    public init() {}

    /// The orchestration playbook asks for a staleness note once the routing table
    /// is about two months old; benchmarks move fast enough that an older table is
    /// advice about models that have since been superseded.
    public static let stalenessWindow: TimeInterval = 60 * 24 * 60 * 60

    public func isRoutingStale(now: Date = Date()) -> Bool {
        guard let routingUpdatedAt else { return true }
        return now.timeIntervalSince(routingUpdatedAt) > Self.stalenessWindow
    }

    /// Ranked CLIs for a task type, matched case-insensitively against section
    /// titles. Advisory: the caller always shows the choice and lets it be changed.
    public func ranking(forTaskType title: String) -> [String] {
        routingSections.first {
            $0.title.range(of: title, options: .caseInsensitive) != nil
        }?.rankedCLIs ?? []
    }
}

/// Parses the delegate roster and routing table out of `~/.ai/`.
///
/// Built as a standalone parser rather than view-local code because Phase 4's
/// routing consumes exactly the same data — the Settings pane is just its first
/// reader.
public struct RosterReader: Sendable {
    public var directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileSupport.homeDirectory
            .appendingPathComponent(".ai", isDirectory: true)
    }

    public func read() -> Roster {
        var roster = Roster()

        let clisFile = directory.appendingPathComponent("clis")
        if let text = FileSupport.readHead(of: clisFile, limit: 8 * 1024) {
            roster.delegates = Self.parseCLIs(text).map { Delegate(name: $0) }
        } else {
            roster.notes.append("No delegate list at \(clisFile.path)")
        }

        let localFile = directory.appendingPathComponent("local-models")
        if let text = FileSupport.readHead(of: localFile, limit: 32 * 1024) {
            for model in Self.parseLocalModels(text) {
                roster.delegates.append(Delegate(name: model.name, isLocal: true, localModel: model))
            }
        }
        // Absence is meaningful, not an error: no `local-models` file means this
        // machine has no local models, and the playbook says to skip silently
        // rather than install one.

        let routingFile = directory.appendingPathComponent("model-routing.md")
        if let text = FileSupport.readHead(of: routingFile, limit: 256 * 1024) {
            roster.routingSections = Self.parseRoutingSections(text)
            roster.routingUpdatedAt = Self.parseLastUpdated(text)
        } else {
            roster.notes.append("No routing table at \(routingFile.path)")
        }

        return roster
    }

    /// `~/.ai/clis` is bare names, one per line.
    public static func parseCLIs(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    public static func parseLocalModels(_ text: String) -> [LocalModel] {
        text.components(separatedBy: .newlines).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 5 else { return nil }
            return LocalModel(
                name: fields[0],
                backend: fields[1],
                baseURL: fields[2],
                model: fields[3],
                tier: fields[4],
                tokensPerSecond: fields.count > 5 ? Double(fields[5]) : nil
            )
        }
    }

    /// Front-matter line `- **Last updated:** YYYY-MM-DD`.
    public static func parseLastUpdated(_ text: String) -> Date? {
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- **Last updated:**") else { continue }
            let value = line
                .replacingOccurrences(of: "- **Last updated:**", with: "")
                .trimmingCharacters(in: .whitespaces)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: String(value.prefix(10))) { return date }
        }
        return nil
    }

    /// `##` sections, each holding a `Rank | CLI | Evidence` table.
    public static func parseRoutingSections(_ text: String) -> [RoutingSection] {
        var sections: [RoutingSection] = []
        var currentTitle: String?
        var currentRows: [RoutingRow] = []

        func flush() {
            guard let title = currentTitle, !currentRows.isEmpty else { return }
            sections.append(RoutingSection(title: title, rows: currentRows))
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("## ") {
                flush()
                currentTitle = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                currentRows = []
                continue
            }
            guard currentTitle != nil, line.hasPrefix("|") else { continue }

            let cells = line
                .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                .components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 3 else { continue }
            // Skip the header row and the |---|---| separator.
            if cells[0].caseInsensitiveCompare("Rank") == .orderedSame { continue }
            if cells[0].allSatisfy({ $0 == "-" || $0 == ":" }) { continue }

            currentRows.append(RoutingRow(
                rank: cells[0],
                clis: extractCLINames(from: cells[1]),
                evidence: cells[2]
            ))
        }
        flush()
        return sections
    }

    /// CLI names out of a table cell. They are always written in backticks, which
    /// is what makes cells like "no clear winner (`codex`/`claude`)" parse cleanly
    /// instead of yielding the prose around them.
    static func extractCLINames(from cell: String) -> [String] {
        var names: [String] = []
        var rest = Substring(cell)
        while let open = rest.firstIndex(of: "`") {
            let afterOpen = rest.index(after: open)
            guard afterOpen < rest.endIndex, let close = rest[afterOpen...].firstIndex(of: "`") else { break }
            let name = rest[afterOpen..<close].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { names.append(name) }
            rest = rest[rest.index(after: close)...]
        }
        return names
    }
}
