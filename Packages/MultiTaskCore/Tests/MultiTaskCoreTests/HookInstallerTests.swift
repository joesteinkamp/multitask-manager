import Foundation
import Testing
@testable import MultiTaskCore

/// Installing hooks edits a file the user owns and probably already uses.
@Suite("Installing the status hooks")
struct HookInstallerTests {

    private func installer(_ dir: TempDir) -> HookInstaller {
        HookInstaller(settingsPath: dir.path("settings.json"),
                      scriptPath: "/opt/mtm/hooks/mtm-status.sh")
    }

    private func settings(_ dir: TempDir) -> [String: Any] {
        HookInstaller.readSettings(at: dir.path("settings.json"))
    }

    @Test("Installs into a settings file that does not exist yet")
    func installsFromNothing() throws {
        let dir = TempDir()
        let added = try installer(dir).install()
        #expect(Set(added) == Set(HookInstaller.events.map(\.event)))

        let hooks = try #require(settings(dir)["hooks"] as? [String: Any])
        // The event this exists for.
        #expect(hooks["Notification"] != nil)
        #expect(hooks["Stop"] != nil)
        #expect(hooks["SessionStart"] != nil)
    }

    @Test("Leaves hooks belonging to someone else exactly where they were")
    func preservesForeignHooks() throws {
        let dir = TempDir()
        // A settings file with the user's own hook already in it — the normal
        // case, and the one where overwriting would be unforgivable.
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": [
                "PreToolUse": [
                    ["matcher": "Bash",
                     "hooks": [["type": "command", "command": "~/.ai/log-tool.sh"]]]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: existing)
        try data.write(to: URL(fileURLWithPath: dir.path("settings.json")))

        try installer(dir).install()
        let after = settings(dir)

        // Unrelated settings survive.
        #expect(after["model"] as? String == "opus")

        let hooks = try #require(after["hooks"] as? [String: Any])
        let preToolUse = try #require(hooks["PreToolUse"] as? [[String: Any]])
        // Both are there: theirs and ours.
        let commands = preToolUse.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        #expect(commands.contains { $0.contains("log-tool.sh") })
        #expect(commands.contains { $0.contains(HookInstaller.marker) })
    }

    @Test("Installing twice changes nothing the second time")
    func isIdempotent() throws {
        let dir = TempDir()
        let subject = installer(dir)
        _ = try subject.install()
        let before = try Data(contentsOf: URL(fileURLWithPath: dir.path("settings.json")))

        #expect(try subject.install().isEmpty)
        let after = try Data(contentsOf: URL(fileURLWithPath: dir.path("settings.json")))
        #expect(before == after)
    }

    @Test("The plan reports what is missing without changing anything")
    func planIsReadOnly() throws {
        let dir = TempDir()
        let subject = installer(dir)

        let before = subject.plan()
        #expect(before.adding.count == HookInstaller.events.count)
        #expect(before.isComplete == false)
        #expect(!FileSupport.fileManager.fileExists(atPath: dir.path("settings.json")))

        _ = try subject.install()
        let after = subject.plan()
        #expect(after.isComplete)
        #expect(after.alreadyInstalled.count == HookInstaller.events.count)
    }

    @Test("Uninstalling removes only this app's entries")
    func uninstallIsSurgical() throws {
        let dir = TempDir()
        let existing: [String: Any] = [
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "~/mine.sh"]]]]]
        ]
        try JSONSerialization.data(withJSONObject: existing)
            .write(to: URL(fileURLWithPath: dir.path("settings.json")))

        let subject = installer(dir)
        _ = try subject.install()
        _ = try subject.uninstall()

        let hooks = try #require(settings(dir)["hooks"] as? [String: Any])
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        let commands = stop.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        #expect(commands == ["~/mine.sh"])
    }

    @Test("Every event we ask for is one the harness actually sends")
    func eventsAreReal() {
        // Guards against a typo becoming a hook that never fires — which would
        // look exactly like the feature not working.
        let known: Set<String> = [
            "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
            "PostToolBatch", "Notification", "Stop", "StopFailure", "SubagentStop",
            "PermissionRequest", "PostToolUseFailure"
        ]
        for (event, _) in HookInstaller.events {
            #expect(known.contains(event), "\(event) is not a Claude Code hook event")
        }
    }
}
