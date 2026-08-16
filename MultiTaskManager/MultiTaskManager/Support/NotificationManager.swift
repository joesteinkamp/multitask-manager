import Foundation
import AppKit
import UserNotifications

/// Identifiers shared between scheduling a notification and handling the tap on
/// it. Kept outside the class because the delegate callbacks arrive on an
/// arbitrary queue.
enum AttentionNotification {
    static let category = "com.multitaskmanager.needsAttention"
    static let openAction = "MTM_OPEN"
    static let sessionIDsKey = "sessionIds"
}

/// Delivers the alerts `AttentionNotifier` decides on, and owns the
/// `UNUserNotificationCenter` plumbing around them.
///
/// Authorization is requested *lazily*, at the moment the first alert would
/// actually be delivered, rather than at launch. A permission prompt that
/// arrives while the menu bar already shows "1 needs attention" explains itself;
/// one that arrives during a cold first launch does not.
///
/// All mutation happens on the main thread: `SessionStore` is `@MainActor`, and
/// the delegate callbacks hop before touching anything.
final class NotificationManager: NSObject, ObservableObject {
    static let shared = NotificationManager()

    enum Authorization: Equatable {
        case notDetermined
        case authorized
        case provisional
        case denied

        var allowsDelivery: Bool { self == .authorized || self == .provisional }

        var label: String {
            switch self {
            case .notDetermined: return "Not requested yet"
            case .authorized: return "Allowed"
            case .provisional: return "Allowed quietly"
            case .denied: return "Blocked in System Settings"
            }
        }
    }

    @Published private(set) var authorization: Authorization = .notDetermined

    /// Routed to `SessionStore.activate(id:)`. Set once at launch.
    var onOpen: ((String) -> Void)?

    /// Alerts held while the user answers the authorization prompt, so the very
    /// first crossing isn't the one that gets dropped.
    private var deferredAlerts: [AttentionNotifier.Alert] = []
    private var isRequesting = false

    private var center: UNUserNotificationCenter { .current() }

    private override init() { super.init() }

    /// Installs the delegate and the notification category. Must run before any
    /// notification is scheduled, otherwise the "Open" action won't exist on the
    /// first one.
    func bootstrap() {
        center.delegate = self

        let open = UNNotificationAction(
            identifier: AttentionNotification.openAction,
            title: "Open",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: AttentionNotification.category,
            actions: [open],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
        refreshAuthorization()
    }

    func refreshAuthorization() {
        center.getNotificationSettings { settings in
            let mapped = Self.map(settings.authorizationStatus)
            Task { @MainActor in self.authorization = mapped }
        }
    }

    func requestAuthorization() {
        guard !isRequesting else { return }
        isRequesting = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in
                self.isRequesting = false
                self.refreshAuthorization()
                self.flushDeferred()
            }
        }
    }

    /// Opens the Notifications pane so a denied state has somewhere to go.
    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Delivery

    func deliver(_ alerts: [AttentionNotifier.Alert]) {
        guard !alerts.isEmpty else { return }

        switch authorization {
        case .authorized, .provisional:
            alerts.forEach(schedule)
        case .notDetermined:
            // Ask now, with the reason visible on screen, and deliver once the
            // user answers.
            deferredAlerts.append(contentsOf: alerts)
            requestAuthorization()
        case .denied:
            // Not a silent no-op: the badge and the popover still carry this,
            // and Settings shows the denied state with a way to fix it.
            break
        }
    }

    private func flushDeferred() {
        let pending = deferredAlerts
        deferredAlerts = []
        guard authorization.allowsDelivery else { return }
        pending.forEach(schedule)
    }

    private func schedule(_ alert: AttentionNotifier.Alert) {
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = AttentionNotification.category
        content.sound = .default

        switch alert {
        case .single(let session):
            content.title = session.title
            content.subtitle = session.projectName == session.title ? "" : session.projectName
            content.body = Self.body(for: session)
            content.userInfo = [AttentionNotification.sessionIDsKey: [session.id]]

        case .summary(let count, let sessions):
            content.title = "\(count) sessions need you"
            content.body = summaryBody(for: sessions)
            content.userInfo = [AttentionNotification.sessionIDsKey: sessions.map(\.id)]
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // deliver immediately
        )
        center.add(request)
    }

    private func summaryBody(for sessions: [Session]) -> String {
        var names: [String] = []
        for session in sessions where !names.contains(session.projectName) {
            names.append(session.projectName)
        }
        guard names.count > 3 else { return names.joined(separator: ", ") }
        return names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
    }

    /// Prefers what the hook said over what the app inferred. A v2 hook knows
    /// the session stopped at an approval gate; the mtime heuristic only knows
    /// it went quiet.
    static func body(for session: Session) -> String {
        if let reason = session.statusReason, !reason.isEmpty { return reason }
        if let waiting = session.waiting { return waiting.notificationBody }
        if session.audit?.hasEnded == true { return "Finished — ready for you to look at." }

        let quiet = max(0, Date().timeIntervalSince(session.lastActivity))
        return "Quiet for \(RelativeTime.compact(quiet)) — probably waiting on you."
    }

    private static func map(_ status: UNAuthorizationStatus) -> Authorization {
        switch status {
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .denied: return .denied
        default: return .notDetermined
        }
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Banners are the point — this app's whole job is telling you about work
    /// while you're looking at something else.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let identifiers = userInfo[AttentionNotification.sessionIDsKey] as? [String]
        let action = response.actionIdentifier

        Task { @MainActor in
            let opened = action == AttentionNotification.openAction
                || action == UNNotificationDefaultActionIdentifier
            if opened, let first = identifiers?.first {
                NotificationManager.shared.onOpen?(first)
            }
            completionHandler()
        }
    }
}
