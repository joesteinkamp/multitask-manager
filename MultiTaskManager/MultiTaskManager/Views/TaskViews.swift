import SwiftUI
import MultiTaskCore

/// The top of the popover: what to do next, and what's blocked on you.
///
/// This is the answer the product exists to give. It sits above the project
/// list because "which project is in what state" is context, and "what should I
/// do" is the decision — and a list you have to interpret before acting is one
/// you stop opening.
struct NextUpView: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.rowPadding) {
            if !store.awaitingMe.isEmpty { waitingSection }
            if !store.nextUp.isEmpty { nextSection }
        }
        .padding(.horizontal, AppTheme.sectionSpacing)
        .padding(.vertical, AppTheme.sectionSpacing)
    }

    /// Requests, not suggestions — these are things an agent stopped and asked
    /// about, so they come first and read differently.
    private var waitingSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.tightSpacing) {
            Label("Waiting on you", systemImage: "hand.raised.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.attentionColor)

            ForEach(store.awaitingMe.prefix(3)) { task in
                HStack(alignment: .top, spacing: AppTheme.rowSpacing) {
                    Circle().fill(AppTheme.attentionColor)
                        .frame(width: AppTheme.inlineDot, height: AppTheme.inlineDot)
                        .padding(.top, AppTheme.tightSpacing)
                    VStack(alignment: .leading, spacing: AppTheme.hairSpacing) {
                        Text(task.title).font(.callout).lineLimit(1)
                        Text(task.waitingReason ?? task.waiting?.label ?? "Waiting")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Button("Resolve") { store.resolveWaiting(task) }
                        .buttonStyle(.link)
                        .font(.caption2)
                        .help("Clear the request — you've dealt with it")
                }
            }
        }
    }

    private var nextSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.tightSpacing) {
            Label("Do next", systemImage: "arrow.right.circle.fill")
                .font(AppTheme.rowDetail.weight(.semibold))
                .foregroundStyle(AppTheme.readyColor)

            ForEach(Array(store.nextUp.prefix(3).enumerated()), id: \.element.id) { index, item in
                TaskRowView(task: item.task, reason: item.reason, isLead: index == 0)
            }
        }
    }
}

/// One task. Used in the "do next" block and inside a project's detail.
struct TaskRowView: View {
    @EnvironmentObject private var store: SessionStore
    let task: TaskRecord
    /// Why this is ranked where it is. Shown because a ranking you can't
    /// interrogate is one you stop trusting.
    var reason: String?
    var isLead = false

