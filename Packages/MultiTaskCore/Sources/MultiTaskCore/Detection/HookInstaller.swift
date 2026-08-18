import Foundation

/// Wires the status hook into Claude Code's settings.
///
/// **Why this exists rather than a README paragraph.** The app's statuses were
/// inferred from how long a transcript had gone unmodified, which cannot tell a
/// session waiting for a person from one thinking hard — and reported both as
/// needing attention. Claude Code will say which outright, through
/// `Notification` (`permission_prompt`, `agent_needs_input`) and `Stop`. But only
/// if hooks are installed, and a set-up step nobody performs is a feature nobody
/// has.
///
/// Merges rather than overwrites: `settings.json` is the user's file and usually
/// already has hooks in it. Anything this app did not write is left exactly
/// where it was.
public struct HookInstaller: Sendable {
    /// Marks the entries this app owns, so they can be found again to update or
    /// remove without touching anyone else's.
    public static let marker = "mtm-status"

    /// Events worth reporting, and why each one earns its place.
    ///
    /// Deliberately not every event Claude Code offers: each hook is a process
    /// spawned on the user's machine, and the ones omitted say nothing this app
    /// would display.
    public static let events: [(event: String, matcher: String?)] = [
        ("SessionStart", nil),          // a session exists — the instant it starts
        ("UserPromptSubmit", nil),      // working, without waiting for a tool call
        ("PreToolUse", nil),            // still working, and on what
        ("Notification", nil),          // blocked on a person: the whole point
        ("Stop", nil),                  // finished responding
        ("StopFailure", nil),           // finished badly, which is not the same
        ("SessionEnd", nil)             // gone
    ]

    public var settingsPath: String
    public var scriptPath: String

    public init(settingsPath: String? = nil, scriptPath: String? = nil) {
        self.settingsPath = settingsPath
            ?? FileSupport.homeDirectory.appendingPathComponent(".claude/settings.json").path
        self.scriptPath = scriptPath
            ?? FileSupport.stateDirectory.appendingPathComponent("hooks/mtm-status.sh").path
    }

    /// What `install` would change, without changing it.
    public struct Plan: Sendable, Equatable {
        public var settingsPath: String
        public var scriptPath: String
        /// Events that would gain a hook entry.
        public var adding: [String]
        /// Events already wired to this app's script.
        public var alreadyInstalled: [String]
        /// Hooks belonging to something else, which are left alone.
        public var foreignHooks: Int

        public var isComplete: Bool { adding.isEmpty }
    }

    /// Reads the current settings and works out what is missing.
    public func plan(now: Date = Date()) -> Plan {
        let settings = Self.readSettings(at: settingsPath)
        let hooks = settings["hooks"] as? [String: Any] ?? [:]

        var adding: [String] = []
        var installed: [String] = []
        var foreign = 0

        for (event, _) in Self.events {
            let entries = hooks[event] as? [[String: Any]] ?? []
            var found = false
            for entry in entries {
                let commands = (entry["hooks"] as? [[String: Any]]) ?? []
                for command in commands {
                    let text = (command["command"] as? String) ?? ""
                    if text.contains(Self.marker) { found = true } else { foreign += 1 }
                }
            }
            if found { installed.append(event) } else { adding.append(event) }
        }

        return Plan(settingsPath: settingsPath, scriptPath: scriptPath,
                    adding: adding, alreadyInstalled: installed, foreignHooks: foreign)
    }

    /// Adds the missing entries, preserving everything already there.
    ///
    /// - Returns: the events actually added.
    @discardableResult
    public func install() throws -> [String] {
        var settings = Self.readSettings(at: settingsPath)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var added: [String] = []

        for (event, matcher) in Self.events {
            var entries = hooks[event] as? [[String: Any]] ?? []
            let existing = entries.contains { entry in
                let commands = (entry["hooks"] as? [[String: Any]]) ?? []
                return commands.contains { ($0["command"] as? String)?.contains(Self.marker) == true }
            }
            guard !existing else { continue }

            // `"$1"`-style arguments: the script needs the event name, and the
            // matcher when there is one, to tell a permission prompt from a
            // completion.
            var command = "\(scriptPath) \(event)"
            if let matcher { command += " \(matcher)" }

            var entry: [String: Any] = ["hooks": [["type": "command", "command": command]]]
            if let matcher { entry["matcher"] = matcher }
            entries.append(entry)
            hooks[event] = entries
            added.append(event)
        }

        guard !added.isEmpty else { return [] }
        settings["hooks"] = hooks

        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys])
        try FileSupport.write(data, to: URL(fileURLWithPath: settingsPath))
        return added
    }

    /// Removes only this app's entries.
    @discardableResult
    public func uninstall() throws -> [String] {
        var settings = Self.readSettings(at: settingsPath)
        guard var hooks = settings["hooks"] as? [String: Any] else { return [] }
        var removed: [String] = []

        for (event, _) in Self.events {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            let before = entries.count
            entries.removeAll { entry in
                let commands = (entry["hooks"] as? [[String: Any]]) ?? []
                return commands.contains { ($0["command"] as? String)?.contains(Self.marker) == true }
            }
            guard entries.count != before else { continue }
            removed.append(event)
            // An empty array left behind is clutter in someone else's file.
            if entries.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = entries }
        }

        guard !removed.isEmpty else { return [] }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys])
        try FileSupport.write(data, to: URL(fileURLWithPath: settingsPath))
        return removed
    }

    static func readSettings(at path: String) -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }
}
