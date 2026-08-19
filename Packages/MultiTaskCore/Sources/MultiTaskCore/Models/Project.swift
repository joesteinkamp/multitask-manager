import Foundation

/// Whether a project is competing for attention at all.
///
/// Distinct from status: lifecycle is what *you* decided, status is what the app
/// observed. A parked project isn't dormant — it's deliberately quiet, and
/// conflating the two is how a deliberate decision starts nagging you.
public enum ProjectLifecycle: Codable, Hashable, Sendable {
    case active
    /// Out of the way but not deleted.
    case archived
    /// Deliberately quiet until a date.
    case parked(until: Date)

    public var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    /// A parked project whose date has passed comes back on its own.
    public func resolved(now: Date) -> ProjectLifecycle {
        if case .parked(let until) = self, until <= now { return .active }
        return self
    }
}

/// What a project needs from you, resolved by a fixed ladder.
///
/// Deliberately computed and explainable rather than inferred: every value comes
/// with the reason it was chosen, because a status you can't interrogate is one
/// you stop trusting the first time it surprises you.
public enum ProjectStatus: String, Codable, CaseIterable, Sendable {
    /// Something is blocked on you specifically.
    case needsYou
    /// An agent or a session is working right now.
    case working
    /// Nothing is blocked and there is something you could pick up.
    case ready
    /// Work remains but all of it is waiting on something else.
    case blocked
    /// Quiet, with nothing ready. The failure mode a many-project week produces:
    /// a stuck project makes noise, a forgotten one doesn't, and silence reads
    /// exactly like fine.
    case dormant

    // There was a seventh status here — `unbriefed`, for a project with no
    // `PRODUCT.md`, shown as a grey question mark. It is gone, and it should
    // not come back. "The app hasn't read anything about this project" is a
    // fact about the app's knowledge, not a state of the project, and it
    // belongs nowhere near a row of states that describe whether work is
    // moving. Rendered as a question mark it read as *something is wrong here*
    // — on projects where nothing was wrong at all. A quiet project with no
    // README is quiet, which the ladder already says.

    /// Sort weight, most urgent first.
    public var sortRank: Int {
        switch self {
        case .needsYou: return 0
        case .working: return 1
        case .ready: return 2
        case .blocked: return 3
        case .dormant: return 4
        }
    }

    public var label: String {
        switch self {
        case .needsYou: return "Needs you"
        case .working: return "Working"
        case .ready: return "Ready"
        case .blocked: return "Blocked"
        case .dormant: return "Dormant"
        }
    }
}

/// How far along a project is, from what is already on disk.
///
/// The roadmap checkbox ratio is free — the reader already tells `- [ ]` from
/// `- [x]` and used to discard the checked ones. It is not a complete measure of
/// progress and isn't presented as one; it is a real number where there was
/// previously none.
public struct ProjectProgress: Codable, Hashable, Sendable {
    public var completed: Int
    public var total: Int
    /// Filename the count came from, shown for provenance.
    public var source: String

    public init(completed: Int, total: Int, source: String) {
        self.completed = completed
        self.total = total
        self.source = source
    }

    public var remaining: Int { max(0, total - completed) }

    public var fraction: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }

    public var summary: String { "\(completed) of \(total)" }
}

