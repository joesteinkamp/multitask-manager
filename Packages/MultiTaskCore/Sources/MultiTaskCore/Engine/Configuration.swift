import Foundation

/// Everything the engine needs to know about the user's settings, as plain values.
///
/// The core must not depend on `UserDefaults` or SwiftUI — the app keeps its
/// `ObservableObject` `Preferences` and conforms it to `ConfigurationProviding`,
/// the daemon gets a plist-backed conformance, and tests just build a struct.
public struct Configuration: Sendable, Equatable {
    // MARK: Stagnation thresholds (seconds)

    /// At/above this gap since last activity (and still live) → "needs attention".
    public var attentionThreshold: TimeInterval
    /// At/above this gap → demoted to "idle".
    public var idleThreshold: TimeInterval
    /// Refresh cadence in seconds.
    public var refreshInterval: TimeInterval
    /// Cadence for the expensive git scan, which must not ride the main refresh.
    public var gitRefreshInterval: TimeInterval

    // MARK: Detector toggles

    public var enableClaudeCode: Bool
    public var enableCodex: Bool
    public var enableRunningApps: Bool
    public var enableDevFolders: Bool
    public var enableHooks: Bool
    public var enableAuditLog: Bool
    public var enableWaves: Bool
    public var enableWorktrees: Bool
    /// Derive what each session changed from its transcript.
    public var enableSessionActivity: Bool

    // MARK: Lists

    public var devFolders: [String]
    public var bundleAllowlist: [String]
    public var appNameKeywords: [String]

    /// Repositories to scan for worktrees and converge conflicts.
    public var trackedRepositories: [String]

    /// Whether to hide sessions classified as idle from the main list.
    public var hideIdle: Bool

    /// Whether to assemble per-project briefings (goal / now / next).
    public var enableProjectContext: Bool

    // MARK: Notifications

    public var enableNotifications: Bool
    /// Per-session cooldown so one flapping session can't repeat.
    public var notificationCooldown: TimeInterval
    /// Quiet hours as minutes-from-midnight, local time. `nil` disables them.
    /// A range whose end is before its start wraps past midnight (22:00 → 07:00).
    public var quietHoursStart: Int?
    public var quietHoursEnd: Int?

    /// Path to the harness audit log. Resolved from `AI_TOOL_LOG` when the app can
    /// see it, otherwise the documented default.
    public var auditLogPath: String

    public init(
        attentionThreshold: TimeInterval = 45,
        idleThreshold: TimeInterval = 30 * 60,
        refreshInterval: TimeInterval = 5,
        gitRefreshInterval: TimeInterval = 30,
        enableClaudeCode: Bool = true,
        enableCodex: Bool = true,
        enableRunningApps: Bool = true,
        enableDevFolders: Bool = true,
        enableHooks: Bool = true,
        enableAuditLog: Bool = true,
        enableWaves: Bool = true,
        enableWorktrees: Bool = true,
        enableSessionActivity: Bool = true,
        devFolders: [String] = [],
        bundleAllowlist: [String] = [],
        appNameKeywords: [String] = [],
        trackedRepositories: [String] = [],
        hideIdle: Bool = false,
        enableProjectContext: Bool = true,
        enableNotifications: Bool = true,
        notificationCooldown: TimeInterval = 10 * 60,
        quietHoursStart: Int? = nil,
        quietHoursEnd: Int? = nil,
        auditLogPath: String = Configuration.defaultAuditLogPath
    ) {
        self.attentionThreshold = attentionThreshold
        self.idleThreshold = idleThreshold
        self.refreshInterval = refreshInterval
        self.gitRefreshInterval = gitRefreshInterval
        self.enableClaudeCode = enableClaudeCode
        self.enableCodex = enableCodex
        self.enableRunningApps = enableRunningApps
        self.enableDevFolders = enableDevFolders
        self.enableHooks = enableHooks
        self.enableAuditLog = enableAuditLog
        self.enableWaves = enableWaves
        self.enableWorktrees = enableWorktrees
        self.enableSessionActivity = enableSessionActivity
        self.devFolders = devFolders
        self.bundleAllowlist = bundleAllowlist
        self.appNameKeywords = appNameKeywords
        self.trackedRepositories = trackedRepositories
        self.hideIdle = hideIdle
        self.enableProjectContext = enableProjectContext
        self.enableNotifications = enableNotifications
        self.notificationCooldown = notificationCooldown
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
        self.auditLogPath = auditLogPath
    }

    /// `$AI_TOOL_LOG` when it is visible to this process, else the documented
    /// default. A GUI app launched from Finder inherits no shell environment, so
    /// the app resolves the variable from a login-shell snapshot and passes the
    /// result in rather than relying on this fallback.
    public static var defaultAuditLogPath: String {
        if let env = ProcessInfo.processInfo.environment["AI_TOOL_LOG"], !env.isEmpty {
            return FileSupport.expandingTilde(env)
        }
        return FileSupport.homeDirectory
            .appendingPathComponent(".ai-logs", isDirectory: true)
            .appendingPathComponent("tool-calls.jsonl").path
    }

    public static let `default` = Configuration()
}

/// Supplies the current `Configuration` to the engine. Conformances live in the
/// app (UserDefaults-backed), the daemon (plist-backed), and tests (literal).
public protocol ConfigurationProviding: Sendable {
    var configuration: Configuration { get }
}

/// Trivial conformance for callers that just have a value.
public struct StaticConfiguration: ConfigurationProviding {
    public var configuration: Configuration
    public init(_ configuration: Configuration = .default) {
        self.configuration = configuration
    }
}
