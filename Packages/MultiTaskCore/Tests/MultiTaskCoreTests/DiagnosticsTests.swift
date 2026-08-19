import Foundation
import Testing
@testable import MultiTaskCore

/// The log is written to be pasted into a conversation, so what it does *not*
/// contain matters as much as what it does.
@Suite("Diagnostics")
struct DiagnosticsTests {

    private func subject() -> Diagnostics {
        let log = Diagnostics()
        log.setEnabled(true)   // off by default under a test bundle
        return log
    }

    @Test("Records decisions in order, with their category")
    func recordsInOrder() {
        let log = subject()
        log.record(.projects, "accepted /a")
        log.record(.status, "b: working")

        let entries = log.recent
        #expect(entries.map(\.category) == [.projects, .status])
        #expect(entries.map(\.message) == ["accepted /a", "b: working"])
    }

    @Test("Keeps the most recent entries and drops the oldest")
    func ringBuffer() {
        let log = subject()
        for index in 0..<(Diagnostics.capacity + 50) { log.record(.detection, "entry \(index)") }

        let entries = log.recent
        #expect(entries.count == Diagnostics.capacity)
        // The newest survive; a buffer that dropped these would report on
        // whatever happened at launch instead of what just went wrong.
        #expect(entries.last?.message == "entry \(Diagnostics.capacity + 49)")
        #expect(entries.first?.message == "entry 50")
    }

    @Test("The home directory does not appear in the export")
    func redactsHome() {
        let log = subject()
        let home = FileSupport.homeDirectory.path
        log.record(.projects, "accepted \(home)/projects/app")

        let text = log.export()
        #expect(!text.contains(home))
        #expect(text.contains("~/projects/app"))
    }

    @Test("Filtering to one area drops the rest")
    func filtersByCategory() {
        let log = subject()
        log.record(.projects, "project line")
        log.record(.terminal, "terminal line")

        let text = log.export(only: .terminal)
        #expect(text.contains("terminal line"))
        #expect(!text.contains("project line"))
    }

    @Test("The header carries the context that would otherwise need a second round trip")
    func headerIsIncluded() {
        let log = subject()
        let text = log.export(header: ["hooks: 7 missing", "sessions: 5"])
        #expect(text.contains("# hooks: 7 missing"))
        #expect(text.contains("# sessions: 5"))
    }

    @Test("An empty log says so rather than looking broken")
    func emptyIsExplained() {
        #expect(subject().export().contains("nothing recorded yet"))
    }

    @Test("Recording is off under a test bundle unless asked for")
    func quietInTests() {
        // Otherwise a suite fills the buffer with reports about its own
        // fixtures and the one entry anyone wanted has scrolled away.
        let log = Diagnostics()
        log.record(.status, "should not be kept")
        #expect(log.recent.isEmpty)
    }
}

/// The log has to survive a restart, because that is when it gets read.
@Suite("Diagnostics on disk")
struct DiagnosticsFileTests {

    /// Each test gets its own file. Sharing one meant three of these read each
    /// other's entries and failed in whichever order the runner chose — which is
    /// how this surfaced, on Windows, where the ordering differed.
    private func subject(_ dir: TempDir) -> Diagnostics {
        let log = Diagnostics(file: dir.url.appendingPathComponent("diagnostics.log"))
        log.setEnabled(true)
        return log
    }

    @Test("Entries are written to the file as they happen")
    func writesThrough() throws {
        let dir = TempDir()
        let log = subject(dir)
        log.record(.projects, "accepted /somewhere/app")

        let text = try String(contentsOf: dir.url.appendingPathComponent("diagnostics.log"),
                              encoding: .utf8)
        #expect(text.contains("accepted /somewhere/app"))
        #expect(text.contains("projects"))
    }

    @Test("The home directory is redacted on disk too, not only in the export")
    func redactsOnDisk() throws {
        let dir = TempDir()
        let log = subject(dir)
        let home = FileSupport.homeDirectory.path
        log.record(.terminal, "chain under \(home)/dev")

        let text = try String(contentsOf: dir.url.appendingPathComponent("diagnostics.log"),
                              encoding: .utf8)
        // A file meant to be sent should not carry an account name on every line.
        #expect(!text.contains(home))
        #expect(text.contains("~/dev"))
    }

    @Test("The export points at the file, since the buffer is only the recent part")
    func exportNamesTheFile() {
        let dir = TempDir()
        let log = subject(dir)
        // Redacted, like everything else — this line is for a person to read,
        // and `~/.multitaskmanager/…` is more use to them than an absolute path
        // with their account name in it.
        #expect(log.export().contains(Diagnostics.redacting(dir.path("diagnostics.log"))))
    }

    @Test("A separate instance keeps its own file")
    func instancesAreIndependent() throws {
        let a = TempDir(), b = TempDir()
        subject(a).record(.status, "only in a")
        subject(b).record(.status, "only in b")

        let textA = try String(contentsOf: a.url.appendingPathComponent("diagnostics.log"),
                               encoding: .utf8)
        #expect(textA.contains("only in a"))
        #expect(!textA.contains("only in b"))
    }
}
