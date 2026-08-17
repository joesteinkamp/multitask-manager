import Foundation
import UserNotifications
import MultiTaskCore

/// Delivers what the engine decided to say.
///
/// The split matters: `NotificationPolicy` in the core decides *whether* to
/// interrupt — edge detection, the two-refresh debounce, the per-session
/// cooldown, coalescing, mute and quiet hours — and it is tested. This type only
/// posts. Keeping the decision in one place is what stops two processes
/// double-notifying about the same session once a daemon exists.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let openAction = "MTM_OPEN"
    static let categoryId = "MTM_ATTENTION"

    /// Set by the app at launch so the "Open" action can focus a session.
    static weak var store: SessionStore?

    private var authorizationRequested = false

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // The delegate has to be installed before the first notification is
        // scheduled, or the action never routes.
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryId,
                actions: [UNNotificationAction(identifier: Self.openAction,
                                               title: "Open",
                                               options: [.foreground])],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    /// - Returns: `false` when authorization was denied, so the caller can say so
    ///   in Settings rather than letting notifications silently never appear.
    @discardableResult
    func deliver(_ notification: PendingNotification) async -> Bool {
        let center = UNUserNotificationCenter.current()

        // Ask in context — the first time there's something real to say — rather
        // than at launch. A permission prompt with a reason attached is far more
        // likely to be granted.
        if !authorizationRequested {
            authorizationRequested = true
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized ||
              settings.authorizationStatus == .provisional else { return false }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.categoryIdentifier = Self.categoryId
        content.userInfo = ["sessionId": notification.primarySessionId]
        content.sound = nil   // The badge is the ambient channel; sound is not.

        // nil trigger delivers immediately.
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        try? await center.add(request)
        return true
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show the banner even when the app is frontmost — with `LSUIElement` there
    /// is no window to notice, so suppressing it would mean losing it.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
    -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard let sessionId = response.notification.request.content.userInfo["sessionId"] as? String
        else { return }
        await MainActor.run { Self.store?.focus(sessionId: sessionId) }
    }
}
