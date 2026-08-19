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
