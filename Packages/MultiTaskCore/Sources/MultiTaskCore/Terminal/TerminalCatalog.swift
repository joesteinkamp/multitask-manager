import Foundation

/// A terminal emulator this app knows how to bring to the front.
///
/// Data, not code — which is the point. Supporting another terminal is one entry
/// in `TerminalCatalog.all`, not a new branch in a `switch` somewhere.
public struct TerminalApp: Sendable, Hashable, Identifiable {
    /// Stable slug, used in preferences and logs.
    public var id: String
    /// What to call it in the interface.
    public var name: String
    /// Bundle identifiers, newest first. Several because terminals ship stable
    /// and preview builds under different ids, and a user may run either.
    public var bundleIds: [String]
    /// Executable *file names* seen in a process tree, lowercased.
    ///
    /// Needed separately from the bundle id: walking up from an agent process
    /// yields executable paths, and a bundled app's executable is rarely named
    /// after its bundle id.
    public var executableNames: [String]

    /// How precisely this terminal can be focused.
    public enum Precision: String, Sendable, Codable {
        /// The app can be brought forward, but not a particular tab.
        case application
        /// A specific tab can be raised, given its tty. Not implemented yet —
        /// see `TerminalFocus` — but recorded so the catalog already carries the
        /// distinction when it is.
        case tab
    }
    public var precision: Precision

    public init(id: String, name: String, bundleIds: [String],
                executableNames: [String], precision: Precision = .application) {
        self.id = id
        self.name = name
        self.bundleIds = bundleIds
        self.executableNames = executableNames
        self.precision = precision
    }
}

/// Every terminal this app can focus.
///
/// **To add one, add an entry.** Nothing else needs to change: matching, the
/// process walk, and the app's activation all read from this list. `CatalogTests`
/// checks the shape of every entry, so a malformed addition fails rather than
/// silently never matching.
public enum TerminalCatalog {
    public static let all: [TerminalApp] = [
        TerminalApp(id: "warp", name: "Warp",
                    bundleIds: ["dev.warp.Warp-Stable", "dev.warp.Warp-Preview"],
                    executableNames: ["warp", "stable", "warp-preview"]),
        TerminalApp(id: "terminal", name: "Terminal",
                    bundleIds: ["com.apple.Terminal"],
                    executableNames: ["terminal"],
                    precision: .tab),
        TerminalApp(id: "iterm2", name: "iTerm2",
                    bundleIds: ["com.googlecode.iterm2"],
                    executableNames: ["iterm2", "iterm"],
                    precision: .tab),
        TerminalApp(id: "ghostty", name: "Ghostty",
                    bundleIds: ["com.mitchellh.ghostty"],
                    executableNames: ["ghostty"]),
        TerminalApp(id: "kitty", name: "kitty",
                    bundleIds: ["net.kovidgoyal.kitty"],
                    executableNames: ["kitty"]),
        TerminalApp(id: "wezterm", name: "WezTerm",
                    bundleIds: ["com.github.wez.wezterm"],
                    executableNames: ["wezterm-gui", "wezterm"]),
        TerminalApp(id: "alacritty", name: "Alacritty",
                    bundleIds: ["org.alacritty"],
                    executableNames: ["alacritty"]),
        TerminalApp(id: "hyper", name: "Hyper",
                    bundleIds: ["co.zeit.hyper"],
                    executableNames: ["hyper"]),
        TerminalApp(id: "tabby", name: "Tabby",
                    bundleIds: ["org.tabby"],
                    executableNames: ["tabby"]),
        // Editors with integrated terminals. Focusing these lands you in the
        // editor that owns the session, which is where the work is.
        TerminalApp(id: "vscode", name: "VS Code",
                    bundleIds: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"],
                    executableNames: ["code helper", "electron", "code"]),
        TerminalApp(id: "cursor", name: "Cursor",
                    bundleIds: ["com.todesktop.230313mzl4w4u92"],
                    executableNames: ["cursor helper", "cursor"])
    ]

    public static func terminal(forBundleId bundleId: String) -> TerminalApp? {
        let needle = bundleId.lowercased()
        return all.first { $0.bundleIds.contains { $0.lowercased() == needle } }
    }

    /// Matches an executable path from a process listing.
    ///
    /// On the *file name*, not the whole path, and case-insensitively: the same
    /// terminal lives in `/Applications`, `~/Applications`, and a Homebrew cask
    /// path depending on how it was installed.
    public static func terminal(forExecutablePath path: String) -> TerminalApp? {
        let name = FileSupport.lastComponent(of: path).lowercased()
        guard !name.isEmpty else { return nil }
        return all.first { $0.executableNames.contains(name) }
    }
}
