import SwiftUI
import AppKit
import MultiTaskCore

struct SettingsView: View {
    var body: some View {
        TabView {
            DetectorSettings()
                .tabItem { Label("Signals", systemImage: "antenna.radiowaves.left.and.right") }
            ThresholdSettings()
                .tabItem { Label("Status", systemImage: "timer") }
            NotificationSettings()
                .tabItem { Label("Notifications", systemImage: "bell") }
            DevFolderSettings()
                .tabItem { Label("Dev Folders", systemImage: "folder") }
            AppSettings()
                .tabItem { Label("Apps", systemImage: "app.badge") }
            HealthSettings()
                .tabItem { Label("Health", systemImage: "stethoscope") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: AppTheme.settingsWidth, height: 400)
    }
}

private struct DetectorSettings: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section("Where sessions come from") {
                Toggle("Claude Code (CLI) — ~/.claude/projects", isOn: $prefs.enableClaudeCode)
                Toggle("Codex (CLI) — ~/.codex", isOn: $prefs.enableCodex)
                Toggle("AI desktop apps (Claude, ChatGPT, Cursor…)", isOn: $prefs.enableRunningApps)
                Toggle("Dev folder file activity", isOn: $prefs.enableDevFolders)
                Toggle("Hook status files (optional precise signal)", isOn: $prefs.enableHooks)
            }
            Section("Harness signals") {
                Toggle("Harness audit log — real activity, and when a run ends", isOn: $prefs.enableAuditLog)
                Toggle("Orchestration waves — ~/.ai-context", isOn: $prefs.enableWaves)
                Toggle("Worktrees and stalled converges (runs git)", isOn: $prefs.enableWorktrees)
                Text("The audit log is what makes “finished” a fact rather than a guess: it records an explicit end-of-session event, where file timestamps can only show that something went quiet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Hide idle sessions", isOn: $prefs.hideIdle)
            }
            Section("Project briefing") {
                Toggle("Show goal / now / next per project", isOn: $prefs.enableProjectContext)
                Text("A project's goal comes from the One-liner in its PRODUCT.md when it has one, and is scraped from README/CLAUDE/AGENTS otherwise. Now comes from the live transcript; Next from ROADMAP/TODO checkboxes, which also give the progress count.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

/// The policy behind these lives in the core and is tested there; this pane only
/// sets its inputs.
private struct NotificationSettings: View {
    @ObservedObject private var prefs = Preferences.shared
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        Form {
            Section {
                Toggle("Notify when a project needs me", isOn: $prefs.enableNotifications)
                if store.notificationsDenied {
                    HStack(spacing: AppTheme.rowSpacing) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AppTheme.attentionColor)
                        Text("macOS denied notification permission — the badge still works.")
                            .font(.caption)
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .font(.caption)
                    }
                }
            }
            Section("Restraint") {
                Stepper(value: $prefs.notificationCooldown, in: 60...3600, step: 60) {
                    HStack {
                        Text("Don't repeat a session for")
                        Spacer()
                        Text("\(Int(prefs.notificationCooldown / 60))m").foregroundStyle(.secondary)
                    }
                }
                Text("A crossing must also hold across two refreshes before it notifies, and three or more at once arrive as a single message. Those two rules aren't adjustable — they're what stop a flapping timeout from becoming an alert every few seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Quiet hours") {
                Toggle("Stay quiet overnight", isOn: $prefs.quietHoursEnabled)
                if prefs.quietHoursEnabled {
                    minutePicker("From", value: $prefs.quietHoursStart)
                    minutePicker("Until", value: $prefs.quietHoursEnd)
                    Text("Notifications inside quiet hours are dropped, not queued — a backlog arriving at 7am is the burst this exists to prevent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func minutePicker(_ label: String, value: Binding<Int>) -> some View {
        Stepper(value: value, in: 0...(23 * 60 + 30), step: 30) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%02d:%02d", value.wrappedValue / 60, value.wrappedValue % 60))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

/// What the app can and can't currently see. "Nothing is running" and "I can't
/// read anything" must never look the same.
private struct HealthSettings: View {
    @ObservedObject private var prefs = Preferences.shared
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        Form {
            Section("Harness audit log") {
                TextField("Path (blank uses $AI_TOOL_LOG, then the default)",
                          text: $prefs.auditLogPath)
                Text(Configuration.defaultAuditLogPath)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Section("Sources") {
                if store.degraded.isEmpty {
                    Label("Everything readable", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.workingColor)
                        .font(.callout)
                } else {
                    ForEach(store.degraded, id: \.self) { reason in
                        Label(reason.message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppTheme.attentionColor)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Section("Now") {
                LabeledContent("Projects", value: "\(store.activeProjects.count)")
                LabeledContent("Sessions", value: "\(store.sessions.count)")
                LabeledContent("Waves", value: "\(store.waves.count)")
                LabeledContent("Repositories scanned", value: "\(store.repositories.count)")
                LabeledContent("Last refresh",
                               value: store.lastRefresh == .distantPast ? "—"
                                                                        : RelativeTime.ago(store.lastRefresh))
            }
        }
        .formStyle(.grouped)
        .padding()
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
