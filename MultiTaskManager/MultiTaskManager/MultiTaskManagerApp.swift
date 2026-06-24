import SwiftUI

@main
struct MultiTaskManagerApp: App {
    @StateObject private var store = SessionStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(store)
                .onAppear { store.refresh() }
        } label: {
            // Icon + count reflect whether anything needs attention.
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
