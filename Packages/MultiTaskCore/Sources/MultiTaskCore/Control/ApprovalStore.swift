import Foundation

/// A request from an agent for permission to spend something.
///
/// **Why this exists rather than handing agents the confirmation token.**
/// The token gate works because the party that reads the description and the
/// party that replays the token is a person. Over MCP it is not: an agent that
/// receives a token can simply call again carrying it, and the gate becomes two
/// round-trips of theatre. Asking an agent to "present this to your human first"
/// is a policy, and a policy is not a mechanism.
///
/// So agents get a different verb. They **request**; only a human **decides**.
/// The request lands here, the app surfaces it as something needing attention,
/// and approving it is what mints the token — inside the engine, where no caller
/// can reach it. The MCP server deliberately exposes no way to decide.
public struct ApprovalRequest: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// Hand a task to a delegate.
        case run
        /// Create an isolated worktree.
        case provision
    }

    public enum State: String, Codable, Sendable {
        case pending
        case approved
        case denied
        /// Sat too long to be safe to act on. See `expiry`.
        case expired

        public var isDecided: Bool { self != .pending }
    }

    public var id: String
    public var kind: Kind
    /// One line a person can decide on.
    public var summary: String
    /// The specifics — the same detail lines the direct gate would have shown.
    public var details: [String]
    /// Which agent asked. Recorded because "who wanted this?" is the first
    /// question anyone asks about a request they didn't expect.
    public var requestedBy: String
    public var requestedAt: Date
    /// Why the agent thinks this should happen. Optional, and worth a lot: a
    /// request with no reason is one a person has to reconstruct before deciding.
    public var rationale: String?

    public var taskId: String?
    public var projectId: String?
    /// For `.run` — which delegate. For `.provision` — the agent name.
    public var delegate: String?

    public var state: State
    public var decidedAt: Date?
    /// Set when denied, or when approving produced something to say.
    public var note: String?
    /// Set once approved and carried out.
    public var runId: String?

    public init(id: String, kind: Kind, summary: String, details: [String],
                requestedBy: String, requestedAt: Date = Date(),
                rationale: String? = nil, taskId: String? = nil,
                projectId: String? = nil, delegate: String? = nil,
                state: State = .pending, decidedAt: Date? = nil,
                note: String? = nil, runId: String? = nil) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.details = details
        self.requestedBy = requestedBy
        self.requestedAt = requestedAt
        self.rationale = rationale
        self.taskId = taskId
        self.projectId = projectId
        self.delegate = delegate
        self.state = state
        self.decidedAt = decidedAt
        self.note = note
        self.runId = runId
    }

    /// How long a pending request stays actionable.
    ///
    /// A request approved two days after it was made is approved against a repo
    /// that has moved, by someone who no longer remembers the context they were
    /// agreeing to. Expiry makes the stale case a re-ask rather than a surprise.
    public static let expiry: TimeInterval = 24 * 60 * 60

    public func hasExpired(now: Date = Date()) -> Bool {
        state == .pending && now.timeIntervalSince(requestedAt) > Self.expiry
    }

    /// The state a reader should treat this as, accounting for age.
    ///
    /// Expiry is applied on read rather than by a sweep, so a request is never
    /// actionable just because nothing has run recently to age it out.
    public func effectiveState(now: Date = Date()) -> State {
        hasExpired(now: now) ? .expired : state
    }

    public static func identifier(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "ask-\(formatter.string(from: now))-\(Int.random(in: 100...999))"
    }
}

/// Approval requests on disk, one file each.
public final class ApprovalStore: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileSupport.stateDirectory
            .appendingPathComponent("approvals", isDirectory: true)
        try? FileSupport.fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public var path: String { directory.path }

    public func save(_ request: ApprovalRequest) {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(request) else { return }
        try? data.write(to: directory.appendingPathComponent("\(request.id).json"), options: .atomic)
    }

    public func load() -> [ApprovalRequest] {
        lock.lock()
        defer { lock.unlock() }
        guard FileSupport.isDirectory(directory) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return FileSupport.contents(of: directory)
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(ApprovalRequest.self, from: Data(contentsOf: $0)) }
            .sorted { $0.requestedAt > $1.requestedAt }
    }

    /// Everything still awaiting a person, newest first. Expired requests are
    /// excluded — they are no longer a decision anyone should be making.
    public func pending(now: Date = Date()) -> [ApprovalRequest] {
        load().filter { $0.effectiveState(now: now) == .pending }
    }

    public func request(id: String) -> ApprovalRequest? {
        let all = load()
        return all.first { $0.id == id } ?? all.first { $0.id.hasPrefix(id) }
    }

    /// Drops decided requests once they stop being useful as history.
    public func prune(olderThan age: TimeInterval = 30 * 86_400, now: Date = Date()) {
        for request in load() where request.state.isDecided {
            guard let decided = request.decidedAt, now.timeIntervalSince(decided) > age else { continue }
            lock.lock()
            try? FileSupport.fileManager.removeItem(at: directory.appendingPathComponent("\(request.id).json"))
            lock.unlock()
        }
    }
}
