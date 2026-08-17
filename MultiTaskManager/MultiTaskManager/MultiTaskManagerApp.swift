import SwiftUI
import MultiTaskCore

@main
struct MultiTaskManagerApp: App {
    @StateObject private var store = SessionStore()

    init() {
        // The notification presenter needs a way back to the store so its
        // "Open" action can focus the right session. Set once, at launch.
        NotificationPresenter.store = nil
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(store)
                .onAppear { NotificationPresenter.store = store }
        } label: {
            // The badge is the ambient channel: it counts *projects* needing
            // you, not sessions, because the project is what you act on.
            let count = store.needsAttentionCount
            Image(systemName: count > 0 ? "bell.badge.fill" : "square.stack.3d.up.fill")
            if count > 0 {
                Text("\(count)")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}
