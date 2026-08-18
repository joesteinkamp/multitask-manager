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
    /// Set when tracking a folder had nothing to do — shown rather than silently
    /// doing nothing, which reads as a broken button.
    @State private var addProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            // Asks come first, above even "what's next". While one of these
            // sits here an agent is stopped, so this is the only thing in the
            // app where the cost of not looking is measured in idle compute
            // rather than in your own attention.
            if !store.pendingApprovals.isEmpty {
                Divider()
                ApprovalsSection()
                    .padding(.horizontal, AppTheme.sectionSpacing)
                    .padding(.vertical, AppTheme.rowSpacing)
            }

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

            if !store.runs.isEmpty {
                Divider()
                RunsSection()
                    .padding(.horizontal, AppTheme.sectionSpacing)
                    .padding(.vertical, AppTheme.rowSpacing)
            }

            if !store.degraded.isEmpty {
                Divider()
                degradedNotice
            }

            Divider()
            footer
        }
        .frame(width: AppTheme.popoverWidth)
        .alert("Nothing to add", isPresented: Binding(get: { addProblem != nil },
                                                      set: { if !$0 { addProblem = nil } })) {
            Button("OK") { addProblem = nil }
        } message: {
            Text(addProblem ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        // Counted separately and named for what they are. `needsAttentionCount`
        // drives the badge and now includes agents' asks, so reusing it here
        // would have reported "3 projects need you" when two of the three were
        // agents waiting on a decision — the wrong thing to go looking for.
        let projectsNeeding = store.activeProjects.filter { $0.status == .needsYou }.count
        let asks = store.pendingApprovals.count
        return VStack(alignment: .leading, spacing: AppTheme.hairSpacing) {
            Text("MultiTask Manager")
                .font(.headline)
            HStack(spacing: AppTheme.rowSpacing) {
                if asks > 0 {
                    Label(asks == 1 ? "An agent is asking you"
                                    : "\(asks) agents are asking you",
                          systemImage: "hand.raised.fill")
                        .foregroundStyle(AppTheme.attentionColor)
                        .font(.caption)
                } else if projectsNeeding > 0 {
                    Label("\(projectsNeeding) project\(projectsNeeding == 1 ? "" : "s") need you",
                          systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(AppTheme.attentionColor)
                        .font(.caption)
                } else {
                    Label("Nothing waiting on you", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.workingColor)
                        .font(.caption)
                }
                Spacer()
                Text("\(store.activeProjects.count) project\(store.activeProjects.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppTheme.sectionSpacing)
    }

    // MARK: List

    private var projectList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.rowSpacing) {
                ForEach(liveProjects) { project in
                    ProjectRowView(project: project)
                }

                if !dormantProjects.isEmpty {
                    if liveProjects.isEmpty {
                        // Nothing is running, so these are the only projects
                        // there are — show them. Collapsing every project behind
                        // a disclosure while the header counts them produces a
                        // list that looks empty and a count that looks wrong,
                        // which is exactly how this read in use.
                        quietHeading
                        ForEach(dormantProjects) { project in
                            ProjectRowView(project: project)
                        }
                    } else {
                        dormantDisclosure
                    }
                }

                if isAdding { addField }
            }
            .padding(.vertical, AppTheme.rowPadding)
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

    /// Shown when the quiet projects are the *only* projects.
    ///
    /// A label rather than a toggle: there is nothing to collapse them in favour
    /// of, and a control whose only outcome is an empty list is not a control.
    private var quietHeading: some View {
        Text("Nothing running right now")
            .font(AppTheme.rowMeta)
            .foregroundStyle(.secondary)
            .padding(.horizontal, AppTheme.sectionSpacing)
            .padding(.bottom, AppTheme.hairSpacing)
    }

    private var dormantDisclosure: some View {
        VStack(alignment: .leading, spacing: AppTheme.tightSpacing) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showingPast.toggle() }
            } label: {
                HStack(spacing: AppTheme.tightSpacing) {
                    Image(systemName: "chevron.right")
                        .font(AppTheme.glyphFont.weight(.semibold))
                        .rotationEffect(.degrees(showingPast ? 90 : 0))
                    Text("\(dormantProjects.count) quiet project\(dormantProjects.count == 1 ? "" : "s")")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, AppTheme.sectionSpacing)
            .help("Projects with no activity and nothing ready to pick up")

            if showingPast {
                ForEach(dormantProjects) { project in
                    ProjectRowView(project: project)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.rowPadding) {
            if isAdding {
                addField.padding(.horizontal, AppTheme.sectionSpacing)
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
        .padding(.vertical, AppTheme.spaciousPadding)
        .padding(.horizontal, AppTheme.sectionSpacing)
    }

    /// Picks a directory to track.
    ///
    /// A folder picker rather than a text field: a project *is* a directory here,
    /// and typing a path is both slower and wrong more often.
    private func trackProject() {
        // Bring the app forward first: a modal opened by a background agent
        // appears behind whatever is in front, which is the same trap the
        // Settings window fell into.
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Track"
        panel.message = "Choose the project's folder."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("projects")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let already = store.trackProject(at: url) {
            addProblem = already
        }
    }

    private var addField: some View {
        TaskComposer(projectId: nil) { isAdding = false }
            .padding(.horizontal, AppTheme.sectionSpacing)
    }

    // MARK: Degraded

    /// "Nothing is running" and "I can't see anything" must not look the same.
    private var degradedNotice: some View {
        VStack(alignment: .leading, spacing: AppTheme.hairSpacing) {
            ForEach(store.degraded, id: \.self) { reason in
                Label(reason.message, systemImage: "eye.trianglebadge.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, AppTheme.sectionSpacing)
        .padding(.vertical, AppTheme.rowSpacing)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: AppTheme.sectionSpacing) {
            // A menu, not a button: "Add" used to mean "add a task" only, which
            // left no way to add a project from the app at all.
            Menu {
                Button("Task…") { isAdding = true }
                Button("Project…") { trackProject() }
                if !store.restorableProjects.isEmpty {
                    Divider()
                    Menu("Bring back") {
                        ForEach(store.restorableProjects) { project in
                            Button(project.name) { store.unarchive(project) }
                        }
                    }
                }
            } label: {
                Label("Add", systemImage: "plus.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

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
        .padding(AppTheme.sectionSpacing)
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
