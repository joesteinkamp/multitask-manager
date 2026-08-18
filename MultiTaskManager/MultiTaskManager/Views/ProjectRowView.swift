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
    @State private var isCapturing = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.tightSpacing) {
            HStack(alignment: .top, spacing: AppTheme.rowPadding) {
                disclosure
                statusDot

                Button { store.activate(project) } label: {
                    VStack(alignment: .leading, spacing: AppTheme.hairSpacing) {
                        HStack(spacing: AppTheme.tightSpacing) {
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
        .padding(.horizontal, AppTheme.sectionSpacing)
        .padding(.vertical, AppTheme.tightSpacing)
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
                    .font(AppTheme.glyphFont.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: AppTheme.statusGlyph, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, AppTheme.hairSpacing)
            .help(isExpanded ? "Hide detail" : "Show sessions, next steps and waves")
        } else {
            Color.clear.frame(width: AppTheme.statusGlyph, height: 12)
        }
    }

    private var hasDetail: Bool {
        !project.sessions.isEmpty || !project.nextSteps.isEmpty || !project.openTasks.isEmpty
            || !project.waves.isEmpty
    }

    // MARK: Status

    private var statusDot: some View {
        Image(systemName: project.status.symbolName)
            .foregroundStyle(project.status.color)
            .font(AppTheme.statusGlyphFont)
            .opacity(isLive && pulse ? 0.35 : 1)
            .animation(isLive ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                       value: pulse)
            .onAppear { if isLive { pulse = true } }
            .frame(width: AppTheme.statusGlyph)
            .padding(.top, AppTheme.hairSpacing)
            .help(project.status.label)
    }

    private var isLive: Bool { project.status == .working }

    private func progressBar(_ progress: ProjectProgress) -> some View {
        HStack(spacing: AppTheme.rowSpacing) {
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
                .font(AppTheme.glyphFont)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .frame(maxWidth: 190)
        .padding(.top, AppTheme.hairSpacing)
        .help("\(progress.summary) items checked in \(progress.source)")
    }

    // MARK: Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: AppTheme.rowSpacing) {
            // The project's own description is deliberately *not* here. You know
            // what your project is; repeating three lines of README above the
            // thing you opened this to see is noise, and it pushed the sessions
            // — the actual answer — below the fold. It still has a place: the
            // collapsed row's subtitle, and `mtm show`.

            // Tasks before sessions: the work is the point, the sessions are
            // how it's being done.
            if !project.openTasks.isEmpty {
                VStack(alignment: .leading, spacing: AppTheme.tightSpacing) {
                    Label("Tasks", systemImage: "checklist")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(project.openTasks.prefix(5)) { task in
                        TaskRowView(task: task)
                    }
                    if project.openTasks.count > 5 {
                        Text("+\(project.openTasks.count - 5) more")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }

            if isCapturing {
                TaskComposer(projectId: project.id) { isCapturing = false }
            } else {
                Button {
                    isCapturing = true
                } label: {
                    Label("Add a task", systemImage: "plus.circle")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            ForEach(project.sessions) { session in
                SessionRowView(session: session)
            }

            if !project.nextSteps.isEmpty && project.openTasks.isEmpty {
                VStack(alignment: .leading, spacing: AppTheme.hairSpacing) {
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
        .padding(.leading, AppTheme.nestedIndent)
        .padding(.trailing, AppTheme.tightSpacing)
        .padding(.vertical, AppTheme.tightSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.controlRadius).fill(Color.secondary.opacity(0.07))
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: Actions

    private var actionsMenu: some View {
        Menu {
            Button("Add a task") { isExpanded = true; isCapturing = true }
            // Two entries, because they are two different places now. Clicking
            // the row goes to the terminal; this one has to keep meaning Finder,
            // or the label lies.
            Button("Go to the terminal") { store.activate(project) }
            Button("Reveal in Finder") {
                if let path = project.path { store.reveal(path) }
            }
            .disabled(project.path == nil)
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
        VStack(alignment: .leading, spacing: AppTheme.hairSpacing) {
            HStack(spacing: AppTheme.tightSpacing) {
                Image(systemName: "square.stack.3d.down.right")
                    .font(AppTheme.glyphFont)
                Text("Wave")
                    .font(AppTheme.rowMeta.weight(.semibold))
                Text(wave.title ?? wave.id)
                    .font(AppTheme.rowMeta)
                    .lineLimit(1)
                Spacer()
                // "4/4" alone is a riddle. It is delegates finished out of
                // delegates dispatched, and the row has to say so.
                Text("\(wave.doneCount) of \(wave.delegates.count) agents done")
                    .font(AppTheme.rowMeta)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .fixedSize()
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
