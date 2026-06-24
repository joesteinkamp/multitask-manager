import Foundation

/// User-controlled adjustments layered on top of auto-detected sessions.
/// Persisted as JSON in Application Support so manual choices survive relaunch.
struct UserOverrides: Codable {
    /// Stable ids the user removed; these stay hidden across refreshes.
    var hidden: Set<String> = []
    /// Sessions the user added by hand.
    var manual: [Session] = []
    /// Custom titles keyed by session id.
    var renames: [String: String] = [:]
    /// Session ids the user pinned to the top.
    var pinned: Set<String> = []

    static let empty = UserOverrides()
}

/// Loads and saves `UserOverrides` to
/// `~/Library/Application Support/MultiTaskManager/overrides.json`.
final class OverridesStore {
    static let shared = OverridesStore()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.multitaskmanager.overrides")

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MultiTaskManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("overrides.json")
    }

    func load() -> UserOverrides {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let decoded = try? JSONDecoder().decode(UserOverrides.self, from: data)
            else { return .empty }
            return decoded
        }
    }

    func save(_ overrides: UserOverrides) {
        queue.async { [fileURL] in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(overrides) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
