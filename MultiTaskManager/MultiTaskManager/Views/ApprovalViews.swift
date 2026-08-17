import SwiftUI
import MultiTaskCore

/// Requests from agents waiting on a decision.
///
/// This sits at the very top of the popover, above "what's next" and above the
/// project list, and it is the one section that appears with a coloured
/// treatment. The reasoning is not decorative: while a request sits here an
/// agent is *stopped*. Every other row in the app describes work that is
/// progressing or waiting on something impersonal; these describe work that is
/// waiting on you specifically, and answering takes two seconds. Putting them
/// anywhere else turns a two-second decision into an hour of idle compute.
struct ApprovalsSection: View {
    @EnvironmentObject var store: SessionStore

    var body: some View {
        if !store.pendingApprovals.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.tightSpacing) {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(AppTheme.attentionColor)
                    Text(store.pendingApprovals.count == 1
                         ? "An agent is asking you"
                         : "\(store.pendingApprovals.count) agents are asking you")
                        .font(.headline)
                }

                ForEach(store.pendingApprovals) { request in
                    ApprovalRowView(request: request)
                }
            }
            .padding(AppTheme.rowPadding)
            .background(AppTheme.attentionColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(AppTheme.attentionColor.opacity(0.35), lineWidth: 1)
            )
        }
    }
}

/// One request, with everything needed to decide it in place.
///
/// Deliberately *not* a row that opens a sheet. The whole value of this app is
/// that a decision is answerable where you are; a row that makes you open a
/// window first has spent the advantage it exists to provide. The full command
/// is available on demand, because a person who wants to read it should be able
/// to, and a person who doesn't shouldn't have to scroll past it.
struct ApprovalRowView: View {
    let request: ApprovalRequest

    @EnvironmentObject var store: SessionStore
    @State private var showingDetails = false
    @State private var decliningWithReason = false
    @State private var reason = ""
    @State private var problem: String?
    @State private var deciding = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.tightSpacing) {
            Text(request.summary)
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)

            Text("\(request.requestedBy) · \(Self.age(request.requestedAt))")
                .font(.caption)
                .foregroundStyle(.secondary)

            // The reason the agent gave. Shown without being asked for: it is
            // the single most useful thing for deciding, and hiding it behind a
            // disclosure would mean deciding without it.
            if let rationale = request.rationale {
                Text(rationale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No reason given.")
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
            }

            if showingDetails {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(request.details, id: \.self) { detail in
                        Text(detail)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
            }

            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(AppTheme.attentionColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if decliningWithReason {
                // A decline the agent can learn from. Optional, because forcing
                // a sentence out of someone who just wants it gone is how a
                // queue stops getting cleared.
                HStack(spacing: 4) {
                    TextField("Why not? (optional)", text: $reason)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .onSubmit { decide(approve: false, note: reason) }
                    Button("Decline") { decide(approve: false, note: reason) }
                        .controlSize(.small)
                    Button("Cancel") { decliningWithReason = false; reason = "" }
                        .controlSize(.small)
                }
            } else {
                HStack(spacing: 6) {
                    Button("Approve") { decide(approve: true, note: nil) }
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                    Button("Decline") { decliningWithReason = true }
                        .controlSize(.small)
                    Button(showingDetails ? "Hide command" : "Show command") {
                        showingDetails.toggle()
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .disabled(deciding)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func decide(approve: Bool, note: String?) {
        deciding = true
        problem = nil
        Task {
            let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
            let failure = await store.decide(request, approve: approve,
                                             note: (trimmed?.isEmpty ?? true) ? nil : trimmed)
            deciding = false
            decliningWithReason = false
            reason = ""
            // A failure stays on screen rather than vanishing: the request is
            // still pending, and a row that disappeared would read as success.
            problem = failure
        }
    }

    private static func age(_ date: Date) -> String {
        let seconds = Int(max(0, Date().timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}

/// Runs currently going, and the last few that finished.
///
/// Shows outcome and exit code rather than streaming output. Output lives in a
/// file on purpose — an in-app terminal is a large amount of work to end up
/// worse than the terminal already on the machine — so "Open output" hands the
/// file to whatever the user reads logs with.
struct RunsSection: View {
    @EnvironmentObject var store: SessionStore

    private var visible: [RunRecord] {
        let active = store.activeRuns
        let recent = store.runs.filter { $0.state.isTerminal }.prefix(3)
        return active + recent
    }

    var body: some View {
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.tightSpacing) {
                Text(store.activeRuns.isEmpty ? "Recent runs" : "\(store.activeRuns.count) running")
                    .font(.headline)
                ForEach(visible) { run in
                    RunRowView(run: run)
                }
            }
        }
    }
}

struct RunRowView: View {
    let run: RunRecord
    @EnvironmentObject var store: SessionStore

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(colour)
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 1) {
                Text(run.delegate)
                    .font(.system(size: 12, weight: .medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if !run.state.isTerminal {
                Button("Stop") { store.cancel(run) }
                    .controlSize(.small)
            }
            Button("Output") { store.showOutput(run) }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.vertical, 1)
    }

    private var subtitle: String {
        var parts = [run.state.label]
        if let code = run.exitCode, run.state != .finished { parts.append("exit \(code)") }
        parts.append(Self.duration(run.duration))
        if let note = run.note { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    private var colour: Color {
        switch run.state {
        case .starting, .running: return AppTheme.workingColor
        case .finished: return AppTheme.calmColor
        case .failed: return AppTheme.attentionColor
        case .cancelled: return .secondary
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
}
