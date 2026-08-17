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
        VStack(alignment: .leading, spacing: 8) {
            if !store.awaitingMe.isEmpty { waitingSection }
            if !store.nextUp.isEmpty { nextSection }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Requests, not suggestions — these are things an agent stopped and asked
    /// about, so they come first and read differently.
    private var waitingSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Waiting on you", systemImage: "hand.raised.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)

            ForEach(store.awaitingMe.prefix(3)) { task in
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(Color.orange).frame(width: 5, height: 5).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 1) {
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
        VStack(alignment: .leading, spacing: 4) {
            Label("Do next", systemImage: "arrow.right.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.accentColor)

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

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Button { store.complete(task) } label: {
                Image(systemName: hovering ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(hovering ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Mark done")
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(isLead ? .callout.weight(.medium) : .callout)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 4) {
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
            Divider()
            Button("Snooze a week") { store.snooze(task) }
            if task.waiting != nil {
                Button("Clear the request") { store.resolveWaiting(task) }
            }
            Button("Delete", role: .destructive) { store.delete(task) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 9))
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
    let projectId: String?
    var onFinish: () -> Void

    @State private var title = ""
    @State private var acceptance = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("What needs doing?", text: $title, onCommit: commit)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)

            if !title.isEmpty {
                TextField("Done when… (optional, but it saves a rejected attempt)",
                          text: $acceptance, onCommit: commit)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { onFinish() }
                    .buttonStyle(.link)
                    .font(.caption)
                Button("Add", action: commit)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { titleFocused = true }
    }

    private func commit() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.addTask(
            title: trimmed,
            projectId: projectId,
            acceptance: acceptance.isEmpty ? nil : acceptance
        )
        title = ""
        acceptance = ""
        onFinish()
    }
}
