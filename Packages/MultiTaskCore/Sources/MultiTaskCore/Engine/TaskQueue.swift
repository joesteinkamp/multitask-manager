import Foundation

/// A task, ranked, with the reason it's ranked there.
///
/// The reason is not decoration. "First because Claude is blocked on it" is a
/// different instruction from "first because it's sat for four days", and a
/// ranked list whose ordering can't be explained gets ignored within a week.
public struct ReadyItem: Sendable, Equatable, Identifiable {
    public var task: TaskRecord
    public var reason: String
    /// How many open tasks are waiting on this one.
    public var unblocks: Int

    public var id: String { task.id }

    public init(task: TaskRecord, reason: String, unblocks: Int) {
        self.task = task
        self.reason = reason
        self.unblocks = unblocks
    }
}

/// Answers "what should I do next" — the question the product exists for.
///
/// Distinct from `AttentionTriage`, which ranks what is *blocked*. This ranks
/// what is *available*: a day with nothing blocked should still open to a useful
/// answer.
public enum TaskQueue {

    /// How long a claim survives without being renewed. A crashed agent's task
    /// returns to the queue after this rather than stranding in `running`.
    public static let leaseDuration: TimeInterval = 30 * 60

    // MARK: Readiness

    /// Whether every dependency is done.
    public static func dependenciesMet(_ task: TaskRecord, in index: [String: TaskRecord]) -> Bool {
        task.deps.allSatisfy { index[$0]?.state == .done }
    }

    /// Tasks that could be started right now by `assignee`.
    ///
    /// One implementation, two consumers: the human's ready list and the
    /// autonomous queue differ only by who they filter for.
    public static func ready(for assignee: Assignee?,
                             tasks: [TaskRecord],
                             now: Date = Date()) -> [TaskRecord] {
        let index = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        return tasks.filter { task in
            // `running` belongs here too: a task you started and walked away from
            // is the most available work there is, and leaving it out is how
            // half-finished things get forgotten. One held by *someone else* is
            // excluded by the live-claim check below, so this only surfaces work
            // that is genuinely yours to resume.
            guard task.state == .ready || task.state == .backlog || task.state == .running else {
                return false
            }
            guard !task.isSnoozed(now: now) else { return false }
            guard !task.hasLiveClaim(now: now) else { return false }
            // A task waiting on a person is a request, not available work.
            // Leaving it here would offer an agent something it cannot finish —
            // and `needingAHuman` already surfaces it, separately and by name.
            guard !task.needsAHuman else { return false }
            guard dependenciesMet(task, in: index) else { return false }
            guard let assignee else { return true }
            return task.assignee == assignee
        }
    }

    /// Open tasks that are blocked purely by dependencies.
    public static func blocked(tasks: [TaskRecord], now: Date = Date()) -> [TaskRecord] {
        let index = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        return tasks.filter { $0.state.isOpen && !dependenciesMet($0, in: index) }
    }

    /// Tasks waiting on a human, most urgent first.
    public static func needingAHuman(tasks: [TaskRecord], now: Date = Date()) -> [TaskRecord] {
        tasks.filter { $0.state.isOpen && $0.needsAHuman && !$0.isSnoozed(now: now) }
            .sorted { lhs, rhs in
                let l = lhs.waiting?.triageRank ?? Int.max
                let r = rhs.waiting?.triageRank ?? Int.max
                if l != r { return l < r }
                return lhs.updatedAt < rhs.updatedAt   // longest wait first
            }
    }

    // MARK: The answer

