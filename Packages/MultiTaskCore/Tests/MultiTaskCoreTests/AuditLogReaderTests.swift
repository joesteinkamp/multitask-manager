import Foundation
import Testing
@testable import MultiTaskCore

@Suite("AuditLogReader — parsing")
struct AuditLogParsingTests {

    @Test("Indexes a session by its harness id, with tool and directory")
    func indexesBySession() throws {
        let dir = TempDir()
        dir.write(Fixtures.auditClaudePair + "\n", to: "tool-calls.jsonl")

        let index = AuditLogReader(path: dir.path("tool-calls.jsonl")).refresh(now: Fixtures.auditNow)
        let activity = try #require(index.bySession["f9f9b53d-1831-4798-966e-45eddd79dd68"])

        #expect(activity.eventCount == 2)
        #expect(activity.lastToolName == "Bash")
        #expect(activity.cwd == "/home/user/projects/app")
        #expect(activity.tool == "claude")
        #expect(activity.hasEnded == false)
    }

    @Test("SessionEnd makes 'finished' a fact, and carries the reason")
    func sessionEndIsAFact() throws {
        let dir = TempDir()
        dir.write(Fixtures.auditClaudePair + "\n" + Fixtures.auditSessionEnd + "\n", to: "tool-calls.jsonl")

        let index = AuditLogReader(path: dir.path("tool-calls.jsonl")).refresh(now: Fixtures.auditNow)
        let activity = try #require(index.bySession["f9f9b53d-1831-4798-966e-45eddd79dd68"])

        #expect(activity.hasEnded)
        #expect(activity.endReason == "prompt_input_exit")
    }

    @Test("A record after SessionEnd clears the ended flag — the session resumed")
    func resumeClearsEnded() throws {
        let dir = TempDir()
        dir.write(Fixtures.auditSessionEnd + "\n" + Fixtures.auditResumed + "\n", to: "tool-calls.jsonl")

        let index = AuditLogReader(path: dir.path("tool-calls.jsonl")).refresh(now: Fixtures.auditNow)
        let activity = try #require(index.bySession["f9f9b53d-1831-4798-966e-45eddd79dd68"])

        #expect(activity.hasEnded == false)
        #expect(activity.lastToolName == "Read")
    }

    @Test("Counts lower-camel and Cursor-specific event names as activity")
    func toleratesEventNameVariants() throws {
        let dir = TempDir()
        dir.write(Fixtures.auditMixedCasing + "\n", to: "tool-calls.jsonl")

        let index = AuditLogReader(path: dir.path("tool-calls.jsonl")).refresh(now: Fixtures.auditNow)

        #expect(index.malformedLines == 0)
        #expect(index.bySession.count == 3)
        #expect(index.bySession["aaaaaaaa-0000-0000-0000-000000000001"]?.lastToolName == "Read")
        // Cursor's `beforeShellExecution` is still a tool call.
        #expect(index.bySession["bbbbbbbb-0000-0000-0000-000000000002"]?.lastToolName == "Shell")
    }

    @Test("Normalises every known event name regardless of casing")
    func eventNormalisation() {
        #expect(AuditEvent(rawValue: "PreToolUse") == .preToolUse)
        #expect(AuditEvent(rawValue: "preToolUse") == .preToolUse)
        #expect(AuditEvent(rawValue: "SessionEnd") == .sessionEnd)
        #expect(AuditEvent(rawValue: "beforeShellExecution") == .beforeShellExecution)
        #expect(AuditEvent(rawValue: "afterFileEdit") == .afterFileEdit)
        // An event the harness adds later still counts as proof of life.
        #expect(AuditEvent(rawValue: "SomethingNew") == .other("SomethingNew"))
        #expect(AuditEvent(rawValue: nil) == .other(""))
    }

    @Test("Builds a directory index for sessions that can't be joined by id")
    func cwdFallbackIndex() throws {
        let dir = TempDir()
        dir.write(Fixtures.auditClaudePair + "\n", to: "tool-calls.jsonl")

        let index = AuditLogReader(path: dir.path("tool-calls.jsonl")).refresh(now: Fixtures.auditNow)

        #expect(index.activity(sessionId: "unknown-id", projectPath: "/home/user/projects/app") != nil)
        #expect(index.activity(sessionId: nil, projectPath: "/nowhere") == nil)
    }

    @Test("A record with no session id or no timestamp is counted, not crashed on")
    func recordsMissingKeyFields() {
        let dir = TempDir()
        dir.write("""
        {"ts":"2026-07-20T13:48:00Z","tool":"claude","event":"PreToolUse"}
        {"tool":"claude","session":"aaaa","event":"PreToolUse"}
        {"ts":"not a date","tool":"claude","session":"bbbb","event":"PreToolUse"}

        """, to: "tool-calls.jsonl")

        let index = AuditLogReader(path: dir.path("tool-calls.jsonl")).refresh(now: Fixtures.auditNow)

        #expect(index.malformedLines == 3)
        #expect(index.bySession.isEmpty)
    }
}

