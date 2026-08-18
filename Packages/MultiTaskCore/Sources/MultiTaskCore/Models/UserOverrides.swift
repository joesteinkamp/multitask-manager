import Foundation

/// User-controlled adjustments layered on top of auto-detected sessions.
/// Persisted as JSON in Application Support so manual choices survive relaunch.
public struct UserOverrides: Codable, Sendable {
    /// Stable ids the user removed; these stay hidden across refreshes.
    public var hidden: Set<String> = []
    /// Sessions the user added by hand.
    public var manual: [Session] = []
    /// Custom titles keyed by session id.
    public var renames: [String: String] = [:]
    /// Session ids the user pinned to the top.
    public var pinned: Set<String> = []
    /// Project paths the user muted — they still appear, but never notify.
    public var mutedProjects: Set<String> = []

    public init(hidden: Set<String> = [], manual: [Session] = [],
                renames: [String: String] = [:], pinned: Set<String> = [],
                mutedProjects: Set<String> = []) {
        self.hidden = hidden
        self.manual = manual
        self.renames = renames
        self.pinned = pinned
        self.mutedProjects = mutedProjects
    }

    public static let empty = UserOverrides()
}

/// Loads and saves `UserOverrides` to
/// `~/Library/Application Support/MultiTaskManager/overrides.json`.
public final class OverridesStore {
    public static let shared = OverridesStore()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.multitaskmanager.overrides")

    /// - Parameter directory: override for tests; defaults to Application Support.
    public init(directory: URL? = nil) {
        let base: URL
        if let directory {
            base = directory
        } else {
            base = FileSupport.fileManager
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("MultiTaskManager", isDirectory: true)
        }
        try? FileSupport.fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("overrides.json")
    }

    public func load() -> UserOverrides {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let decoded = try? JSONDecoder().decode(UserOverrides.self, from: data)
            else { return .empty }
            return decoded
        }
    }

    public func save(_ overrides: UserOverrides) {
        queue.async { [fileURL] in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(overrides) else { return }
            try? FileSupport.write(data, to: fileURL)
        }
    }
}