/// The part of a project that is *decided* rather than observed, and therefore
/// persisted.
///
/// A project exists here whether or not anything is running in it — which is the
/// point. Before this, a project came into being only because an agent happened
/// to run somewhere, so the app could only manage work that had already started.
public struct ProjectRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Repository or working directory. Absent for a project that is still an
    /// idea with a brief.
    public var path: String?
    /// `linear:ENG-412`, `notion:<page-id>` — set when something outside filed
    /// this. Also the idempotency key that stops a sweep run twice from
    /// duplicating the board.
    public var externalRef: String?
    public var lifecycle: ProjectLifecycle
    public var createdAt: Date
    /// Which agent or session filed it, when it came from outside.
    public var origin: String?
    /// Pinned projects sort above their status peers.
    public var isPinned: Bool

    public init(id: String, name: String, path: String? = nil, externalRef: String? = nil,
                lifecycle: ProjectLifecycle = .active, createdAt: Date = Date(),
                origin: String? = nil, isPinned: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.externalRef = externalRef
        self.lifecycle = lifecycle
        self.createdAt = createdAt
        self.origin = origin
        self.isPinned = isPinned
    }

    /// A stable id derived from a path, so a project discovered from a running
    /// session keeps the same identity across refreshes and restarts.
    public static func identifier(forPath path: String) -> String {
        let name = FileSupport.lastComponent(of: path)
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        var collapsed = ""
        var lastWasDash = false
        for character in slug {
            if character == "-" {
                if !lastWasDash { collapsed.append(character) }
                lastWasDash = true
            } else {
                collapsed.append(character)
                lastWasDash = false
            }
        }
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        // Paths can collide on their last component, so disambiguate by a short
        // digest of the full path rather than by name alone.
        return trimmed.isEmpty ? "project-\(shortDigest(of: path))" : "\(trimmed)-\(shortDigest(of: path))"
    }

    /// Identifier for a project that has no path yet — an idea with a brief.
    public static func identifier(forName name: String) -> String {
        let slug = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, character in
                if character == "-" && result.hasSuffix("-") { return }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "project-\(shortDigest(of: name))" : "\(slug)-\(shortDigest(of: name))"
    }

    /// Small non-cryptographic digest — this only has to avoid collisions among
    /// a person's own project directories.
    static func shortDigest(of value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash % 0xFFFFFF, radix: 36)
    }
}

/// A project as the app presents it: the persisted record plus everything
/// observed about it this refresh.
public struct Project: Identifiable, Codable, Hashable, Sendable {
    public var record: ProjectRecord
    public var status: ProjectStatus
    /// Why the status is what it is, in one line the UI can show verbatim.
    public var statusReason: String
    public var brief: ProductBrief?
    public var briefs: BriefSet
    public var progress: ProjectProgress?
    /// Unchecked roadmap items — what you could pick up, before a task store
    /// exists to hold real tasks.
    public var nextSteps: [String]
    /// Steps the agents themselves proposed, harvested from their closing
    /// messages and awaiting a yes or no. Not tasks yet — see `SuggestedStep`.
    public var suggestedSteps: [SuggestedStep] = []
    public var sessions: [Session]
    /// Work belonging to this project — the unit the app actually manages.
    public var tasks: [TaskRecord]
    public var waves: [Wave]
    public var repository: RepositoryState?
    /// Newest activity across everything belonging to this project.
    public var lastActivity: Date

    public var id: String { record.id }
    public var name: String { record.name }
    public var path: String? { record.path }

    /// The one line that says what this project is. The brief's one-liner when
    /// there is one; otherwise whatever the scraped context could manage.
    public var oneLiner: String?

    public init(record: ProjectRecord, status: ProjectStatus, statusReason: String,
                brief: ProductBrief? = nil, briefs: BriefSet = BriefSet(),
                progress: ProjectProgress? = nil, nextSteps: [String] = [],
                suggestedSteps: [SuggestedStep] = [],
                sessions: [Session] = [], tasks: [TaskRecord] = [], waves: [Wave] = [],
                repository: RepositoryState? = nil,
                lastActivity: Date = .distantPast, oneLiner: String? = nil) {
        self.record = record
        self.status = status
        self.statusReason = statusReason
        self.brief = brief
        self.briefs = briefs
        self.progress = progress
        self.nextSteps = nextSteps
        self.suggestedSteps = suggestedSteps
        self.sessions = sessions
        self.tasks = tasks
        self.waves = waves
        self.repository = repository
        self.lastActivity = lastActivity
        self.oneLiner = oneLiner
    }

    public var needsAttentionCount: Int {
        sessions.filter { $0.status == .needsAttention }.count
    }

    public var hasLiveSession: Bool {
        sessions.contains { $0.status == .working }
    }

    /// Open tasks, which is what "how much is left here" actually means once
    /// tasks exist — roadmap checkboxes are the stand-in until they do.
    public var openTasks: [TaskRecord] { tasks.filter { $0.state.isOpen } }

    /// Tasks waiting on a human.
    public var tasksNeedingYou: [TaskRecord] { openTasks.filter(\.needsAHuman) }
}