@Suite("AuditLogReader — corruption tolerance")
struct AuditCorruptionTests {

    @Test("An interleaved line is skipped and counted, and the pass continues")
    func interleavedLine() throws {
        let dir = TempDir()
        // The interleaved fixture is one physical line holding two half-records,
        // followed by a clean one.
        dir.write(Fixtures.auditInterleaved + "\n" + Fixtures.auditClaudePair + "\n", to: "tool-calls.jsonl")

        let reader = AuditLogReader(path: dir.path("tool-calls.jsonl"))
        let index = reader.refresh(now: Fixtures.auditNow)

        #expect(index.malformedLines == 1)
        // The good records after the corruption were still indexed.
        #expect(index.bySession["f9f9b53d-1831-4798-966e-45eddd79dd68"]?.eventCount == 2)
    }

    @Test("Malformed lines accumulate across passes as a health metric")
    func malformedCountAccumulates() {
        let dir = TempDir()
        dir.write("garbage\n", to: "tool-calls.jsonl")
        let reader = AuditLogReader(path: dir.path("tool-calls.jsonl"))
        _ = reader.refresh(now: Fixtures.auditNow)
        #expect(reader.malformedLineCount == 1)

        dir.append("more garbage\n", to: "tool-calls.jsonl")
        _ = reader.refresh(now: Fixtures.auditNow)
        #expect(reader.malformedLineCount == 2)
    }

    @Test("A missing log degrades rather than failing, and recovers when it appears")
    func missingLogDegrades() throws {
        let dir = TempDir()
        let reader = AuditLogReader(path: dir.path("tool-calls.jsonl"))

        let degraded = reader.refresh(now: Fixtures.auditNow)
        #expect(degraded.degraded != nil)
        #expect(degraded.bySession.isEmpty)

        dir.write(Fixtures.auditClaudePair + "\n", to: "tool-calls.jsonl")
        let recovered = reader.refresh(now: Fixtures.auditNow)
        #expect(recovered.degraded == nil)
        #expect(recovered.bySession.count == 1)
    }
}

@Suite("AuditLogReader — incremental tail")
struct AuditTailTests {

    @Test("A second pass reads only what was appended since the first")
    func incrementalOffsets() throws {
        let dir = TempDir()
        dir.write(Fixtures.auditClaudePair + "\n", to: "tool-calls.jsonl")
        let reader = AuditLogReader(path: dir.path("tool-calls.jsonl"))

        let first = reader.refresh(now: Fixtures.auditNow)
        #expect(first.recordsRead == 2)

        // Nothing appended: the pass is a no-op rather than a re-parse.
        let unchanged = reader.refresh(now: Fixtures.auditNow)
        #expect(unchanged.recordsRead == 2)

        dir.append(Fixtures.auditSessionEnd + "\n", to: "tool-calls.jsonl")
        let third = reader.refresh(now: Fixtures.auditNow)
        #expect(third.recordsRead == 3)
        #expect(third.bySession["f9f9b53d-1831-4798-966e-45eddd79dd68"]?.hasEnded == true)
    }

    @Test("A record split across two passes is buffered, not counted as corrupt")
    func partialLineBuffering() throws {
        let dir = TempDir()
        let record = Fixtures.auditSessionEnd
        let split = record.index(record.startIndex, offsetBy: 40)

        dir.write(String(record[..<split]), to: "tool-calls.jsonl")
        let reader = AuditLogReader(path: dir.path("tool-calls.jsonl"))
        let partial = reader.refresh(now: Fixtures.auditNow)
        #expect(partial.malformedLines == 0)
        #expect(partial.bySession.isEmpty)

        dir.append(String(record[split...]) + "\n", to: "tool-calls.jsonl")
        let complete = reader.refresh(now: Fixtures.auditNow)
        #expect(complete.malformedLines == 0)
        #expect(complete.bySession["f9f9b53d-1831-4798-966e-45eddd79dd68"]?.hasEnded == true)
    }

    @Test("A multi-byte character split across two passes survives")
    func multiByteSplit() throws {
        let dir = TempDir()
        let record = """
        {"ts":"2026-08-15T10:00:00Z","tool":"claude","session":"utf8","cwd":"/home/user/naïve—project","event":"PreToolUse","tool_name":"Read"}

        """
        let bytes = Array(record.utf8)
        // Cut inside the multi-byte em dash.
        let cut = bytes.firstIndex(of: 0xE2) ?? (bytes.count / 2)

        let path = dir.path("tool-calls.jsonl")
        FileManager.default.createFile(atPath: path, contents: Data(bytes[..<(cut + 1)]))
        let reader = AuditLogReader(path: path)
        _ = reader.refresh(now: Fixtures.auditNow)

        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(bytes[(cut + 1)...]))
        try handle.close()

