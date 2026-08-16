import Foundation
import Testing
@testable import MultiTaskCore

/// Opt-in checks against the real harness data on the developer's own machine.
///
/// Fixtures prove the parsers handle the shapes we captured. These prove they
/// handle the shapes we *didn't* — a 35 MB log with two months of drift in it,
/// written by four different harnesses across many versions. Run with:
///
/// ```
/// MTM_REAL_DATA=1 swift test
/// ```
///
/// Skipped by default so CI and a fresh checkout stay green without the data.
@Suite("Real harness data", .enabled(if: ProcessInfo.processInfo.environment["MTM_REAL_DATA"] == "1"))
struct RealDataSmokeTests {

    static let auditPath = Configuration.defaultAuditLogPath

    @Test("Parses the machine's own audit log without choking")
    func realAuditLog() throws {
        try #require(FileManager.default.fileExists(atPath: Self.auditPath),
                     "no audit log at \(Self.auditPath)")

        let reader = AuditLogReader(path: Self.auditPath)
        let index = reader.refresh()

        #expect(index.degraded == nil)
        #expect(index.recordsRead > 0)
        // The first pass reads the last 2 MB, so the whole 35 MB backlog must not
        // have been parsed.
        #expect(index.recordsRead < 20_000)

        // Corruption should be rare. A high rate means the tail logic is wrong, not
        // that the log is broken.
        let corruptionRate = Double(index.malformedLines) / Double(max(1, index.recordsRead + index.malformedLines))
        #expect(corruptionRate < 0.01, "malformed line rate \(corruptionRate)")

        // Every indexed session must carry a usable timestamp.
        #expect(index.bySession.values.allSatisfy { $0.lastEventAt > Date(timeIntervalSince1970: 1_700_000_000) })
    }

    @Test("The audit log's session ids line up with real Claude Code transcripts")
    func sessionIdJoinHolds() throws {
        try #require(FileManager.default.fileExists(atPath: Self.auditPath))
        let projectsRoot = FileSupport.homeDirectory
            .appendingPathComponent(".claude/projects", isDirectory: true)
        try #require(FileSupport.isDirectory(projectsRoot))

        // Read the whole log, not just the tail, so the comparison is meaningful.
        var logSessions = Set<String>()
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: Self.auditPath))
        defer { try? handle.close() }
        let data = (try? handle.readToEnd()) ?? Data()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let record = try? JSONDecoder().decode(AuditLogReader.Record.self, from: Data(line)),
                  let session = record.session, record.tool == "claude" else { continue }
            logSessions.insert(session)
        }

        var transcriptIds = Set<String>()
        for projectDir in FileSupport.contents(of: projectsRoot) where FileSupport.isDirectory(projectDir) {
            for file in FileSupport.contents(of: projectDir) where file.pathExtension == "jsonl" {
                transcriptIds.insert(file.deletingPathExtension().lastPathComponent)
            }
        }

        try #require(!transcriptIds.isEmpty)
        let overlap = Double(logSessions.intersection(transcriptIds).count) / Double(transcriptIds.count)

        // This is the assumption the whole precise-join design rests on. If it ever
        // stops holding, the cwd fallback still works but this test should say so
        // loudly rather than letting the precision quietly disappear.
        #expect(overlap > 0.8, "only \(Int(overlap * 100))% of transcripts join by session id")
    }

    @Test("Detects the machine's live Claude Code and Codex sessions")
    func realDetectors() async {
        let claude = await ClaudeCodeDetector().detect()
        let codex = await CodexDetector().detect()

        for session in claude.sessions + codex.sessions {
            #expect(!session.id.isEmpty)
            #expect(!session.projectName.isEmpty)
            #expect(session.transcriptPath != nil)
            // Every detected session must expose a join key, or the audit log's
            // precision is wasted on it.
            #expect(session.harnessSessionId != nil, "no session id for \(session.id)")
        }
    }

    @Test("Reads the machine's own delegate roster and routing table")
    func realRoster() throws {
        let roster = RosterReader().read()
        try #require(!roster.delegates.isEmpty, "no delegates found in ~/.ai/clis")
        #expect(roster.routingUpdatedAt != nil)
        #expect(!roster.routingSections.isEmpty)
        // Every section should name at least one CLI or say plainly that it can't.
        #expect(roster.routingSections.allSatisfy { !$0.rows.isEmpty })
    }

    @Test("Reads this repository's own worktree state")
    func realWorktrees() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MultiTaskCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // MultiTaskCore
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // repo root
            .path

        let state = try #require(WorktreeReader().read(repository: repo))
        #expect(state.worktrees.contains { $0.isMain })
        #expect(state.integrationBranch != nil)
    }
}
