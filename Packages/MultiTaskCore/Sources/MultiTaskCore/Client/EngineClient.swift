import Foundation

/// Which sessions a caller wants back.
///
/// Filtering happens engine-side rather than in the caller so that the same
/// question costs the same whether it's answered in-process or across a socket —
/// otherwise every remote client pays to receive rows it immediately discards.
public struct SessionQuery: Codable, Sendable, Equatable {
    /// Only sessions currently waiting on the user, in triage order.
    public var waitingOnly: Bool
    /// Restrict to one project path.
    public var projectPath: String?
    /// Force a detection pass before answering instead of serving the last one.
    public var refresh: Bool

    public init(waitingOnly: Bool = false, projectPath: String? = nil, refresh: Bool = false) {
        self.waitingOnly = waitingOnly
        self.projectPath = projectPath
        self.refresh = refresh
    }

    public static let all = SessionQuery()
}

/// Something a caller asks the engine to do.
///
/// Deliberately limited to the user-override mutations the app already performs.
/// Phase 3's launch, converge and steer actions are *not* here yet: when they
/// arrive, their confirmation gates belong behind this enum's handling, not in
/// the UI that calls it — otherwise the engine becomes a way around the gate.
public enum EngineAction: Codable, Sendable, Equatable {
    case refresh
    case hide(sessionId: String)
    case unhide(sessionId: String)
    case clearHidden
    case pin(sessionId: String)
    case unpin(sessionId: String)
    case rename(sessionId: String, title: String)
    case addManual(title: String, projectPath: String?)
    case removeManual(sessionId: String)
    case mute(projectPath: String)
    case unmute(projectPath: String)

    // Task actions. Organising work is free; anything that spends — starting a
    // run, touching a repository — is gated, and none of those live here yet.
    case createTask(CreateTask)
    case updateTask(UpdateTask)
    case claimTask(taskId: String, owner: String)
    case completeTask(taskId: String, note: String?)
    case snoozeTask(taskId: String, days: Int)
    case deleteTask(taskId: String)

    /// Fields for a new task. A struct rather than a dozen associated values so
    /// the MCP server and the CLI can decode one shape.
    public struct CreateTask: Codable, Sendable, Equatable {
        public var title: String
        public var projectId: String?
        public var assignee: String?
        public var body: String?
        /// What "done" means. Its absence was the most-cited quality failure in
        /// the prior art this design learned from.
        public var acceptance: String?
        public var deps: [String]
        public var externalRef: String?
        public var origin: String?
        public var state: String?

        public init(title: String, projectId: String? = nil, assignee: String? = nil,
                    body: String? = nil, acceptance: String? = nil, deps: [String] = [],
                    externalRef: String? = nil, origin: String? = nil, state: String? = nil) {
            self.title = title
            self.projectId = projectId
            self.assignee = assignee
            self.body = body
            self.acceptance = acceptance
            self.deps = deps
            self.externalRef = externalRef
            self.origin = origin
            self.state = state
        }
    }

    /// A partial update — every field optional, absent means "leave alone".
    public struct UpdateTask: Codable, Sendable, Equatable {
        public var taskId: String
        public var title: String?
        public var state: String?
        public var assignee: String?
        public var acceptance: String?
        public var body: String?
        public var deps: [String]?
        public var waiting: String?
        public var waitingReason: String?
        public var projectId: String?

        public init(taskId: String, title: String? = nil, state: String? = nil,
                    assignee: String? = nil, acceptance: String? = nil, body: String? = nil,
                    deps: [String]? = nil, waiting: String? = nil,
                    waitingReason: String? = nil, projectId: String? = nil) {
            self.taskId = taskId
            self.title = title
            self.state = state
            self.assignee = assignee
            self.acceptance = acceptance
            self.body = body
            self.deps = deps
            self.waiting = waiting
            self.waitingReason = waitingReason
            self.projectId = projectId
        }
    }
}

public struct ActionResult: Codable, Sendable, Equatable {
    public var ok: Bool
    /// Snapshot after the action, so a caller doesn't need a second round-trip.
    public var snapshot: EngineSnapshot?

    public init(ok: Bool, snapshot: EngineSnapshot? = nil) {
        self.ok = ok
        self.snapshot = snapshot
    }
}

/// Something the engine reports without being asked.
public enum EngineEvent: Codable, Sendable {
    /// A new snapshot. Sent whole rather than as a diff — a snapshot is tens of
    /// sessions, so the bandwidth argument is theoretical, while a subtly wrong
    /// diff shows a stale list, which is the exact failure this app exists to
    /// prevent. Suppressed when identical to the last one sent.
    case snapshot(EngineSnapshot)
    /// The notification policy decided the user should be interrupted. The engine
    /// decides; the app delivers. Keeping the decision in one place is what stops
    /// two processes double-notifying about the same session.
    case notify(PendingNotification)
}

/// What the engine can and can't currently see. Backs `mtm doctor` and the
/// Settings health pane.
public struct EngineHealth: Codable, Sendable, Equatable {
    public var auditLogPath: String
    public var auditRecordsRead: Int
    public var auditMalformedLines: Int
    public var auditSessionsIndexed: Int
    /// Sessions matched to the audit log by session id rather than by directory.
    /// The number that decides whether status is a fact or a guess.
    public var preciseJoins: Int
    public var sessionCount: Int
    public var degraded: [DegradedReason]
    public var lastRefresh: Date?
    public var engineVersion: Int

    public init(auditLogPath: String, auditRecordsRead: Int, auditMalformedLines: Int,
                auditSessionsIndexed: Int, preciseJoins: Int, sessionCount: Int,
                degraded: [DegradedReason], lastRefresh: Date?,
                engineVersion: Int = WireProtocol.version) {
        self.auditLogPath = auditLogPath
        self.auditRecordsRead = auditRecordsRead
        self.auditMalformedLines = auditMalformedLines
        self.auditSessionsIndexed = auditSessionsIndexed
        self.preciseJoins = preciseJoins
        self.sessionCount = sessionCount
        self.degraded = degraded
        self.lastRefresh = lastRefresh
        self.engineVersion = engineVersion
    }
}

/// The one interface every face of this app talks to — the popover, a window,
/// `mtm`, and eventually a daemon client.
///
/// Two conformances are planned and the choice is meant to be invisible:
/// `InProcessEngine` runs the detection engine itself, and a later `IPCClient`
/// forwards to `mtmd` over a unix socket. Defining the interface first is what
/// keeps the daemon an optimisation rather than a dependency — and what lets the
/// app fall back to in-process when a daemon it doesn't need goes away.
public protocol EngineClient: Sendable {
    /// Sessions matching `query`, plus the waves and repositories alongside them.
    func list(_ query: SessionQuery) async throws -> EngineSnapshot

    /// One session by id, or `nil` if it isn't currently tracked.
    func get(sessionId: String) async throws -> Session?

    /// What the engine can currently see.
    func health() async throws -> EngineHealth

    /// A stream of snapshots and notifications. The stream finishes when the
    /// client is torn down, or — for a socket client — when the connection drops,
    /// which is the caller's signal to resubscribe or fall back.
    func subscribe() -> AsyncStream<EngineEvent>

    /// Perform an action. Throws `ProtocolFault` on refusal.
    @discardableResult
    func act(_ action: EngineAction) async throws -> ActionResult
}

public extension EngineClient {
    /// Convenience for the common case.
    func list() async throws -> EngineSnapshot { try await list(.all) }
}
