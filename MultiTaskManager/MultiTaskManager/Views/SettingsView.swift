import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            DetectorSettings()
                .tabItem { Label("Detection", systemImage: "antenna.radiowaves.left.and.right") }
            ThresholdSettings()
                .tabItem { Label("Status", systemImage: "timer") }
            DevFolderSettings()
                .tabItem { Label("Dev Folders", systemImage: "folder") }
            AppSettings()
                .tabItem { Label("Apps", systemImage: "app.badge") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 460, height: 360)
    }
}

private struct DetectorSettings: View {
    @ObservedObject private var prefs = Preferences.shared

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