    @State private var hovering = false
    /// The confirmation the engine handed back, and the delegate it was for.
    /// Held together so the sheet cannot show one command and authorise another.
    @State private var pendingRun: (ConfirmationRequest, delegate: String)?
    @State private var runProblem: String?

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.rowSpacing) {
            Button { store.complete(task) } label: {
                Image(systemName: hovering ? "checkmark.circle.fill" : "circle")
                    .font(AppTheme.statusGlyphFont)
                    .foregroundStyle(hovering ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Mark done")
            .padding(.top, AppTheme.hairSpacing)

            VStack(alignment: .leading, spacing: AppTheme.hairSpacing) {
                Text(task.title)
                    .font(isLead ? .callout.weight(.medium) : .callout)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: AppTheme.tightSpacing) {
                    if let reason {
                        Text(reason).foregroundStyle(.secondary)
                    } else {
                        Text(task.state.label).foregroundStyle(.secondary)
                    }
                    if task.assignee != .me {
                        Text("· \(task.assignee.label)").foregroundStyle(.tertiary)
                    }
                    if task.claimedBy != nil {
                        Image(systemName: "lock.fill").foregroundStyle(.tertiary)
                    }
                }
                .font(.caption2)

                if let acceptance = task.acceptance, isLead {
                    Text("done when: \(acceptance)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 4)
            menu
        }
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .sheet(isPresented: Binding(get: { pendingRun != nil },
                                    set: { if !$0 { pendingRun = nil } })) {
            if let (confirmation, delegate) = pendingRun {
                RunConfirmationSheet(task: task, confirmation: confirmation, delegate: delegate) {
                    pendingRun = nil
                }
            }
        }
        .alert("Can't run this", isPresented: Binding(get: { runProblem != nil },
                                                      set: { if !$0 { runProblem = nil } })) {
            Button("OK") { runProblem = nil }
        } message: {
            Text(runProblem ?? "")
        }
    }

    /// Asks the engine to describe the run, then shows what it said.
    ///
    /// The app never composes the command or the confirmation text itself: it
    /// displays exactly what the engine returns, and sends back the token that
    /// came with it. Anything else and the sheet and the run could drift apart.
    private func offerRun(with delegate: String) {
        Task {
            let (confirmation, error) = await store.describeRun(task, delegate: delegate)
            if let confirmation {
                pendingRun = (confirmation, delegate)
            } else {
                runProblem = error ?? "The engine wouldn't describe this run."
            }
        }
    }

    private var menu: some View {
        Menu {
            Button("Mark done") { store.complete(task) }
            if task.state != .running {
                Button("Start") { store.start(task) }
            }
            Menu("Hand to") {
                Button("Me") { store.assign(task, to: .me) }
                ForEach(store.delegates, id: \.self) { name in
                    Button(name) { store.assign(task, to: .agent(name)) }
                }
            }
            // Separate from "Hand to" on purpose. Assigning is organising and
            // costs nothing; running spends compute and writes to a repository,
            // and the two reading as one menu item is how you end up spending
            // by accident.
            Menu("Run now with…") {
                ForEach(store.delegates, id: \.self) { name in
                    Button(name) { offerRun(with: name) }
                }
            }
            Divider()
            Button("Snooze a week") { store.snooze(task) }
            if task.waiting != nil {
                Button("Clear the request") { store.resolveWaiting(task) }
            }
            Button("Delete", role: .destructive) { store.delete(task) }
        } label: {
            Image(systemName: "ellipsis")
                .font(AppTheme.glyphFont)
                .foregroundStyle(.tertiary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Capture a piece of work without leaving the popover.
///
/// Deliberately two fields, not a form: a capture box you have to fill in
/// properly is one you route around, and the acceptance line is prompted for
/// rather than required because half-captured work still beats forgotten work.
struct TaskComposer: View {
    @EnvironmentObject private var store: SessionStore
    /// The project this task belongs to. `nil` means "not chosen yet", not
    /// "no project" — see `chosenProject`.
    let projectId: String?
    var onFinish: () -> Void

    @State private var title = ""
    @State private var acceptance = ""
    @State private var selectedProjectId: String?
    @FocusState private var titleFocused: Bool

    /// Where the task will be filed.
    ///
    /// **A task always belongs to a project.** A loose task is one nobody will
    /// ever see in context, and it breaks the thing this product is built on:
    /// the project is the primary unit, and "what should I do next" ranks work
    /// *within* projects. Filing without one produced a central list that
    /// belonged nowhere.
    ///
    /// Composed from a project's row, that project is the answer. Composed from
    /// the footer, the field below asks — defaulting to the project that most
    /// recently did something, which is nearly always the one meant.
    private var chosenProject: String? {
        projectId ?? selectedProjectId ?? store.activeProjects.first?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.tightSpacing) {
            TextField("What needs doing?", text: $title, onCommit: commit)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)

            if !title.isEmpty {
                TextField("Done when… (optional, but it saves a rejected attempt)",
                          text: $acceptance, onCommit: commit)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }

            // Only when the caller did not already know: a task added from a
            // project's own row does not ask which project it is for.
            if projectId == nil {
                Picker("Project", selection: Binding(
                    get: { chosenProject ?? "" },
                    set: { selectedProjectId = $0.isEmpty ? nil : $0 }
                )) {
                    ForEach(store.activeProjects) { project in
                        Text(project.name).tag(project.id)
                    }
                }
                .labelsHidden()
                .font(.caption)
                .disabled(store.activeProjects.isEmpty)
            }

            HStack {
                Spacer()
                Button("Cancel") { onFinish() }
                    .buttonStyle(.link)
                    .font(.caption)
                Button("Add", action: commit)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty
                              || chosenProject == nil)
            }

            if store.activeProjects.isEmpty, projectId == nil {
                Text("Track a project first — a task needs somewhere to belong.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { titleFocused = true }
    }

    private func commit() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard let project = chosenProject else { return }
        store.addTask(
            title: trimmed,
            projectId: project,
            acceptance: acceptance.isEmpty ? nil : acceptance
        )
        title = ""
        acceptance = ""
        onFinish()
    }
}

/// The confirmation shown before a run starts.
///
/// Everything on it comes from the engine. The app contributes layout and
/// nothing else — no re-worded summary, no reconstructed command — because the
/// text a person agrees to and the command that runs have to be the same thing,
/// and the only way to guarantee that is to not have a second source for it.
///
/// The command is shown in full and selectable rather than elided. A delegate's
/// prompt is long, but this is the one moment where the length is the point: it
/// is the last place to notice that the brief says something you didn't mean.
struct RunConfirmationSheet: View {
    let task: TaskRecord
    let confirmation: ConfirmationRequest
    let delegate: String
    let onFinish: () -> Void

    @EnvironmentObject private var store: SessionStore
    @State private var starting = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            Text(confirmation.summary)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: AppTheme.tightSpacing) {
                ForEach(confirmation.details, id: \.self) { detail in
                    Text(detail)
                        .font(AppTheme.monoDetail)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(AppTheme.rowPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(AppTheme.groupFill), in: RoundedRectangle(cornerRadius: AppTheme.controlRadius))

            if task.acceptance == nil {
                // Said plainly at the moment of spending: a delegate with no
                // target to hit reliably delivers the wrong thing, and finding
                // that out afterwards costs more than the run did.
                Label("This task has no acceptance criteria, so nothing defines a good result.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.attentionColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(AppTheme.attentionColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { onFinish() }
                    .keyboardShortcut(.cancelAction)
                Button(starting ? "Starting…" : "Run") { start() }
                    // Deliberately *not* the default action: return should not
                    // start a run, because a sheet that spends on a stray
                    // keypress is not a confirmation.
                    .disabled(starting)
            }
        }
        .padding(AppTheme.loosePadding)
        .frame(width: AppTheme.sheetWidth)
    }

    private func start() {
        starting = true
        problem = nil
        Task {
            let failure = await store.confirmRun(task, delegate: delegate,
                                                 token: confirmation.token)
            starting = false
            if let failure { problem = failure } else { onFinish() }
        }
    }
}
