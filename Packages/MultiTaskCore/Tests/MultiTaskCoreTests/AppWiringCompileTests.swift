import Foundation
import Testing
@testable import MultiTaskCore

/// Compile-time proof that the macOS app's calls into the core are valid.
///
/// The app can't be built on Linux, so its wiring would otherwise go unchecked
/// until someone opened Xcode. These mirror the exact call shapes in
/// `Preferences.configuration` and `SessionStore.init` — argument labels, order,
/// and defaults included. If the core's signatures drift, this fails here rather
/// than in a build nobody on this machine can run.
@Suite("App wiring")
struct AppWiringCompileTests {

    /// A stand-in for `Preferences`, which is the app's `ConfigurationProviding`.
    struct FakePreferences: ConfigurationProviding {
        var attentionThreshold = 45.0
        var idleThreshold = 1800.0
        var refreshInterval = 5.0
        var enableClaudeCode = true, enableCodex = true, enableRunningApps = true
        var enableDevFolders = true, enableHooks = true, enableAuditLog = true
        var enableWaves = true, enableWorktrees = true
        var devFolders: [String] = [], bundleAllowlist: [String] = [], appNameKeywords: [String] = []
        var hideIdle = false, enableProjectContext = true
        var enableNotifications = true, notificationCooldown = 600.0
        var quietHoursEnabled = false, quietHoursStart = 1320, quietHoursEnd = 420
        var auditLogPath = ""

        // Mirrors Preferences.configuration exactly.
        var configuration: Configuration {
            Configuration(
                attentionThreshold: attentionThreshold,
                idleThreshold: idleThreshold,
                refreshInterval: refreshInterval,
                enableClaudeCode: enableClaudeCode,
                enableCodex: enableCodex,
                enableRunningApps: enableRunningApps,
                enableDevFolders: enableDevFolders,
                enableHooks: enableHooks,
                enableAuditLog: enableAuditLog,
                enableWaves: enableWaves,
                enableWorktrees: enableWorktrees,
                devFolders: devFolders,
                bundleAllowlist: bundleAllowlist,
                appNameKeywords: appNameKeywords,
                hideIdle: hideIdle,
                enableProjectContext: enableProjectContext,
                enableNotifications: enableNotifications,
                notificationCooldown: notificationCooldown,
                quietHoursStart: quietHoursEnabled ? quietHoursStart : nil,
                quietHoursEnd: quietHoursEnabled ? quietHoursEnd : nil,
                auditLogPath: auditLogPath.isEmpty ? Configuration.defaultAuditLogPath
                                                   : FileSupport.expandingTilde(auditLogPath)
            )
        }
    }

    /// Stands in for `RunningAppsDetector`, the one detector that needs AppKit
    /// and so is injected by the app rather than living in the core.
    struct FakeInjectedDetector: SessionDetector {
        let id = "runningApps"
        let displayName = "AI Desktop Apps"
        let configuration: ConfigurationProviding
        func detect() async -> DetectionOutcome {
            guard configuration.configuration.enableRunningApps else { return .empty }
            return DetectionOutcome(sessions: [])
        }
    }

    @Test("Preferences builds a Configuration with the labels the core declares")
    func configurationCallShape() {
        let config = FakePreferences().configuration
        #expect(config.attentionThreshold == 45)
        #expect(config.quietHoursStart == nil)          // quiet hours off ⇒ nil, not 0
        #expect(config.auditLogPath == Configuration.defaultAuditLogPath)
    }

    @Test("SessionStore's engine wiring compiles and runs")
    func engineWiring() async throws {
        let dir = TempDir()
        let prefs = FakePreferences()

        let detection = DetectionEngine(
            configuration: prefs,
            additionalDetectors: [FakeInjectedDetector(configuration: prefs)],
            projectStore: ProjectStore(directory: dir.url.appendingPathComponent("projects"))
        )
        let engine = InProcessEngine(
            configuration: prefs,
            engine: detection,
            overridesStore: OverridesStore(directory: dir.url.appendingPathComponent("state"))
        )

        // The exact sequence SessionStore.start() performs.
        await engine.primeNotifications()
        var iterator = engine.subscribe().makeAsyncIterator()
        _ = try await engine.act(.refresh)
        let event = await iterator.next()
        #expect(event != nil)
        await engine.stop()
    }

    @Test("Every action the app's UI can trigger exists on the engine")
    func actionsUsedByTheApp() {
        // Mirrors SessionStore's action set — a rename here would break the app
        // silently from this machine's point of view.
        let actions: [EngineAction] = [
            .refresh,
            .addManual(title: "t", projectPath: nil),
            .removeManual(sessionId: "s"),
            .hide(sessionId: "s"),
            .rename(sessionId: "s", title: "t"),
            .pin(sessionId: "s"), .unpin(sessionId: "s"),
            .clearHidden,
            .mute(projectPath: "/p"), .unmute(projectPath: "/p")
        ]
        #expect(actions.count == 10)
    }

    @Test("The project fields the popover renders are all reachable")
    func projectSurfaceUsedByViews() {
        let record = ProjectRecord(id: "a", name: "app", path: "/p")
        let project = Project(record: record, status: .needsYou, statusReason: "why",
                              progress: ProjectProgress(completed: 1, total: 4, source: "ROADMAP.md"))

        // Each of these is read by ProjectRowView.
        #expect(project.id == "a")
        #expect(project.name == "app")
        #expect(project.record.isPinned == false)
        #expect(project.record.lifecycle.isActive)
        #expect(project.status.label == "Needs you")
        #expect(project.statusReason == "why")
        #expect(project.progress?.summary == "1 of 4")
        #expect(project.progress?.fraction == 0.25)
        #expect(project.briefs.meetsMinimum == false)
        #expect(project.sessions.isEmpty)
        #expect(project.waves.isEmpty)
        #expect(project.nextSteps.isEmpty)
    }
}
