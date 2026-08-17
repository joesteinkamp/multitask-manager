import SwiftUI
import MultiTaskCore

/// A session inside a project row: status dot, what it's doing, and actions.
///
/// Sessions are now *detail* rather than the top level, so this is deliberately
/// quieter than it used to be — smaller type, no project name (the parent row
/// already said it), and the briefing collapsed to the one line that changes.
struct SessionRowView: View {
    @EnvironmentObject private var store: SessionStore
    let session: Session

    @State private var isRenaming = false
    @State private var renameText = ""

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: session.status.symbolName)
                .foregroundStyle(session.status.color)
                .font(.system(size: 9))
                .frame(width: 12)
                .padding(.top, 2)

            if isRenaming {
                TextField("Name", text: $renameText, onCommit: commitRename)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            } else {
                Button { store.activate(session) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            if session.isPinned {
                                Image(systemName: "pin.fill").font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                            }
                            Text(session.title)
                                .font(.caption)
                                .lineLimit(1)
                            if let waiting = session.waiting {
                                Image(systemName: waiting.symbolName)
                                    .font(.system(size: 8))
                                    .foregroundStyle(.orange)
                                    .help(waiting.label)
                            }
                        }
                        Text(subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        // What it changed beats what it was asked: "wrote 4
                        // files" is evidence, the prompt is only intent.
                        if let did = session.activity?.summary {
                            Text(did)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let now = session.context?.now {
                            Text(now)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 4)
            actionsMenu
        }
        .contentShape(Rectangle())
    }

    /// Leads with the reason when there is one — "Needs approval" tells you more
    /// than "Needs attention" ever could.
    private var subtitle: String {
        var parts: [String] = []
        if let reason = session.reason, !reason.isEmpty {
            parts.append(reason)
        } else if let waiting = session.waiting {
            parts.append(waiting.label)
        } else {
            parts.append(session.status.label)
        }
        parts.append(session.source.label)
        parts.append(RelativeTime.string(from: session.lastActivity, status: session.status))
        if let tool = session.lastToolName { parts.append(tool) }
        return parts.joined(separator: " · ")
    }

    private var actionsMenu: some View {
        Menu {
            Button("Open / Reveal") { store.activate(session) }
            Button(session.isPinned ? "Unpin" : "Pin") { store.togglePin(session) }
            Button("Rename…") {
                renameText = session.title
                isRenaming = true
            }
            Divider()
            Button("Remove", role: .destructive) { store.remove(session) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func commitRename() {
        store.rename(session, to: renameText)
        isRenaming = false
    }
}

/// The per-project briefing — goal, now, next — assembled from files on disk
/// with no model involved. Kept for the settings preview and any surface that
/// wants the long form.
struct ProjectBriefView: View {
    let context: ProjectContext

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let goal = context.goal {
                briefLine(icon: "target", title: "Goal", text: goal, source: context.goalSource)
            }
            if let now = context.now {
                briefLine(icon: "waveform", title: "Now", text: now, source: nil)
            }
            if !context.next.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(context.next.enumerated()), id: \.offset) { index, item in
                        briefLine(
                            icon: index == 0 ? "arrow.right.circle" : nil,
                            title: index == 0 ? "Next" : nil,
                            text: item,
                            source: index == 0 ? context.nextSource : nil
                        )
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    @ViewBuilder
    private func briefLine(icon: String?, title: String?, text: String, source: String?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Group {
                if let icon {
                    Image(systemName: icon).font(.system(size: 10))
                } else {
                    Color.clear.frame(width: 10, height: 10)
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: 12)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                if let title {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if let source {
                            Text(source)
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
