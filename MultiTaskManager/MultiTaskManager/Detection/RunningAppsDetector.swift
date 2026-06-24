import AppKit

/// Detects AI desktop apps that are currently running (Claude, ChatGPT/Codex,
/// Cursor, …) via `NSWorkspace`.
///
/// This signal is coarse: it operates at the app level, not per-session, and a
/// GUI app exposes no transcript we can time. We treat the frontmost app as
/// `working` and report a launch timestamp otherwise, so the store can still age
/// it out. Matching is by bundle-id allowlist OR a name-keyword fallback, because
/// vendor bundle ids vary across builds.
struct RunningAppsDetector: SessionDetector {
    let id = "runningApps"
    let displayName = "AI Desktop Apps"

    /// Bundle identifiers to always include when running.
    var bundleAllowlist: [String]
    /// Case-insensitive substrings matched against the app's display name.
    var nameKeywords: [String]

    func detect() -> [Session] {
        let active = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var sessions: [Session] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            let name = app.localizedName ?? ""
            let bundleId = app.bundleIdentifier ?? ""

            let matchesBundle = bundleAllowlist.contains(bundleId)
            let matchesName = nameKeywords.contains { !$0.isEmpty && name.range(of: $0, options: .caseInsensitive) != nil }
            guard matchesBundle || matchesName else { continue }

            let isFront = active == app.processIdentifier
            let lastActivity = isFront ? Date() : (app.launchDate ?? Date())

            let session = Session(
                id: "app:\(bundleId.isEmpty ? name : bundleId)",
                title: name,
                projectName: name,
                projectPath: nil,
                source: .desktopApp(bundleId: bundleId),
                lastActivity: lastActivity,
                pid: app.processIdentifier,
                bundleId: bundleId.isEmpty ? nil : bundleId
            )
            sessions.append(session)
        }
        return sessions
    }
}