    /// What to do next, ranked and explained.
    ///
    /// Ordering, most significant first:
    /// 1. **Unblocking someone else beats starting something new.** A task other
    ///    work is waiting on is worth more than an equally old task nothing
    ///    depends on — especially when the waiting party is an agent that could
    ///    then run unattended.
    /// 2. **Work already in progress beats work not yet begun**, because leaving
    ///    something half-done is how it gets forgotten.
    /// 3. **Pinned projects**, because the user said they matter.
    /// 4. **Longest ready** last, as the tiebreak — the thing going stale.
    public static func next(for assignee: Assignee?,
                            tasks: [TaskRecord],
                            pinnedProjectIds: Set<String> = [],
                            now: Date = Date(),
                            limit: Int? = nil) -> [ReadyItem] {

        let candidates = ready(for: assignee, tasks: tasks, now: now)
        let blockedCounts = dependents(of: candidates.map(\.id), in: tasks)

        let ranked = candidates
            .map { task -> (item: ReadyItem, key: SortKey) in
                let unblocks = blockedCounts[task.id] ?? 0
                let pinned = task.projectId.map(pinnedProjectIds.contains) ?? false
                let waitingDays = now.timeIntervalSince(task.updatedAt) / 86_400

                let key = SortKey(
                    unblocks: -unblocks,
                    resumed: task.state == .running ? 0 : 1,
                    pinned: pinned ? 0 : 1,
                    negatedAge: -waitingDays
                )
                return (ReadyItem(task: task,
                                  reason: reason(unblocks: unblocks,
                                                 task: task,
                                                 pinned: pinned,
                                                 waitingDays: waitingDays),
                                  unblocks: unblocks), key)
            }
            .sorted { $0.key < $1.key }
            .map(\.item)

        guard let limit else { return ranked }
        return Array(ranked.prefix(limit))
    }

    private struct SortKey: Comparable {
        var unblocks: Int
        var resumed: Int
        var pinned: Int
        var negatedAge: Double

        static func < (lhs: SortKey, rhs: SortKey) -> Bool {
            if lhs.unblocks != rhs.unblocks { return lhs.unblocks < rhs.unblocks }
            if lhs.resumed != rhs.resumed { return lhs.resumed < rhs.resumed }
            if lhs.pinned != rhs.pinned { return lhs.pinned < rhs.pinned }
            return lhs.negatedAge < rhs.negatedAge
        }
    }

    static func reason(unblocks: Int, task: TaskRecord, pinned: Bool, waitingDays: Double) -> String {
        if unblocks > 0 {
            return "Unblocks \(unblocks) other task\(unblocks == 1 ? "" : "s")"
        }
        if task.state == .running { return "Already in progress" }
        if pinned { return "In a pinned project" }
        if waitingDays >= 1 { return "Ready for \(Int(waitingDays)) day\(Int(waitingDays) == 1 ? "" : "s")" }
        return "Ready"
    }

    /// For each id, how many *open* tasks depend on it.
    static func dependents(of ids: [String], in tasks: [TaskRecord]) -> [String: Int] {
        var counts: [String: Int] = [:]
        let wanted = Set(ids)
        for task in tasks where task.state.isOpen {
            for dep in task.deps where wanted.contains(dep) {
                counts[dep, default: 0] += 1
            }
        }
        return counts
    }

    // MARK: Claiming

    /// Takes a task for `owner`, with an expiring lease.
    ///
    /// The lease is what stops two agents doing the same work, and what returns
    /// a crashed agent's task to the queue instead of stranding it in `running`
    /// forever.
    public static func claim(_ task: TaskRecord,
                             by owner: String,
                             now: Date = Date(),
                             duration: TimeInterval = leaseDuration) throws -> TaskRecord {
        if task.hasLiveClaim(now: now), task.claimedBy != owner {
            throw TaskStoreError.alreadyClaimed(by: task.claimedBy ?? "someone")
        }
        var claimed = task
        claimed.claimedBy = owner
        claimed.leaseExpires = now.addingTimeInterval(duration)
        claimed.state = .running
        claimed.updatedAt = now
        return claimed
    }

    /// Returns expired claims to the queue. Run on start and on each pass.
    public static func reclaimExpired(_ tasks: [TaskRecord], now: Date = Date()) -> [TaskRecord] {
        tasks.compactMap { task in
            guard task.state == .running, task.claimedBy != nil, !task.hasLiveClaim(now: now) else {
                return nil
            }
            var released = task
            released.claimedBy = nil
            released.leaseExpires = nil
            released.state = .ready
            released.updatedAt = now
            return released
        }
    }
}
