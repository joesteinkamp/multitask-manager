import SwiftUI

/// A single session row: status dot, title, metadata, and an actions menu.
struct SessionRowView: View {
    @EnvironmentObject private var store: SessionStore
    let session: Session

    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var pulse = false
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                disclosure
                statusDot

                if isRenaming {
                    TextField("Name", text: $renameText, onCommit: commitRename)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Button(action: { store.activate(session) }) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                if session.isPinned {
                                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                                }
                                Text(session.title)
                                    .font(.callout)
                                    .lineLimit(1)
                                if let waiting = session.waiting {
                                    Image(systemName: waiting.symbolName)
                                        .font(.caption2)
                                        .foregroundStyle(session.status.color)
                                        .help(waiting.label)
                                }
                                if store.isMuted(session) {
                                    Image(systemName: "bell.slash.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .help("Notifications muted for this project")
                                }
                            }
                            Text(subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 4)
                actionsMenu
            }

            if isExpanded, let context = session.context {
                ProjectBriefView(context: context)
                    .padding(.leading, 22)
                    .padding(.trailing, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    // MARK: Disclosure

    /// A chevron that reveals the project briefing, shown only when there's a
    /// briefing to reveal; otherwise a spacer keeps rows aligned.
    @ViewBuilder
    private var disclosure: some View {
        if session.context != nil {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide briefing" : "Show goal · now · next")
        } else {
            Color.clear.frame(width: 12, height: 12)
        }
    }

    // MARK: Status dot

    private var statusDot: some View {
        Image(systemName: session.status.symbolName)
            .foregroundStyle(session.status.color)
            .font(.system(size: 11))
            .opacity(isLive && pulse ? 0.35 : 1)
            .animation(isLive ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { if isLive { pulse = true } }
            .frame(width: 14)
    }

    /// True when activity is recent enough to show a live pulse.
    private var isLive: Bool {
        session.status == .working &&
        Date().timeIntervalSince(session.lastActivity) < Preferences.shared.activeThreshold
    }

    /// Leads with whatever knows most about *why* the session is in this state:
    /// a hook's reason, then the waiting kind, then a finished-run fact from the
    /// audit log, then the tool it last ran — falling back to the plain status
    /// label the app has always shown.
    private var subtitle: String {
        let relative = RelativeTime.string(from: session.lastActivity, status: session.status)
        return "\(leadingDetail) · \(session.source.label) · \(relative)"
    }

    private var leadingDetail: String {
        if let reason = session.statusReason { return reason }
        if let waiting = session.waiting { return waiting.label }
        if session.audit?.hasEnded == true { return "Finished" }
        if session.status == .working, let tool = session.audit?.lastToolName {
            return "Running \(tool)"
        }
        return session.status.label
    }

    // MARK: Actions

    private var actionsMenu: some View {
        Menu {
            Button("Open / Reveal") { store.activate(session) }
            Button(session.isPinned ? "Unpin" : "Pin") { store.togglePin(session) }
            Button(store.isMuted(session) ? "Unmute Notifications" : "Mute Notifications") {
                store.toggleMute(session)
            }
            Button("Rename…") {
                renameText = session.title
                isRenaming = true
            }
            Divider()
            Button("Remove", role: .destructive) { store.remove(session) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
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

/// The expandable per-project briefing: goal, what's happening now, and what to do
/// next. Every line is read from files on disk — no model involved.
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
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
        )
        .padding(.bottom, 2)
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

/// Formats activity timestamps as compact relative strings.
enum RelativeTime {
    static func string(from date: Date, status: SessionStatus) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        let elapsed = compact(seconds)
        switch status {
        case .needsAttention: return "waiting \(elapsed)"
        case .working: return seconds < 5 ? "now" : "\(elapsed) ago"
        default: return "\(elapsed) ago"
        }
    }

    /// Bare elapsed time — "3m", "2h". Also used for notification bodies.
    static func compact(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}
