import AppKit
import MultiTaskCore

/// Detects AI desktop apps that are currently running (Claude, ChatGPT/Codex,
/// Cursor, …) via `NSWorkspace`.
///
/// This is the one detector that can't live in `MultiTaskCore`: it needs AppKit,
/// and the core imports Foundation only so it can build and test on Linux. The
/// app injects it through `DetectionEngine(additionalDetectors:)`, which is
/// exactly what that parameter exists for.
///
/// The signal is coarse: it operates at the app level, not per-session, and a
/// GUI app exposes no transcript we can time. We treat the frontmost app as
/// `working` and report a launch timestamp otherwise, so the engine can still
/// age it out. Matching is by bundle-id allowlist OR a name-keyword fallback,
/// because vendor bundle ids vary across builds.
struct RunningAppsDetector: SessionDetector {
    let id = "runningApps"
    let displayName = "AI Desktop Apps"

    /// Read at detect time rather than captured at construction, so toggling the
    /// allowlist in Settings takes effect on the next tick without rebuilding
    /// the detector.
    let configuration: ConfigurationProviding

    init(configuration: ConfigurationProviding) {
        self.configuration = configuration
    }

    func detect() async -> DetectionOutcome {
        let config = configuration.configuration
        guard config.enableRunningApps else { return .empty }

        // NSWorkspace is main-thread-affine in practice; hop there to read it.
        let sessions = await MainActor.run { () -> [Session] in
            let active = NSWorkspace.shared.frontmostApplication?.processIdentifier
            var found: [Session] = []

            for app in NSWorkspace.shared.runningApplications {
                guard app.activationPolicy == .regular else { continue }
                let name = app.localizedName ?? ""
                let bundleId = app.bundleIdentifier ?? ""

                let matchesBundle = config.bundleAllowlist.contains(bundleId)
                let matchesName = config.appNameKeywords.contains {
                    !$0.isEmpty && name.range(of: $0, options: .caseInsensitive) != nil
                }
                guard matchesBundle || matchesName else { continue }

                let isFront = active == app.processIdentifier
                let lastActivity = isFront ? Date() : (app.launchDate ?? Date())

                found.append(Session(
                    id: "app:\(bundleId.isEmpty ? name : bundleId)",
                    title: name,
                    projectName: name,
                    projectPath: nil,
                    source: .desktopApp(bundleId: bundleId),
                    lastActivity: lastActivity,
                    pid: app.processIdentifier,
                    bundleId: bundleId.isEmpty ? nil : bundleId
                ))
            }
            return found
        }

        return DetectionOutcome(sessions: sessions)
    }
}
