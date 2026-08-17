import Foundation
import Combine
import MultiTaskCore

/// App-wide settings, backed by `UserDefaults` and observable by SwiftUI.
///
/// This is the app's half of the configuration split: the core defines a plain
/// `Configuration` value and a `ConfigurationProviding` protocol so it can stay
/// free of `UserDefaults` and SwiftUI, and this type supplies one. A daemon
/// would conform something plist-backed the same way.
///
/// `@unchecked Sendable` because `ConfigurationProviding` is `Sendable` and this
/// is a `@Published`-bearing class: every mutation happens from the UI on the
/// main thread, and reads are of value types.
final class Preferences: ObservableObject, ConfigurationProviding, @unchecked Sendable {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    // MARK: Status thresholds (seconds)

    /// Below this gap since last activity, a working session still pulses. Purely
    /// presentational, which is why it lives here rather than in the core.
    @Published var activeThreshold: Double {
        didSet { defaults.set(activeThreshold, forKey: Keys.activeThreshold) }
    }
    @Published var attentionThreshold: Double {
        didSet { defaults.set(attentionThreshold, forKey: Keys.attentionThreshold) }
    }
    @Published var idleThreshold: Double {
        didSet { defaults.set(idleThreshold, forKey: Keys.idleThreshold) }
    }
    @Published var refreshInterval: Double {
        didSet { defaults.set(refreshInterval, forKey: Keys.refreshInterval) }
    }

    // MARK: Signals

    @Published var enableClaudeCode: Bool { didSet { defaults.set(enableClaudeCode, forKey: Keys.enableClaudeCode) } }
    @Published var enableCodex: Bool { didSet { defaults.set(enableCodex, forKey: Keys.enableCodex) } }
    @Published var enableRunningApps: Bool { didSet { defaults.set(enableRunningApps, forKey: Keys.enableRunningApps) } }
    @Published var enableDevFolders: Bool { didSet { defaults.set(enableDevFolders, forKey: Keys.enableDevFolders) } }
    @Published var enableHooks: Bool { didSet { defaults.set(enableHooks, forKey: Keys.enableHooks) } }
    @Published var enableAuditLog: Bool { didSet { defaults.set(enableAuditLog, forKey: Keys.enableAuditLog) } }
    @Published var enableWaves: Bool { didSet { defaults.set(enableWaves, forKey: Keys.enableWaves) } }
    @Published var enableWorktrees: Bool { didSet { defaults.set(enableWorktrees, forKey: Keys.enableWorktrees) } }

    // MARK: Lists

    @Published var devFolders: [String] { didSet { defaults.set(devFolders, forKey: Keys.devFolders) } }
    @Published var bundleAllowlist: [String] { didSet { defaults.set(bundleAllowlist, forKey: Keys.bundleAllowlist) } }
    @Published var appNameKeywords: [String] { didSet { defaults.set(appNameKeywords, forKey: Keys.appNameKeywords) } }

    @Published var hideIdle: Bool { didSet { defaults.set(hideIdle, forKey: Keys.hideIdle) } }
    @Published var enableProjectContext: Bool { didSet { defaults.set(enableProjectContext, forKey: Keys.enableProjectContext) } }

    // MARK: Notifications

    @Published var enableNotifications: Bool { didSet { defaults.set(enableNotifications, forKey: Keys.enableNotifications) } }
    @Published var notificationCooldown: Double { didSet { defaults.set(notificationCooldown, forKey: Keys.notificationCooldown) } }
    /// Quiet hours as minutes from midnight. `quietHoursEnabled` off means neither applies.
    @Published var quietHoursEnabled: Bool { didSet { defaults.set(quietHoursEnabled, forKey: Keys.quietHoursEnabled) } }
    @Published var quietHoursStart: Int { didSet { defaults.set(quietHoursStart, forKey: Keys.quietHoursStart) } }
    @Published var quietHoursEnd: Int { didSet { defaults.set(quietHoursEnd, forKey: Keys.quietHoursEnd) } }

    /// Path to the harness audit log. Empty means "use the documented default".
    @Published var auditLogPath: String { didSet { defaults.set(auditLogPath, forKey: Keys.auditLogPath) } }

    // MARK: ConfigurationProviding

    /// The plain value the engine consumes. Everything above is a UI concern;
    /// this is the contract.
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
            Keys.enableAuditLog: true,
            Keys.enableWaves: true,
            Keys.enableWorktrees: true,
            Keys.hideIdle: false,
            Keys.enableProjectContext: true,
            Keys.enableNotifications: true,
            Keys.notificationCooldown: 10.0 * 60.0,
            Keys.quietHoursEnabled: false,
            Keys.quietHoursStart: 22 * 60,
            Keys.quietHoursEnd: 7 * 60
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
        enableAuditLog = defaults.bool(forKey: Keys.enableAuditLog)
        enableWaves = defaults.bool(forKey: Keys.enableWaves)
        enableWorktrees = defaults.bool(forKey: Keys.enableWorktrees)

        hideIdle = defaults.bool(forKey: Keys.hideIdle)
        enableProjectContext = defaults.bool(forKey: Keys.enableProjectContext)

        enableNotifications = defaults.bool(forKey: Keys.enableNotifications)
        notificationCooldown = defaults.double(forKey: Keys.notificationCooldown)
        quietHoursEnabled = defaults.bool(forKey: Keys.quietHoursEnabled)
        quietHoursStart = defaults.integer(forKey: Keys.quietHoursStart)
        quietHoursEnd = defaults.integer(forKey: Keys.quietHoursEnd)

        devFolders = defaults.stringArray(forKey: Keys.devFolders) ?? []
        bundleAllowlist = defaults.stringArray(forKey: Keys.bundleAllowlist) ?? Self.defaultBundleAllowlist
        appNameKeywords = defaults.stringArray(forKey: Keys.appNameKeywords) ?? Self.defaultNameKeywords
        auditLogPath = defaults.string(forKey: Keys.auditLogPath) ?? ""
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
        static let enableAuditLog = "enableAuditLog"
        static let enableWaves = "enableWaves"
        static let enableWorktrees = "enableWorktrees"
        static let devFolders = "devFolders"
        static let bundleAllowlist = "bundleAllowlist"
        static let appNameKeywords = "appNameKeywords"
        static let hideIdle = "hideIdle"
        static let enableProjectContext = "enableProjectContext"
        static let enableNotifications = "enableNotifications"
        static let notificationCooldown = "notificationCooldown"
        static let quietHoursEnabled = "quietHoursEnabled"
        static let quietHoursStart = "quietHoursStart"
        static let quietHoursEnd = "quietHoursEnd"
        static let auditLogPath = "auditLogPath"
    }
}
