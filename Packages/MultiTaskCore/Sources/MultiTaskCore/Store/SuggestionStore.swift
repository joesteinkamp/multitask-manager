import Foundation

/// Remembers which harvested steps a person has already ruled on.
///
/// **Dismissal has to be permanent, and that is the whole design.** A harvested
/// step is re-derived from the transcript on every refresh, so without a record
/// of the decision, every step the user rejected returns within the minute. One
/// round of that and the queue is something to be cleared rather than read.
/// Accepted steps are recorded for the same reason — the task now exists on the
/// board, and offering to create it a second time is the same bug.
public final class SuggestionStore: @unchecked Sendable {
    public static let shared = SuggestionStore()

    private struct Ledger: Codable {
        var accepted: [String: Date] = [:]
        var dismissed: [String: Date] = [:]
    }

    private let url: URL
    private let lock = NSLock()
    private var ledger: Ledger

    public init(file: URL? = nil) {
        self.url = file ?? FileSupport.stateDirectory.appendingPathComponent("suggestions.json")
        self.ledger = SuggestionStore.load(from: self.url)
    }

    private static func load(from url: URL) -> Ledger {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Ledger.self, from: data) else { return Ledger() }
        return decoded
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(ledger), let text = String(data: data, encoding: .utf8) else { return }
        try? FileSupport.write(text, to: url)
    }

    /// Whether this step has already been ruled on.
    public func isDecided(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ledger.accepted[id] != nil || ledger.dismissed[id] != nil
    }

    /// Drops steps the user has already accepted or dismissed.
    public func pending(_ steps: [SuggestedStep]) -> [SuggestedStep] {
        lock.lock()
        let accepted = ledger.accepted, dismissed = ledger.dismissed
        lock.unlock()
        return steps.filter { accepted[$0.id] == nil && dismissed[$0.id] == nil }
    }

    public func accept(_ step: SuggestedStep, at date: Date = Date()) {
        lock.lock()
        ledger.accepted[step.id] = date
        lock.unlock()
        persist()
    }

    public func dismiss(_ step: SuggestedStep, at date: Date = Date()) {
        lock.lock()
        ledger.dismissed[step.id] = date
        lock.unlock()
        persist()
    }

    /// Undoes a decision, so the step can be offered again on the next refresh.
    public func reconsider(_ id: String) {
        lock.lock()
        ledger.accepted[id] = nil
        ledger.dismissed[id] = nil
        lock.unlock()
        persist()
    }

    public var decidedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return ledger.accepted.count + ledger.dismissed.count
    }
}
