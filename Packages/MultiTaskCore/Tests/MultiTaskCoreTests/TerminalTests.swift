import Foundation
import Testing
@testable import MultiTaskCore

@Suite("Terminal catalog")
struct TerminalCatalogTests {

    /// Guards the shape of every entry, so adding a terminal cannot half-work.
    @Test("Every entry is complete and unambiguous")
    func entriesAreWellFormed() {
        var seenIds: Set<String> = []
        var seenBundles: Set<String> = []
        var seenExecutables: Set<String> = []

        for terminal in TerminalCatalog.all {
            #expect(!terminal.id.isEmpty)
            #expect(!terminal.name.isEmpty)
            #expect(!terminal.bundleIds.isEmpty, "\(terminal.id) has no bundle id")
            #expect(!terminal.executableNames.isEmpty, "\(terminal.id) has no executable name")

            #expect(seenIds.insert(terminal.id).inserted, "duplicate id \(terminal.id)")
            for bundle in terminal.bundleIds {
                #expect(bundle.contains("."), "\(bundle) is not a bundle id")
                #expect(seenBundles.insert(bundle.lowercased()).inserted,
                        "\(bundle) is claimed by two terminals")
            }
            for executable in terminal.executableNames {
                // Lowercased in the table, because matching lowercases the needle
                // and a capital here would simply never match.
                #expect(executable == executable.lowercased(),
                        "\(executable) must be lowercase to ever match")
                #expect(seenExecutables.insert(executable).inserted,
                        "\(executable) is claimed by two terminals")
            }
        }
    }

    @Test("The terminals actually used are present")
    func coversTheCommonOnes() {
        let ids = Set(TerminalCatalog.all.map(\.id))
        for expected in ["warp", "terminal", "iterm2", "ghostty", "kitty", "wezterm", "alacritty"] {
            #expect(ids.contains(expected), "missing \(expected)")
        }
    }

    @Test("Bundle ids match however they are cased")
    func bundleMatching() {
        #expect(TerminalCatalog.terminal(forBundleId: "dev.warp.Warp-Stable")?.id == "warp")
        #expect(TerminalCatalog.terminal(forBundleId: "DEV.WARP.WARP-STABLE")?.id == "warp")
        #expect(TerminalCatalog.terminal(forBundleId: "com.apple.Terminal")?.id == "terminal")
        #expect(TerminalCatalog.terminal(forBundleId: "com.apple.Finder") == nil)
    }

    @Test("Executables match on the file name, wherever the app was installed")
    func executableMatching() {
        // The same terminal, three plausible install locations.
        #expect(TerminalCatalog.terminal(forExecutablePath: "/Applications/Ghostty.app/Contents/MacOS/ghostty")?.id == "ghostty")
        #expect(TerminalCatalog.terminal(forExecutablePath: "/Users/joe/Applications/Ghostty.app/Contents/MacOS/Ghostty")?.id == "ghostty")
        #expect(TerminalCatalog.terminal(forExecutablePath: "/opt/homebrew/bin/ghostty")?.id == "ghostty")

        #expect(TerminalCatalog.terminal(forExecutablePath: "/bin/zsh") == nil)
        #expect(TerminalCatalog.terminal(forExecutablePath: "") == nil)
    }
}

@Suite("Finding the terminal a session runs in")
struct TerminalResolverTests {

    /// A plausible tree: Warp → zsh → claude, plus unrelated processes.
    private func tree(agentCwd: String = "/Users/joe/projects/app") -> [RunningProcess] {
        [
            RunningProcess(pid: 1, parentPid: 0, executablePath: "/sbin/launchd"),
            RunningProcess(pid: 100, parentPid: 1,
                           executablePath: "/Applications/Warp.app/Contents/MacOS/stable"),
            RunningProcess(pid: 200, parentPid: 100, executablePath: "/bin/zsh",
                           workingDirectory: agentCwd),
            RunningProcess(pid: 300, parentPid: 200, executablePath: "/opt/homebrew/bin/claude",
                           workingDirectory: agentCwd),
            RunningProcess(pid: 400, parentPid: 1, executablePath: "/Applications/Safari.app/Contents/MacOS/Safari"),
            RunningProcess(pid: 500, parentPid: 1, executablePath: "/bin/zsh",
                           workingDirectory: "/Users/joe/elsewhere")
        ]
    }

    @Test("Walks up from the agent to the terminal hosting it")
    func findsTheTerminal() throws {
        let found = try #require(TerminalResolver.terminal(forProjectPath: "/Users/joe/projects/app",
                                                           among: tree()))
        #expect(found.0.id == "warp")
        #expect(found.1.pid == 100)
    }

    @Test("Prefers the agent over a plain shell in the same directory")
    func prefersTheAgent() throws {
        let agent = try #require(TerminalResolver.agentProcess(
            forProjectPath: "/Users/joe/projects/app", among: tree()))
        // Both zsh (200) and claude (300) sit in that directory; the agent is the
        // one that says which session this is.
        #expect(agent.pid == 300)
    }

    @Test("A shell alone still resolves — the session may be between tool calls")
    func fallsBackToAnyProcessThere() throws {
        let processes = tree().filter { $0.pid != 300 }
        let found = try #require(TerminalResolver.terminal(forProjectPath: "/Users/joe/projects/app",
                                                           among: processes))
        #expect(found.0.id == "warp")
    }

    @Test("Nothing running in the project resolves to nothing, rather than a guess")
    func noProcessThere() {
        #expect(TerminalResolver.terminal(forProjectPath: "/Users/joe/nowhere", among: tree()) == nil)
    }

    @Test("An agent under no recognised terminal resolves to nothing")
    func unrecognisedTerminal() {
        let processes = [
            RunningProcess(pid: 1, parentPid: 0, executablePath: "/sbin/launchd"),
            RunningProcess(pid: 100, parentPid: 1, executablePath: "/Applications/Unknown.app/Contents/MacOS/unknown"),
            RunningProcess(pid: 200, parentPid: 100, executablePath: "/opt/homebrew/bin/claude",
                           workingDirectory: "/p")
        ]
        // Better to fall back to revealing the folder than to activate whatever
        // happened to be the parent.
        #expect(TerminalResolver.terminal(forProjectPath: "/p", among: processes) == nil)
    }

    @Test("A cycle in reported parentage terminates instead of hanging")
    func survivesACycle() {
        // A snapshot taken while processes exit can report parentage that loops.
        // This runs inside a click handler, so looping is not survivable.
        let processes = [
            RunningProcess(pid: 10, parentPid: 20, executablePath: "/bin/a", workingDirectory: "/p"),
            RunningProcess(pid: 20, parentPid: 10, executablePath: "/bin/b")
        ]
        #expect(TerminalResolver.terminal(forProjectPath: "/p", among: processes) == nil)
    }

    @Test("Paths are compared the way the filesystem would")
    func pathComparison() throws {
        // A trailing slash from one source and not another must not lose the match.
        let found = try #require(TerminalResolver.terminal(forProjectPath: "/Users/joe/projects/app/",
                                                           among: tree()))
        #expect(found.0.id == "warp")
    }
}
