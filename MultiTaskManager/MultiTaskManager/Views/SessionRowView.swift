import SwiftUI

/// A single session row: status dot, title, metadata, and an actions menu.
struct SessionRowView: View {
    @EnvironmentObject private var store: SessionStore
    let session: Session

    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
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

    private var subtitle: String {
        "\(session.status.label) · \(session.source.label) · \(RelativeTime.string(from: session.lastActivity, status: session.status))"
    }

    // MARK: Actions

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

    private static func compact(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}
