import SwiftUI
import MultiTaskCore

/// One project: status, why, progress — and its sessions on disclosure.
///
/// The row always says *why* it is in the state it's in. A status you can't
/// interrogate is one you stop trusting the first time it surprises you, which
/// is why `statusReason` is rendered rather than kept for debugging.
struct ProjectRowView: View {
    @EnvironmentObject private var store: SessionStore
    let project: Project

    @State private var isExpanded = false
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                disclosure
                statusDot

                Button { store.activate(project) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if project.record.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(project.name)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            if store.isMuted(project) {
                                Image(systemName: "bell.slash")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }

                        Text(project.statusReason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if let progress = project.progress {
                            progressBar(progress)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer(minLength: 4)
                actionsMenu
            }

            if isExpanded { detail }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: Disclosure

    @ViewBuilder
    private var disclosure: some View {
        if hasDetail {
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
            .padding(.top, 2)
            .help(isExpanded ? "Hide detail" : "Show sessions, next steps and waves")
        } else {
            Color.clear.frame(width: 12, height: 12)
        }
    }

    private var hasDetail: Bool {
        !project.sessions.isEmpty || !project.nextSteps.isEmpty
            || !project.waves.isEmpty || project.oneLiner != nil
    }

    // MARK: Status

    private var statusDot: some View {
        Image(systemName: project.status.symbolName)
            .foregroundStyle(project.status.color)
            .font(.system(size: 11))
            .opacity(isLive && pulse ? 0.35 : 1)
            .animation(isLive ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                       value: pulse)
            .onAppear { if isLive { pulse = true } }
            .frame(width: 14)
            .padding(.top, 2)
            .help(project.status.label)
    }

    private var isLive: Bool { project.status == .working }

    private func progressBar(_ progress: ProjectProgress) -> some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(Color.secondary.opacity(0.55))
                        .frame(width: max(2, geo.size.width * progress.fraction))
                }
            }
            .frame(height: 3)

            Text(progress.summary)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .frame(maxWidth: 190)
        .padding(.top, 1)
        .help("\(progress.summary) items checked in \(progress.source)")
    }

    // MARK: Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let one = project.oneLiner {
                Text(one)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(project.sessions) { session in
                SessionRowView(session: session)
            }

            if !project.nextSteps.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Next", systemImage: "arrow.right.circle")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(project.nextSteps.prefix(3).enumerated()), id: \.offset) { _, step in
                        Text("· \(step)")
                            .font(.caption2)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            ForEach(project.waves) { wave in
                WaveRowView(wave: wave)
            }

            if !project.briefs.meetsMinimum {
                Label("No PRODUCT.md — add one to get suggestions",
                      systemImage: "doc.badge.plus")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.07))
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: Actions

    private var actionsMenu: some View {
        Menu {
            Button("Reveal in Finder") { store.activate(project) }
            Button(project.record.isPinned ? "Unpin" : "Pin") { store.togglePin(project) }
            Button(store.isMuted(project) ? "Unmute notifications" : "Mute notifications") {
                store.toggleMute(project)
            }
            Divider()
            Button("Park for a week") { store.park(project) }
            Button("Archive") { store.archive(project) }
        } label: {
            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// One orchestration wave, rendered as a unit rather than as N unrelated rows.
struct WaveRowView: View {
    let wave: Wave

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.down.right")
                    .font(.system(size: 9))
                Text(wave.title ?? wave.id)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text("\(wave.doneCount)/\(wave.delegates.count)")
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)

            if let progress = wave.progress {
                Text(progress)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