        let index = reader.refresh(now: Fixtures.auditNow)
        #expect(index.malformedLines == 0)
        #expect(index.bySession["utf8"]?.cwd == "/home/user/naïve—project")
    }

    @Test("Truncation is treated as rotation and re-read from the top")
    func truncationResetsOffset() throws {
        let dir = TempDir()
        dir.write(Fixtures.auditClaudePair + "\n", to: "tool-calls.jsonl")
        let reader = AuditLogReader(path: dir.path("tool-calls.jsonl"))
        _ = reader.refresh(now: Fixtures.auditNow)

        // The rotated-in file is shorter than the offset we were holding.
        dir.write(Fixtures.auditSessionEnd + "\n", to: "tool-calls.jsonl")
        let index = reader.refresh(now: Fixtures.auditNow)

        #expect(index.bySession["f9f9b53d-1831-4798-966e-45eddd79dd68"]?.hasEnded == true)
        #expect(index.malformedLines == 0)
    }

    @Test("The first pass reads only the tail of a large log")
    func firstPassSeeksToTail() throws {
        let dir = TempDir()
        let path = dir.path("tool-calls.jsonl")

        // A record shape that is cheap to repeat, padded past the 2 MB window.
        var backlog = ""
        let filler = #"{"ts":"2026-08-15T09:00:00Z","tool":"claude","session":"old","cwd":"/old","event":"PreToolUse","tool_name":"Bash","pad":"\#(String(repeating: "x", count: 400))"}"# + "\n"
        while backlog.utf8.count < 3 * 1024 * 1024 { backlog += filler }
        backlog += Fixtures.auditClaudePair + "\n"
        try backlog.write(toFile: path, atomically: true, encoding: .utf8)

        let index = AuditLogReader(path: path).refresh(now: Fixtures.auditNow)

        // The recent session is present; the months of backlog ahead of the window
        // were skipped rather than parsed.
        #expect(index.bySession["f9f9b53d-1831-4798-966e-45eddd79dd68"] != nil)
        #expect(index.recordsRead < 6_000)
        let old = try #require(index.bySession["old"])
        #expect(old.eventCount < 6_000)
    }

    @Test("Sessions untouched for longer than the retention window are pruned")
    func retentionPruning() throws {
        let dir = TempDir()
        dir.write(Fixtures.auditClaudePair + "\n", to: "tool-calls.jsonl")
        let reader = AuditLogReader(path: dir.path("tool-calls.jsonl"))

        // The fixture's records are from June 2026; ask for the index well after.
        let index = reader.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(index.bySession.isEmpty)
        #expect(index.byCWD.isEmpty)
    }
}

/// Attributing one agent's work to another is worse than attributing none.
@Suite("The directory fallback does not cross agents")
struct AuditAttributionTests {
    let now = Fixtures.auditNow

    private func index() -> AuditIndex {
        var index = AuditIndex()
        // Codex is working in this directory. Claude Code is not.
        index.byCWD["/dev/app"] = AuditActivity(lastEventAt: now, tool: "codex")
        index.bySession["codex-1"] = AuditActivity(lastEventAt: now, tool: "codex")
        return index
    }

    @Test("A Claude Code session does not inherit Codex's activity")
    func doesNotCrossAgents() {
        // The bug this replaces: a project showed "Claude Code active" while
        // three Codex sessions did the work and no Claude Code was running.
        #expect(index().activity(sessionId: nil, projectPath: "/dev/app", tool: "claude") == nil)
    }

    @Test("The same agent still matches by directory")
    func sameAgentStillMatches() {
        #expect(index().activity(sessionId: nil, projectPath: "/dev/app", tool: "codex") != nil)
    }

    @Test("An exact session id wins regardless of tool")
    func sessionIdIsAuthoritative() {
        // The id is the precise join; the tool check exists only to discipline
        // the coarse one.
        #expect(index().activity(sessionId: "codex-1", projectPath: nil, tool: "claude") != nil)
    }

    @Test("With no tool recorded on either side, the old coarse behaviour stands")
    func degradesGracefully() {
        var index = AuditIndex()
        index.byCWD["/dev/app"] = AuditActivity(lastEventAt: now)
        // Better than nothing when the harness did not record which agent it was.
        #expect(index.activity(sessionId: nil, projectPath: "/dev/app", tool: "claude") != nil)
    }
}
