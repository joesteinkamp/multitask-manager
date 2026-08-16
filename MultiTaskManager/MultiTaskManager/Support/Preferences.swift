import Foundation
import Combine

/// App-wide settings, backed by `UserDefaults` and observable by SwiftUI.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    // MARK: Stagnation thresholds (seconds)

    /// Below this gap since last activity → "working".
    @Published var activeThreshold: Double {
        didSet { defaults.set(activeThreshold, forKey: Keys.activeThreshold) }
    }
    /// At/above this gap (and still live) → "needs attention".
    @Published var attentionThreshold: Double {
        didSet { defaults.set(attentionThreshold, forKey: Keys.attentionThreshold) }
    }
    /// At/above this gap → demoted to "idle".
    @Published var idleThreshold: Double {
        didSet { defaults.set(idleThreshold, forKey: Keys.idleThreshold) }
    }
    /// Refresh cadence in seconds.
    @Published var refreshInterval: Double {
        didSet { defaults.set(refreshInterval, forKey: Keys.refreshInterval) }
    }

    // MARK: Detector toggles

    @Published var enableClaudeCode: Bool { didSet { defaults.set(enableClaudeCode, forKey: Keys.enableClaudeCode) } }
    @Published var enableCodex: Bool { didSet { defaults.set(enableCodex, forKey: Keys.enableCodex) } }
    @Published var enableRunningApps: Bool { didSet { defaults.set(enableRunningApps, forKey: Keys.enableRunningApps) } }
    @Published var enableDevFolders: Bool { didSet { defaults.set(enableDevFolders, forKey: Keys.enableDevFolders) } }
    @Published var enableHooks: Bool { didSet { defaults.set(enableHooks, forKey: Keys.enableHooks) } }

    // MARK: Lists

    @Published var devFolders: [String] {
        didSet { defaults.set(devFolders, forKey: Keys.devFolders) }
    }
    @Published var bundleAllowlist: [String] {
        didSet { defaults.set(bundleAllowlist, forKey: Keys.bundleAllowlist) }
    }
    @Published var appNameKeywords: [String] {
        didSet { defaults.set(appNameKeywords, forKey: Keys.appNameKeywords) }
    }

    /// Whether to hide sessions classified as idle from the main list.
    @Published var hideIdle: Bool {
        didSet { defaults.set(hideIdle, forKey: Keys.hideIdle) }
    }

    /// Whether to assemble per-project briefings (goal / now / next) from the
    /// project's markdown files and show them in the expandable row.
    @Published var enableProjectContext: Bool {
        didSet { defaults.set(enableProjectContext, forKey: Keys.enableProjectContext) }
    }

    // MARK: Audit log (P1.2)

    /// Whether to read the harness audit log as an activity signal.
    @Published var enableAuditLog: Bool {
        didSet { defaults.set(enableAuditLog, forKey: Keys.enableAuditLog) }
    }

    /// Explicit path to the audit log, overriding `$AI_TOOL_LOG` and the default.
    /// Empty means "resolve it". Needed because a GUI app launched from Finder
    /// doesn't inherit the shell environment that sets `AI_TOOL_LOG`.
    @Published var auditLogPath: String {
        didSet { defaults.set(auditLogPath, forKey: Keys.auditLogPath) }
    }

    // MARK: Notifications (P1.1)

    @Published var enableNotifications: Bool {
        didSet { defaults.set(enableNotifications, forKey: Keys.enableNotifications) }
    }

    /// How long before the same session may notify again.
    @Published var notificationCooldown: Double {
        didSet { defaults.set(notificationCooldown, forKey: Keys.notificationCooldown) }
    }

    @Published var quietHoursEnabled: Bool {
        didSet { defaults.set(quietHoursEnabled, forKey: Keys.quietHoursEnabled) }
    }

    /// Quiet-hours bounds as minutes from local midnight. Windows that wrap past
    /// midnight are normal.
    @Published var quietHoursStart: Double {
        didSet { defaults.set(quietHoursStart, forKey: Keys.quietHoursStart) }
    }
    @Published var quietHoursEnd: Double {
        didSet { defaults.set(quietHoursEnd, forKey: Keys.quietHoursEnd) }
    }

    private init() {
        defaults.register(defaults: [
            Keys.activeThreshold: 20.0,
            Keys.attentionThreshold: 45.0,
            Keys.idleThreshold: 30.0 * 60.0,
            Keys.refreshInterval: 5.0,
            Keys.enableClaudeCode: true,
            Keys.enableCodex: true,
            Keys.enableRunningApps: true,
            Keys.enableDevFolders: true,
            Keys.enableHooks: true,
            Keys.hideIdle: false,
            Keys.enableProjectContext: true,
            Keys.enableAuditLog: true,
            Keys.auditLogPath: "",
            Keys.enableNotifications: true,
            Keys.notificationCooldown: 10.0 * 60.0,
            Keys.quietHoursEnabled: false,
            Keys.quietHoursStart: 22.0 * 60.0,
            Keys.quietHoursEnd: 7.0 * 60.0
        ])

        activeThreshold = defaults.double(forKey: Keys.activeThreshold)
        attentionThreshold = defaults.double(forKey: Keys.attentionThreshold)
        idleThreshold = defaults.double(forKey: Keys.idleThreshold)
        refreshInterval = defaults.double(forKey: Keys.refreshInterval)

        enableClaudeCode = defaults.bool(forKey: Keys.enableClaudeCode)
        enableCodex = defaults.bool(forKey: Keys.enableCodex)
        enableRunningApps = defaults.bool(forKey: Keys.enableRunningApps)
        enableDevFolders = defaults.bool(forKey: Keys.enableDevFolders)
        enableHooks = defaults.bool(forKey: Keys.enableHooks)
        hideIdle = defaults.bool(forKey: Keys.hideIdle)
        enableProjectContext = defaults.bool(forKey: Keys.enableProjectContext)

        enableAuditLog = defaults.bool(forKey: Keys.enableAuditLog)
        auditLogPath = defaults.string(forKey: Keys.auditLogPath) ?? ""

        enableNotifications = defaults.bool(forKey: Keys.enableNotifications)
        notificationCooldown = defaults.double(forKey: Keys.notificationCooldown)
        quietHoursEnabled = defaults.bool(forKey: Keys.quietHoursEnabled)
        quietHoursStart = defaults.double(forKey: Keys.quietHoursStart)
        quietHoursEnd = defaults.double(forKey: Keys.quietHoursEnd)

        devFolders = defaults.stringArray(forKey: Keys.devFolders) ?? []
        bundleAllowlist = defaults.stringArray(forKey: Keys.bundleAllowlist) ?? Self.defaultBundleAllowlist
        appNameKeywords = defaults.stringArray(forKey: Keys.appNameKeywords) ?? Self.defaultNameKeywords
    }

    /// Best-guess bundle ids for common AI desktop apps. Name-keyword matching
    /// covers cases where these are wrong on a given machine.
    static let defaultBundleAllowlist: [String] = [
        "com.anthropic.claudefordesktop",
        "com.anthropic.claude",
        "com.openai.chat",
        "com.todesktop.230313mzl4w4u92" // Cursor
    ]

    static let defaultNameKeywords: [String] = ["Claude", "ChatGPT", "Codex", "Cursor"]

    private enum Keys {
        static let activeThreshold = "activeThreshold"
        static let attentionThreshold = "attentionThreshold"
        static let idleThreshold = "idleThreshold"
        static let refreshInterval = "refreshInterval"
        static let enableClaudeCode = "enableClaudeCode"
        static let enableCodex = "enableCodex"
        static let enableRunningApps = "enableRunningApps"
        static let enableDevFolders = "enableDevFolders"
        static let enableHooks = "enableHooks"
        static let devFolders = "devFolders"
        static let bundleAllowlist = "bundleAllowlist"
        static let appNameKeywords = "appNameKeywords"
        static let hideIdle = "hideIdle"
        static let enableProjectContext = "enableProjectContext"
        static let enableAuditLog = "enableAuditLog"
        static let auditLogPath = "auditLogPath"
        static let enableNotifications = "enableNotifications"
        static let notificationCooldown = "notificationCooldown"
        static let quietHoursEnabled = "quietHoursEnabled"
        static let quietHoursStart = "quietHoursStart"
        static let quietHoursEnd = "quietHoursEnd"
    }

    /// Whether quiet hours are in effect right now.
    var isWithinQuietHours: Bool {
        guard quietHoursEnabled else { return false }
        return QuietHours.isActive(
            at: Date(),
            startMinutes: Int(quietHoursStart),
            endMinutes: Int(quietHoursEnd)
        )
    }
}
