import SwiftUI
import MultiTaskCore

/// Root of the menu bar popover.
///
/// **Projects, not sessions.** The previous version listed sessions and grouped
/// them under a project *name* — a string derived from a directory — which is a
/// session monitor with a grouping feature. Here the project is the row and
/// sessions are detail underneath it, and a project with nothing running still
/// appears, because that is often the one that needs attention most.
struct MenuContentView: View {
    @EnvironmentObject private var store: SessionStore

    @State private var isAdding = false
    @State private var showingPast = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            // The decision comes before the context: what to do, then which
            // project is in what state.
            if !store.nextUp.isEmpty || !store.awaitingMe.isEmpty {
                Divider()
                NextUpView()
            }

            Divider()

            if store.activeProjects.isEmpty {
                emptyState
            } else {
                projectList
            }

            if !store.degraded.isEmpty {
                Divider()
                degradedNotice
            }

            Divider()
            footer
        }
        .frame(width: 380)
    }

    // MARK: Header

    private var header: some View {
        let needing = store.needsAttentionCount
        return VStack(alignment: .leading, spacing: 2) {
            Text("MultiTask Manager")
                .font(.headline)
            HStack(spacing: 6) {
                if needing > 0 {
                    Label("\(needing) project\(needing == 1 ? "" : "s") need you",
                          systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                } else {
                    Label("Nothing waiting on you", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
                Spacer()
                Text("\(store.activeProjects.count) project\(store.activeProjects.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    // MARK: List

    private var projectList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(liveProjects) { project in
                    ProjectRowView(project: project)
                }

                if !dormantProjects.isEmpty {
                    dormantDisclosure
                }

                if isAdding { addField }
            }
            .padding(.vertical, 8)
        }
        .frame(maxHeight: 460)
    }

    /// Everything except the quiet ones, which collapse so they don't crowd out
    /// what's live — but they stay one click away rather than disappearing.
    private var liveProjects: [Project] {
        store.activeProjects.filter { $0.status != .dormant }
    }

    private var dormantProjects: [Project] {
        store.activeProjects.filter { $0.status == .dormant }
    }

    private var dormantDisclosure: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showingPast.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showingPast ? 90 : 0))
                    Text("\(dormantProjects.count) gone quiet")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .help("Projects with no activity and nothing ready to pick up")

            if showingPast {
                ForEach(dormantProjects) { project in
                    ProjectRowView(project: project)
                }
            }
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
                Text("No projects tracked yet")
                    .font(.callout)
                Text("Start a Claude Code or Codex session in a project, or capture a task to begin.")
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
        TaskComposer(projectId: nil) { isAdding = false }
            .padding(.horizontal, 12)
    }

    // MARK: Degraded

    /// "Nothing is running" and "I can't see anything" must not look the same.
    private var degradedNotice: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(store.degraded, id: \.self) { reason in
                Label(reason.message, systemImage: "eye.trianglebadge.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button { isAdding.toggle() } label: {
                Label("Add", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)

            Button { store.refresh() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)

            if store.hiddenCount > 0 {
                Button { store.clearHidden() } label: {
                    Label("Restore \(store.hiddenCount)", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
            }

            Spacer()

            SettingsButton()

            Button { NSApplication.shared.terminate(nil) } label: {
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
