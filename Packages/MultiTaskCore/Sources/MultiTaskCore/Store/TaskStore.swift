import Foundation

/// Why a write was refused.
public enum TaskStoreError: Error, Equatable, CustomStringConvertible {
    case emptyTitle
    case notFound(String)
    /// Dependencies form a cycle. Rejected at write time rather than discovered
    /// at scheduling time, when it would present as work that never becomes
    /// ready and nobody can explain.
    case dependencyCycle([String])
    case unknownDependency(String)
    case alreadyClaimed(by: String)

    public var description: String {
        switch self {
        case .emptyTitle: return "A task needs a title"
        case .notFound(let id): return "No task \(id)"
        case .dependencyCycle(let path): return "Dependency cycle: \(path.joined(separator: " → "))"
        case .unknownDependency(let id): return "Depends on a task that doesn't exist: \(id)"
        case .alreadyClaimed(let who): return "Already claimed by \(who)"
        }
    }
}

/// Reads and writes tasks as one markdown file each under
/// `~/.multitaskmanager/tasks/`.
///
/// Files rather than a database: git-friendly, readable without the app,
/// editable by the agents themselves with the tools they already have, and they
/// survive the app being uninstalled. Consistent with how the harness stores
/// everything else.
public final class TaskStore: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileSupport.stateDirectory
            .appendingPathComponent("tasks", isDirectory: true)
        try? FileSupport.fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public var path: String { directory.path }

    public func load() -> [TaskRecord] {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    private func loadUnlocked() -> [TaskRecord] {
        guard FileSupport.isDirectory(directory) else { return [] }
        return FileSupport.contents(of: directory)
            .filter { $0.pathExtension == "md" }
            .compactMap { url in
                FileSupport.readHead(of: url, limit: 256 * 1024).flatMap(Self.decode)
            }
            .sorted { $0.id < $1.id }
    }

    public func task(id: String) -> TaskRecord? {
        load().first { $0.id == id }
    }

    /// Resolves any unique id prefix, or an exact title match.
    ///
    /// People and agents alike type what they were shown, which is rarely the
    /// whole id.
    public func resolve(_ needle: String) -> TaskRecord? {
        let all = load()
        if let exact = all.first(where: { $0.id == needle }) { return exact }
        let matches = all.filter {
            $0.id.hasPrefix(needle) || $0.title.lowercased() == needle.lowercased()
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Writes a task, validating its dependency graph first.
    @discardableResult
    public func save(_ task: TaskRecord, now: Date = Date()) throws -> TaskRecord {
        guard !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaskStoreError.emptyTitle
        }

        lock.lock()
        defer { lock.unlock() }

        var existing = loadUnlocked()
        existing.removeAll { $0.id == task.id }
        try Self.validateDependencies(of: task, against: existing)

        var updated = task
        updated.updatedAt = now
        write(updated)
        return updated
    }

    /// Creates, or updates in place when `externalRef` already exists.
    ///
    /// This is what makes an agent-driven sync safe to run twice: without it, a
    /// sweep that reruns doubles the board, and the second run is the one that
    /// destroys trust in it.
    /// **Merges rather than replaces.** A sync sweep sends what the tracker knows,
    /// which is rarely everything: the second run of an importer that omits
    /// `acceptance` and `assignee` must not wipe the ones a person set here. So
    /// an absent or empty incoming field keeps whatever the board already had —
    /// the same rule `update` follows, for the same reason.
    @discardableResult
    public func upsert(_ task: TaskRecord, now: Date = Date()) throws -> TaskRecord {
        guard let ref = task.externalRef, !ref.isEmpty,
              let match = load().first(where: { $0.externalRef == ref })
        else { return try save(task, now: now) }

        var merged = task
        merged.id = match.id
        merged.createdAt = match.createdAt

        if merged.acceptance?.isEmpty ?? true { merged.acceptance = match.acceptance }
        if merged.assignee == .unassigned { merged.assignee = match.assignee }
        if merged.body.isEmpty { merged.body = match.body }
        if merged.projectId == nil { merged.projectId = match.projectId }
        if merged.deps.isEmpty { merged.deps = match.deps }
        if merged.sessions.isEmpty { merged.sessions = match.sessions }
        if merged.origin == nil { merged.origin = match.origin }
        // Local state about *this* board's workflow is never the tracker's to
        // set: a claim, a snooze, and a pending question all survive a re-sync.
        merged.claimedBy = match.claimedBy
        merged.leaseExpires = match.leaseExpires
        merged.snoozedUntil = match.snoozedUntil
        if merged.waiting == nil {
            merged.waiting = match.waiting
            merged.waitingReason = match.waitingReason
        }
        // Never silently un-finish work somebody completed locally.
        if match.state == .done { merged.state = .done }

        return try save(merged, now: now)
    }

    public func delete(id: String) {
        lock.lock()
        defer { lock.unlock() }
        try? FileSupport.fileManager.removeItem(at: directory.appendingPathComponent("\(id).md"))
    }

    private func write(_ task: TaskRecord) {
        let url = directory.appendingPathComponent("\(task.id).md")
        try? FileSupport.write(Self.encode(task), to: url)
    }

    // MARK: Dependency validation

    /// Rejects unknown dependencies and cycles, at write time.
    static func validateDependencies(of task: TaskRecord, against others: [TaskRecord]) throws {
        var byId: [String: TaskRecord] = [:]
        for other in others { byId[other.id] = other }
        byId[task.id] = task

        for dep in task.deps where byId[dep] == nil {
            throw TaskStoreError.unknownDependency(dep)
        }

        var visiting: Set<String> = []
        var done: Set<String> = []
        var path: [String] = []

        func visit(_ id: String) throws {
            if done.contains(id) { return }
            if visiting.contains(id) {
                throw TaskStoreError.dependencyCycle(path + [id])
            }
            visiting.insert(id)
            path.append(id)
            for dep in byId[id]?.deps ?? [] { try visit(dep) }
            path.removeLast()
            visiting.remove(id)
            done.insert(id)
        }
        try visit(task.id)
    }

    // MARK: Coding

    static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func encode(_ task: TaskRecord) -> String {
        var fields: [(String, String)] = [
            ("id", task.id),
            ("title", task.title)
        ]
        if let project = task.projectId { fields.append(("project", project)) }
        fields.append(("assignee", task.assignee.encoded))
        fields.append(("state", task.state.rawValue))
        if !task.deps.isEmpty { fields.append(("deps", task.deps.joined(separator: ", "))) }
        if let acceptance = task.acceptance { fields.append(("acceptance", acceptance)) }
        if let waiting = task.waiting { fields.append(("waiting", waiting.rawValue)) }
        if let reason = task.waitingReason { fields.append(("waitingReason", reason)) }
        if let snoozed = task.snoozedUntil { fields.append(("snoozedUntil", formatter.string(from: snoozed))) }
        if let ref = task.externalRef { fields.append(("externalRef", ref)) }
        if let origin = task.origin { fields.append(("origin", origin)) }
        if let claimed = task.claimedBy { fields.append(("claimedBy", claimed)) }
        if let lease = task.leaseExpires { fields.append(("leaseExpires", formatter.string(from: lease))) }
        if !task.sessions.isEmpty { fields.append(("sessions", task.sessions.joined(separator: ", "))) }
        fields.append(("created", formatter.string(from: task.createdAt)))
        fields.append(("updated", formatter.string(from: task.updatedAt)))

        return FrontMatter.render(fields: fields, body: task.body)
    }

    static func decode(_ text: String) -> TaskRecord? {
        let (fields, body) = FrontMatter.parse(text)
        guard let id = fields["id"], !id.isEmpty,
              let title = fields["title"], !title.isEmpty
        else { return nil }

        func list(_ key: String) -> [String] {
            (fields[key] ?? "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        return TaskRecord(
            id: id,
            title: title,
            projectId: fields["project"],
            assignee: Assignee(encoded: fields["assignee"] ?? ""),
            state: TaskState(rawValue: fields["state"] ?? "") ?? .backlog,
            deps: list("deps"),
            acceptance: fields["acceptance"],
            waiting: fields["waiting"].flatMap(WaitingReason.init(rawValue:)),
            waitingReason: fields["waitingReason"],
            snoozedUntil: fields["snoozedUntil"].flatMap(formatter.date(from:)),
            externalRef: fields["externalRef"],
            origin: fields["origin"],
            claimedBy: fields["claimedBy"],
            leaseExpires: fields["leaseExpires"].flatMap(formatter.date(from:)),
            createdAt: fields["created"].flatMap(formatter.date(from:)) ?? Date(),
            updatedAt: fields["updated"].flatMap(formatter.date(from:)) ?? Date(),
            sessions: list("sessions"),
            body: body
        )
    }
}
