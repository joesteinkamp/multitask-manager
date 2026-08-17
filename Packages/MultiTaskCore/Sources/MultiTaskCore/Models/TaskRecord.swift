import Foundation

/// Who owns a piece of work.
///
/// **Two kinds of actor.** A task assigned to a person is as complete a citizen
/// as one assigned to a delegate: it appears in the ready list, it blocks agent
/// tasks that depend on it, and it accrues time-in-state the same way. A model
/// that treats human work as untracked context around the "real" agent work
/// reproduces exactly the problem this app exists to solve.
///
/// Deliberately not called `Task` — that name belongs to Swift concurrency, and
/// shadowing it inside this module would be a lasting nuisance.
public enum Assignee: Codable, Hashable, Sendable {
    case me
    /// A delegate by its CLI name — "claude", "codex", "agy", "agent", "lm".
    case agent(String)
    case unassigned

    public var isHuman: Bool { self == .me }

    public var isAgent: Bool {
        if case .agent = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .me: return "Me"
        case .agent(let name): return name
        case .unassigned: return "Unassigned"
        }
    }

    /// Round-trips through the front matter as `me`, `agent:claude`, or empty.
    public var encoded: String {
        switch self {
        case .me: return "me"
        case .agent(let name): return "agent:\(name)"
        case .unassigned: return ""
        }
    }

    public init(encoded: String) {
        let value = encoded.trimmingCharacters(in: .whitespaces)
        if value == "me" { self = .me }
        else if value.hasPrefix("agent:") { self = .agent(String(value.dropFirst(6))) }
        else if value.isEmpty { self = .unassigned }
        // A bare delegate name is what a person or an agent will type.
        else { self = .agent(value) }
    }
}

/// Where a task is in its life.
public enum TaskState: String, Codable, CaseIterable, Sendable {
    /// Captured, not yet committed to.
    case backlog
    /// Committed to, and startable once dependencies clear.
    case ready
    /// Someone or something is on it.
    case running
    /// Done by its owner, waiting to be checked.
    case review
    case done
    /// Can't proceed for a reason that isn't a dependency.
    case blocked

    public var isOpen: Bool { self != .done }

    public var label: String {
        switch self {
        case .backlog: return "Backlog"
        case .ready: return "Ready"
        case .running: return "Running"
        case .review: return "Review"
        case .done: return "Done"
        case .blocked: return "Blocked"
        }
    }
}

/// A piece of work that outlives any session.
///
/// Stored as one markdown file with front matter — git-friendly, readable
/// without the app, and editable by the agents themselves with the tools they
/// already have.
public struct TaskRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// Owning project's id. A task without one is loose, which is allowed but
    /// surfaced, since work that belongs to nothing tends to be work nobody does.
    public var projectId: String?
    public var assignee: Assignee
    public var state: TaskState
    /// Ids of tasks that must be `done` first.
    public var deps: [String]

    /// **What "done" means.** Missing acceptance criteria was the single
    /// most-cited quality failure in the prior art this design learned from, and
    /// that system had no field for them — they were expected to live in free
    /// text and so routinely didn't exist. A task without this will be delivered
    /// wrong and rejected, which costs more than asking for it up front.
    public var acceptance: String?

    /// What this task needs from a human, as a field rather than a tag. For an
    /// app whose central question is "what needs me", this state is the product.
    public var waiting: WaitingReason?
    /// Short free text explaining the wait.
    public var waitingReason: String?

    /// Deliberately out of the way until a date. The escape hatch that stops one
    /// impossible item consuming every cycle it's offered in.
    public var snoozedUntil: Date?

    /// `linear:ENG-412`, `notion:<page-id>`. The idempotency key: creating with
    /// an existing ref updates instead of inserting, so a sweep that runs twice
    /// doesn't double the board.
    public var externalRef: String?
    /// Which agent or session filed this, when it came from outside.
    public var origin: String?

    /// Lease held by whoever claimed it, so two agents can't take the same task
    /// and a crashed one's work returns to `ready` rather than stranding.
    public var claimedBy: String?
    public var leaseExpires: Date?

    public var createdAt: Date
    public var updatedAt: Date
    /// Sessions that worked this task.
    public var sessions: [String]

    /// The outcome in prose. This is what gets written into `TASK.md` when the
    /// task is dispatched to a delegate.
    public var body: String

    public init(id: String, title: String, projectId: String? = nil,
                assignee: Assignee = .unassigned, state: TaskState = .backlog,
                deps: [String] = [], acceptance: String? = nil,
                waiting: WaitingReason? = nil, waitingReason: String? = nil,
                snoozedUntil: Date? = nil, externalRef: String? = nil,
                origin: String? = nil, claimedBy: String? = nil,
                leaseExpires: Date? = nil, createdAt: Date = Date(),
                updatedAt: Date = Date(), sessions: [String] = [], body: String = "") {
        self.id = id
        self.title = title
        self.projectId = projectId
        self.assignee = assignee
        self.state = state
        self.deps = deps
        self.acceptance = acceptance
        self.waiting = waiting
        self.waitingReason = waitingReason
        self.snoozedUntil = snoozedUntil
        self.externalRef = externalRef
        self.origin = origin
        self.claimedBy = claimedBy
        self.leaseExpires = leaseExpires
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sessions = sessions
        self.body = body
    }

    /// Snoozed and not yet due.
    public func isSnoozed(now: Date) -> Bool {
        guard let snoozedUntil else { return false }
        return snoozedUntil > now
    }

    /// A claim that has expired is no claim at all — this is what returns a
    /// crashed agent's work to the queue instead of stranding it forever.
    public func hasLiveClaim(now: Date) -> Bool {
        guard claimedBy != nil, let leaseExpires else { return false }
        return leaseExpires > now
    }

    /// Whether a human is being waited on.
    public var needsAHuman: Bool { waiting != nil }

    /// Generates a readable, stable id: a date plus a slug of the title.
    public static func identifier(title: String, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"

        var slug = ""
        var lastWasDash = false
        for character in title.lowercased() {
            if character.isLetter || character.isNumber {
                slug.append(character)
                lastWasDash = false
            } else if !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        }
        slug = String(slug.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(48))
        let stem = slug.isEmpty ? "task" : slug
        return "\(formatter.string(from: now))-\(stem)"
    }
}
