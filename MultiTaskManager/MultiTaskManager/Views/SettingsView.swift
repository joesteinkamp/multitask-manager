import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            DetectorSettings()
                .tabItem { Label("Detection", systemImage: "antenna.radiowaves.left.and.right") }
            ThresholdSettings()
                .tabItem { Label("Status", systemImage: "timer") }
            NotificationSettings()
                .tabItem { Label("Notifications", systemImage: "bell") }
            DevFolderSettings()
                .tabItem { Label("Dev Folders", systemImage: "folder") }
            AppSettings()
                .tabItem { Label("Apps", systemImage: "app.badge") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 480, height: 400)
    }
}

/// Notification policy, the authorization state, and the mute list.
///
/// The authorization row is deliberately loud when notifications are blocked: a
/// feature that silently does nothing is worse than one that isn't there.
private struct NotificationSettings: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var notifications = NotificationManager.shared
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        Form {
            Section {
                Toggle("Notify when a session needs you", isOn: $prefs.enableNotifications)
                authorizationRow
            }

            Section("Frequency") {
                Stepper(value: $prefs.notificationCooldown, in: 60.0...3600.0, step: 60) {
                    HStack {
                        Text("Don't repeat a session for")
                        Spacer()
                        Text("\(Int(prefs.notificationCooldown / 60))m")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("A crossing has to hold across two refreshes before it notifies, and three or more within 30 seconds arrive as a single summary.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Quiet hours") {
                Toggle("Silence notifications overnight", isOn: $prefs.quietHoursEnabled)
                if prefs.quietHoursEnabled {
                    timeRow("From", value: $prefs.quietHoursStart)
                    timeRow("Until", value: $prefs.quietHoursEnd)
                    Text("Crossings during quiet hours are dropped, not queued — the badge carries them instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !store.mutedProjectKeys.isEmpty {
                Section("Muted projects") {
                    ForEach(store.mutedProjectKeys, id: \.self) { key in
                        HStack {
                            Image(systemName: "bell.slash")
                            Text((key as NSString).lastPathComponent)
                            Spacer()
                            Button("Unmute") { store.unmute(key: key) }
                                .buttonStyle(.link)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { notifications.refreshAuthorization() }
    }

    @ViewBuilder
    private var authorizationRow: some View {
        HStack {
            Label(
                notifications.authorization.label,
                systemImage: notifications.authorization == .denied
                    ? "exclamationmark.triangle.fill"
                    : "checkmark.circle"
            )
            .font(.caption)
            .foregroundStyle(notifications.authorization == .denied ? Color.orange : Color.secondary)

            Spacer()

            switch notifications.authorization {
            case .denied:
                Button("Open System Settings") { notifications.openSystemSettings() }
                    .buttonStyle(.link)
            case .notDetermined:
                Button("Allow…") { notifications.requestAuthorization() }
                    .buttonStyle(.link)
            case .authorized, .provisional:
                EmptyView()
            }
        }
    }

    private func timeRow(_ label: String, value: Binding<Double>) -> some View {
        // Minutes from midnight, in half-hour steps, up to 23:30.
        let range: ClosedRange<Double> = 0...1410
        return Stepper(value: value, in: range, step: 30) {
            HStack {
                Text(label)
                Spacer()
                Text(QuietHours.format(Int(value.wrappedValue)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

private struct DetectorSettings: View {
    @ObservedObject private var prefs = Preferences.shared
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        Form {
            Section("Auto-detection sources") {
                Toggle("Claude Code (CLI) — ~/.claude/projects", isOn: $prefs.enableClaudeCode)
                Toggle("Codex (CLI) — ~/.codex", isOn: $prefs.enableCodex)
                Toggle("AI desktop apps (Claude, ChatGPT, Cursor…)", isOn: $prefs.enableRunningApps)
                Toggle("Dev folder file activity", isOn: $prefs.enableDevFolders)
                Toggle("Hook status files (optional precise signal)", isOn: $prefs.enableHooks)
            }
            Section {
                Toggle("Hide idle sessions", isOn: $prefs.hideIdle)
            }
            Section("Project briefing") {
                Toggle("Show goal / now / next per project", isOn: $prefs.enableProjectContext)
                Text("Reads each project's README/CLAUDE/AGENTS/PROJECT/PRODUCT/GOAL for the goal, the live transcript for what it's working on now, and ROADMAP/TODO checkboxes for what's next. Expand a session row to see it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Harness audit log") {
                Toggle("Use the tool-call log as an activity signal", isOn: $prefs.enableAuditLog)
                TextField("Path (blank = $AI_TOOL_LOG, then ~/.ai-logs/tool-calls.jsonl)",
                          text: $prefs.auditLogPath)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!prefs.enableAuditLog)
                if prefs.enableAuditLog {
                    auditHealth
                }
                Text("Tool-call records give a truer pulse than file timestamps, and a SessionEnd record makes “finished” a fact rather than a guess. Set the path explicitly if $AI_TOOL_LOG is non-standard — a menu bar app doesn't inherit your shell environment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// Health, not statistics. `malformedLines` is the interesting number: it is
    /// expected to be non-zero on a busy machine, because stock macOS has no
    /// `flock` and parallel agents interleave their appends.
    @ViewBuilder
    private var auditHealth: some View {
        if let health = store.auditHealth {
            VStack(alignment: .leading, spacing: 2) {
                if health.exists {
                    Label(
                        "\(health.sessionsTracked) sessions · \(health.recordsIndexed) records read",
                        systemImage: "checkmark.circle"
                    )
                    .foregroundStyle(.secondary)
                    if health.malformedLines > 0 {
                        Label(
                            "\(health.malformedLines) unparseable lines skipped (interleaved appends)",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.secondary)
                    }
                    if health.rotations > 0 {
                        Text("Log rotated \(health.rotations) time(s) since launch")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label("No log at \(health.path) — running on timestamps alone.",
                          systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
    }
}

private struct ThresholdSettings: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section("Stagnation thresholds") {
                stepperRow("Live pulse under", value: $prefs.activeThreshold, range: 2...60, step: 1)
                stepperRow("Needs attention after", value: $prefs.attentionThreshold, range: 5...600, step: 5)
                stepperRow("Demote to idle after", value: $prefs.idleThreshold, range: 60...7200, step: 60)
            }
            Section("Refresh") {
                stepperRow("Refresh every", value: $prefs.refreshInterval, range: 1...60, step: 1)
            }
            Text("A session with no new activity for the “needs attention” window is flagged as waiting for you. Hooks, when configured, override these timings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }

    private func stepperRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(label)
                Spacer()
                Text(formatSeconds(value.wrappedValue)).foregroundStyle(.secondary)
            }
        }
    }

    private func formatSeconds(_ s: Double) -> String {
        if s < 60 { return "\(Int(s))s" }
        if s < 3600 { return "\(Int(s / 60))m" }
        return "\(Int(s / 3600))h"
    }
}

private struct DevFolderSettings: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        VStack(alignment: .leading) {
            Text("Folders watched for recent file edits. Each top-level subfolder is treated as a project.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(prefs.devFolders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder")
                        Text(folder).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) {
                            prefs.devFolders.removeAll { $0 == folder }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 160)

            HStack {
                Button("Add Folder…", action: chooseFolder)
                Spacer()
            }
        }
        .padding()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !prefs.devFolders.contains(url.path) {
                prefs.devFolders.append(url.path)
            }
        }
    }
}

private struct AppSettings: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var newKeyword = ""

    var body: some View {
        VStack(alignment: .leading) {
            Text("Desktop apps are matched by name keyword or bundle id. Add keywords for any AI app you want tracked.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(prefs.appNameKeywords, id: \.self) { keyword in
                    HStack {
                        Image(systemName: "textformat")
                        Text(keyword)
                        Spacer()
                        Button(role: .destructive) {
                            prefs.appNameKeywords.removeAll { $0 == keyword }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 140)

            HStack {
                TextField("Add keyword (e.g. Windsurf)", text: $newKeyword, onCommit: addKeyword)
                    .textFieldStyle(.roundedBorder)
                Button("Add", action: addKeyword)
                    .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
    }

    private func addKeyword() {
        let trimmed = newKeyword.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !prefs.appNameKeywords.contains(trimmed) else { return }
        prefs.appNameKeywords.append(trimmed)
        newKeyword = ""
    }
}

private struct GeneralSettings: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        launchAtLogin = LaunchAtLogin.setEnabled(newValue)
                    }
            }
            Section("About") {
                Text("MultiTask Manager keeps an eye on your concurrent AI sessions and flags the ones waiting on you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
