import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService` (macOS 13+) for launch-at-login.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns the new state on success; on failure returns the current state.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("LaunchAtLogin toggle failed: \(error.localizedDescription)")
        }
        return isEnabled
    }
}
