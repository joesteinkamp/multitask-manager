import SwiftUI

/// Root of the menu bar popover: summary header, project-grouped session list,
/// and footer actions.
struct MenuContentView: View {
    @EnvironmentObject private var store: SessionStore

    @State private var isAdding = false
    @State private var newTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if store.sessions.isEmpty {
                emptyState
            } else {
                sessionList
            }

            Divider()
            footer
        }
        .frame(width: 340)
    }

    // MARK: Header

    private var header: some View {
        let attention = store.needsAttentionCount
        return VStack(alignment: .leading, spacing: 2) {
            Text("MultiTask Manager")
                .font(.headline)
            HStack(spacing: 6) {
                if attention > 0 {
                    Label("\(attention) need attention", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                } else {
                    Label("All caught up", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
                Spacer()
                Text("\(store.sessions.count) tracked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    // MARK: List

    private var sessionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(store.groupedByProject, id: \.project) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.project)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                        ForEach(sortedSessions(group.sessions)) { session in
                            SessionRowView(session: session)
                        }
                    }
                }
                if isAdding { addField }
            }
            .padding(.vertical, 8)
        }
        .frame(maxHeight: 420)
    }

    private func sortedSessions(_ sessions: [Session]) -> [Session] {
        sessions.sorted { a, b in
            if a.status.sortRank != b.status.sortRank { return a.status.sortRank < b.status.sortRank }
            return a.lastActivity > b.lastActivity
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if isAdding {
                addField.padding(.horizontal, 12)
            } else {
                Image(systemName: "moon.stars")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No active sessions detected")
                    .font(.callout)
                Text("Start a Claude Code or Codex session, or add one manually.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 12)
    }

    private var addField: some View {
        HStack {
            TextField("Name this task…", text: $newTitle, onCommit: commitAdd)
                .textFieldStyle(.roundedBorder)
            Button("Add", action: commitAdd)
                .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
    }

    private func commitAdd() {
        store.addManual(title: newTitle, projectPath: nil)
        newTitle = ""
        isAdding = false
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                isAdding.toggle()
            } label: {
                Label("Add", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)

            Button {
                store.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)

            if store.hiddenCount > 0 {
                Button {
                    store.clearHidden()
                } label: {
                    Label("Restore \(store.hiddenCount)", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
            }

            Spacer()

            SettingsButton()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("Quit")
        }
        .font(.callout)
        .padding(12)
    }
}

/// Opens the Settings scene, working on both macOS 13 and 14+.
struct SettingsButton: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
        } else {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }
}
