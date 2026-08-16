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
    /// Projects that never notify. Keyed by project path when there is one, and
    /// by project name otherwise, so the mute survives a session id changing
    /// underneath it — transcripts get new filenames, projects don't move.
    var mutedProjects: Set<String> = []

    static let empty = UserOverrides()

    /// The mute key for a session. Path first: two projects can share a name.
    static func muteKey(for session: Session) -> String {
        session.projectPath ?? session.projectName
    }

    func isMuted(_ session: Session) -> Bool {
        mutedProjects.contains(Self.muteKey(for: session))
    }

    init() {}

    /// Decoded key by key with a fallback per field.
    ///
    /// Swift's synthesized decoder throws on a missing key even when the
    /// property has a default, which would mean every new field silently wipes
    /// the user's existing hides, renames, and pins on upgrade. This is the file
    /// that holds the only state the app can't re-derive — it decodes
    /// permissively on purpose.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hidden = Self.decode(Set<String>.self, .hidden, from: container, fallback: [])
        manual = Self.decode([Session].self, .manual, from: container, fallback: [])
        renames = Self.decode([String: String].self, .renames, from: container, fallback: [:])
        pinned = Self.decode(Set<String>.self, .pinned, from: container, fallback: [])
        mutedProjects = Self.decode(Set<String>.self, .mutedProjects, from: container, fallback: [])
    }

    enum CodingKeys: String, CodingKey {
        case hidden, manual, renames, pinned, mutedProjects
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        _ key: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>,
        fallback: T
    ) -> T {
        guard let decoded = try? container.decodeIfPresent(type, forKey: key) else { return fallback }
        return decoded ?? fallback
    }
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
