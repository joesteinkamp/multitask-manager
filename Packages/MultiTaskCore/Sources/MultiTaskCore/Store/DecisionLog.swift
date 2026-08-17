import Foundation

/// What kind of decision was made. A closed vocabulary on purpose: an open one
/// becomes free-text within a month and stops being searchable, which is exactly
/// how an event log turns into noise nobody reads.
public enum DecisionCategory: String, Codable, CaseIterable, Sendable {
    case taskCreated
    case taskAssigned
    case taskCompleted
    case taskSnoozed
    case taskEscalated
    case projectArchived
    case projectParked
    case suggestionAccepted
    case suggestionRejected
    case syncRan
    case other

    public var label: String {
        switch self {
        case .taskCreated: return "Filed"
        case .taskAssigned: return "Assigned"
        case .taskCompleted: return "Completed"
        case .taskSnoozed: return "Snoozed"
        case .taskEscalated: return "Escalated"
        case .projectArchived: return "Archived"
        case .projectParked: return "Parked"
        case .suggestionAccepted: return "Accepted"
        case .suggestionRejected: return "Rejected"
        case .syncRan: return "Synced"
        case .other: return "Noted"
        }
    }
}

/// One line of narration: what happened, and why.
public struct Decision: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var at: Date
    public var category: DecisionCategory
    /// One human-readable sentence. This is the field that has to still make
    /// sense in three months.
    public var summary: String
    /// Who did it — "me", a delegate name, or "mcp".
    public var actor: String
    public var projectId: String?
    public var taskId: String?

    public init(id: String = UUID().uuidString, at: Date = Date(),
                category: DecisionCategory, summary: String, actor: String,
                projectId: String? = nil, taskId: String? = nil) {
        self.id = id
        self.at = at
        self.category = category
        self.summary = summary
        self.actor = actor
        self.projectId = projectId
        self.taskId = taskId
    }
}

/// An append-only record of *why*, kept apart from the audit trail.
///
/// The distinction matters and is the whole reason this exists. The audit log
/// records that a thing occurred — the mechanical trace. This records the
/// reasoning: "escalated because the build needs a signing certificate". In the
/// prior art this design learned from, the decision log was the only record that
/// still answered "what happened here" months later, while its raw event feed
/// was 77% status-change noise nobody could read.
///
/// So the rules are deliberate: a **closed** category vocabulary, one
/// human-readable sentence per entry, and **nothing mechanical** — no status
/// transitions, no refresh ticks, no "session became idle". If an entry wouldn't
/// be worth reading aloud, it doesn't belong here.
public final class DecisionLog: @unchecked Sendable {
    /// Entries are cheap but not free; a long-running daemon shouldn't grow this
    /// without bound, and anything older than this has outlived its usefulness
    /// as narration.
    public static let retention: TimeInterval = 90 * 24 * 60 * 60

    private let fileURL: URL
    private let lock = NSLock()

    public init(directory: URL? = nil) {
        let base = directory ?? FileSupport.stateDirectory
        try? FileSupport.fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("decisions.jsonl")
    }

    public var path: String { fileURL.path }

    /// Appends one decision. Never throws: losing a narration line must not fail
    /// the action it was narrating.
    public func record(_ decision: Decision) {
        guard let line = try? Self.encoder.encode(decision) else { return }
        var data = line
        data.append(UInt8(ascii: "\n"))

        lock.lock()
        defer { lock.unlock() }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Convenience for the common shape.
    public func record(_ category: DecisionCategory, _ summary: String,
                       actor: String = "me", projectId: String? = nil,
                       taskId: String? = nil, at: Date = Date()) {
        record(Decision(at: at, category: category, summary: summary,
                        actor: actor, projectId: projectId, taskId: taskId))
    }

    /// Most recent first.
    public func recent(limit: Int = 50, projectId: String? = nil) -> [Decision] {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        var decisions: [Decision] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            // A corrupt line is skipped, never fatal — the same tolerance the
            // audit reader applies, for the same reason.
            guard let decision = try? Self.decoder.decode(Decision.self, from: Data(line)) else { continue }
            if let projectId, decision.projectId != projectId { continue }
            decisions.append(decision)
        }
        return decisions.sorted { $0.at > $1.at }.prefix(limit).map { $0 }
    }

    /// Drops entries past the retention window. Cheap enough to run at startup.
    public func prune(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return }

        let cutoff = now.addingTimeInterval(-Self.retention)
        var kept = Data()
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let decision = try? Self.decoder.decode(Decision.self, from: Data(line)),
                  decision.at >= cutoff else { continue }
            kept.append(contentsOf: line)
            kept.append(UInt8(ascii: "\n"))
        }
        try? kept.write(to: fileURL, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]     // never pretty: one line each
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
