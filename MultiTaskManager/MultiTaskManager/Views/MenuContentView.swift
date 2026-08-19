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
    /// Measured height of the project list's content — see `projectList`.
    @State private var listHeight: CGFloat = 0

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

            // Outside the scroll region on purpose: a transient input that can
            // be scrolled away — or clipped by a container with no height — is
            // one that looks like it never opened.
            if isAdding, !store.activeProjects.isEmpty {
                addField.padding(.top, AppTheme.rowPadding)
            }

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
                    Label(projectsNeeding == 1 ? "1 project needs you"
                                            : "\(projectsNeeding) projects need you",
                          systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(AppTheme.attentionColor)
                        .font(.caption)
                } else {
                    // Deliberately uncoloured. Calm is the *absence* of a signal —
                    // if "all clear" is green and a working agent is green, the
                    // colour has stopped meaning anything. Nothing coloured in
                    // view is itself the message.
                    Label("Nothing waiting on you", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
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

            }
            .padding(.vertical, AppTheme.rowPadding)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ListHeightKey.self, value: proxy.size.height)
                }
            )
        }
        .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
        // **`maxHeight` alone collapsed this to nothing.** A ScrollView has no
        // intrinsic height, and a MenuBarExtra window sizes to its content's
        // *ideal* height — which for a ScrollView is effectively zero. So the
        // whole project list rendered at zero points: the header counted four
        // projects above a gap where the list should have been.
        //
        // Measuring the content and asking for that height, capped, gives the
        // behaviour the ceiling was meant to express: grow with the list, scroll
        // past 460.
        .frame(height: min(max(listHeight, 1), 460))
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
            // Two plain buttons rather than one "Add" menu. `Menu` inside a
            // MenuBarExtra window is unreliable across macOS versions, and this
            // footer already had a control reported as doing nothing — a popover
            // is the wrong place to depend on a nested menu opening.
            Button { isAdding.toggle() } label: {
                Label("Task", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
            .help("Capture a task")

            Button { trackProject() } label: {
                Label("Project", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.plain)
            .help("Track a folder as a project")

            Button { store.refresh() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)

            if !store.restorableProjects.isEmpty {
                Menu("Bring back \(store.restorableProjects.count)") {
                    ForEach(store.restorableProjects) { project in
                        Button(project.name) { store.unarchive(project) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Un-archive a project")
            }

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
///
/// **Activate before opening, on every path.** This is an `LSUIElement` agent,
/// so it is not the frontmost app while its popover is showing — and a window
/// created by a background app opens *behind* whatever is in front. `SettingsLink`
/// is the blessed control on macOS 14+ but offers no hook to activate first,
/// which is exactly how Settings ended up opening behind other windows. The
/// `openSettings` environment action is equally supported and can be preceded by
/// the activation the situation needs.
struct SettingsButton: View {
    var body: some View {
        Group {
            if #available(macOS 14.0, *) {
                ModernSettingsButton()
            } else {
                Button {
                    SettingsPresentation.prepare()
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .buttonStyle(.plain)
        .help("Settings")
    }
}

@available(macOS 14.0, *)
private struct ModernSettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            SettingsPresentation.prepare()
            openSettings()
        } label: {
            Image(systemName: "gearshape")
        }
    }
}

/// Makes the app briefly behave like a normal app while a real window is open.
///
/// `LSUIElement` is right for the popover — no Dock icon, no App Switcher entry,
/// nothing in the way. It is wrong for Settings: a window you cannot Cmd-Tab back
/// to is a window you lose behind your editor, which is exactly what happened.
///
/// So the activation policy is raised to `.regular` while a window is open and
/// dropped back to `.accessory` once the last one closes. The Dock icon that
/// appears alongside is the honest cost — an app that is Cmd-Tabbable and has no
/// Dock icon is a worse inconsistency than a Dock icon that comes and goes.
@MainActor
enum SettingsPresentation {
    private static var closeObserver: NSObjectProtocol?

    /// Call immediately *before* opening a window. Activating first is
    /// deterministic; activating after races the window's creation.
    static func prepare() {
        NSApp.setActivationPolicy(.regular)
        // `activate()` is macOS 14+, and this helper is reachable from the
        // macOS 13 path too — the package deploys to 13. On 14+ it is the right
        // call (the `ignoringOtherApps:` variant is deprecated there, and this
        // is a direct response to a click, the case cooperative activation
        // exists for); on 13 that variant is the only one there is.
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        observeClose()
    }

    private static func observeClose() {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { _ in
            // Hopped rather than run inline, so the closing window has left
            // `NSApp.windows` by the time we count what is left.
            //
            // `Task { @MainActor in }` rather than `MainActor.assumeIsolated`,
            // which is macOS 14+ and this deploys to 13.
            Task { @MainActor in
                // `canBecomeMain` is what separates a real window from the menu
                // bar popover, which is a panel and must never hold the app in
                // `.regular`.
                let stillOpen = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
                if !stillOpen { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }
}

/// Carries the project list's measured content height up to its container.
private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
