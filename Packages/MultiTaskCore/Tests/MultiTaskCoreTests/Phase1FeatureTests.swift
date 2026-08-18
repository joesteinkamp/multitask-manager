import Foundation
import Testing
@testable import MultiTaskCore

@Suite("CodexDetector — session ids")
struct CodexDetectorTests {

    @Test("Extracts the session uuid trailing a rollout filename")
    func extractsSessionId() {
        let name = "rollout-2026-07-25T19-45-09-019f9acf-6091-7663-b483-4b0fec2f778b.jsonl"
        #expect(CodexDetector.sessionId(fromRolloutFilename: name) == "019f9acf-6091-7663-b483-4b0fec2f778b")
    }

    @Test("The dashes in the timestamp don't confuse the uuid match")
    func timestampDashesIgnored() {
        // Splitting on dashes alone would yield the wrong five groups; the match is
        // on the uuid's own 8-4-4-4-12 shape taken from the end.
        let name = "rollout-2026-01-02T03-04-05-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl"
        #expect(CodexDetector.sessionId(fromRolloutFilename: name) == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    }

    @Test("Returns nil for filenames that carry no uuid")
    func rejectsNonRollouts() {
        #expect(CodexDetector.sessionId(fromRolloutFilename: "history.jsonl") == nil)
        #expect(CodexDetector.sessionId(fromRolloutFilename: "rollout-2026-07-25.jsonl") == nil)
        #expect(CodexDetector.sessionId(fromRolloutFilename: "rollout-zzzzzzzz-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl") == nil)
    }

    @Test("Detects a rollout and reads its working directory")
    func detectsRollout() async throws {
        let dir = TempDir()
        let name = "rollout-2026-08-15T10-00-00-019f9acf-6091-7663-b483-4b0fec2f778b.jsonl"
        dir.write(Fixtures.codexTranscript, to: "sessions/2026/08/15/\(name)")

        let outcome = await CodexDetector(root: dir.url).detect()
        let session = try #require(outcome.sessions.first)

        #expect(session.projectPath == "/home/user/projects/other")
        #expect(session.projectName == "other")
        #expect(session.harnessSessionId == "019f9acf-6091-7663-b483-4b0fec2f778b")
    }

    @Test("A missing Codex directory degrades with a reason instead of going quiet")
    func missingRootDegrades() async {
        let outcome = await CodexDetector(root: URL(fileURLWithPath: "/nonexistent/codex")).detect()
        #expect(outcome.sessions.isEmpty)
        #expect(outcome.degraded?.message.contains("/nonexistent/codex") == true)
    }
}

@Suite("HookStatusReader — contract v2")
struct HookContractTests {

    private func read(_ json: String, file: String = "status.json") async -> DetectionOutcome {
        let dir = TempDir()
        dir.write(json, to: file)
        return await HookStatusReader(statusDirectory: dir.url).detect()
    }

    @Test("A v1 record with no schemaVersion parses exactly as it always did")
    func v1StillParses() async throws {
        let outcome = await read("""
        {"projectPath":"/home/user/projects/app","project":"app","status":"needsAttention","updatedAt":1755252000}
        """)
        let session = try #require(outcome.sessions.first)

        #expect(session.hookStatus == .needsAttention)
        #expect(session.projectPath == "/home/user/projects/app")
        #expect(session.waiting == nil)
        #expect(session.harnessSessionId == nil)
        #expect(session.evidence == .hook)
    }

    @Test("A v2 record carries the session id, the wait reason and the explanation")
    func v2FullRecord() async throws {
        let outcome = await read("""
        {"schemaVersion":2,"projectPath":"/home/user/projects/app","project":"app",
         "sessionId":"f9f9b53d-1831-4798-966e-45eddd79dd68","status":"needsAttention",
         "waiting":"approval","reason":"Bash(rm -rf build/)","updatedAt":1755252000}
        """)
        let session = try #require(outcome.sessions.first)

        #expect(session.harnessSessionId == "f9f9b53d-1831-4798-966e-45eddd79dd68")
        #expect(session.waiting == .approval)
        #expect(session.reason == "Bash(rm -rf build/)")
        // The id is keyed on the session, so two sessions in one project stay distinct.
        #expect(session.id == "hook:f9f9b53d-1831-4798-966e-45eddd79dd68")
    }

    @Test("An unrecognised waiting value is ignored rather than rejecting the record")
    func unknownWaitingValue() async throws {
        let outcome = await read("""
        {"schemaVersion":2,"projectPath":"/p","status":"needsAttention","waiting":"pondering"}
        """)
        let session = try #require(outcome.sessions.first)
        #expect(session.hookStatus == .needsAttention)
        #expect(session.waiting == nil)
    }

    @Test("Maps every accepted status spelling")
    func statusSpellings() {
        #expect(HookStatusReader.parseStatus("working") == .working)
        #expect(HookStatusReader.parseStatus("BUSY") == .working)
        #expect(HookStatusReader.parseStatus("needs_attention") == .needsAttention)
        #expect(HookStatusReader.parseStatus("error") == .needsAttention)
        #expect(HookStatusReader.parseStatus("idle") == .idle)
        #expect(HookStatusReader.parseStatus("nonsense") == nil)
    }

    @Test("An unreadable status file is counted as degraded, not silently skipped")
    func unreadableFileDegrades() async throws {
        let dir = TempDir()
        dir.write("{ not json", to: "broken.json")
        let outcome = await HookStatusReader(statusDirectory: dir.url).detect()

        #expect(outcome.sessions.isEmpty)
        #expect(outcome.degraded?.message.contains("unreadable") == true)
    }

    @Test("No status directory at all is normal, not degraded — hooks are opt-in")
    func absentDirectoryIsNormal() async {
        let outcome = await HookStatusReader(statusDirectory: URL(fileURLWithPath: "/nonexistent/status")).detect()
        #expect(outcome.sessions.isEmpty)
        #expect(outcome.degraded == nil)
    }
}

@Suite("WaveReader — orchestration waves")
struct WaveReaderTests {
    let now = Fixtures.auditNow

    private func makeWave(_ dir: TempDir, id: String = "app-audit-reader") {
        dir.write("# Wire up the audit reader\n\nRead the harness audit log and use it as the activity signal.\n",
                  to: "\(id)/TASK.md")
        dir.write("# State\n\n- decided: join on session id\n- remaining: rotation handling\n",
                  to: "\(id)/STATE.md")
        dir.write("full report\n", to: "\(id)/agents/codex.md")
        dir.write("full report\n", to: "\(id)/agents/agy.md")
        dir.write("diff\n", to: "\(id)/artifacts/diff.patch")
    }

    @Test("Reads title, progress, delegates and artifacts from one context dir")
    func readsWave() throws {
        let dir = TempDir()
        makeWave(dir)

        let waves = WaveReader(root: dir.url).read(now: now)
        let wave = try #require(waves.first)

        #expect(wave.id == "app-audit-reader")
        #expect(wave.title == "Read the harness audit log and use it as the activity signal.")
        #expect(wave.progress == "remaining: rotation handling")
        #expect(wave.delegates.map(\.name) == ["agy", "codex"])
        #expect(wave.artifacts == ["diff.patch"])
    }

    @Test("A delegate file written moments ago is active; a settled one is done")
    func delegateState() throws {
        let dir = TempDir()
        makeWave(dir)
        dir.setModificationDate(now.addingTimeInterval(-30), of: "app-audit-reader/agents/codex.md")
        dir.setModificationDate(now.addingTimeInterval(-3600), of: "app-audit-reader/agents/agy.md")

        let wave = try #require(WaveReader(root: dir.url).read(now: now).first)
        #expect(wave.delegates.first { $0.name == "codex" }?.state == .active)
        #expect(wave.delegates.first { $0.name == "agy" }?.state == .done)
        #expect(wave.activeCount == 1)
        #expect(wave.doneCount == 1)
    }

    /// Attribution only considers paths under the real home directory, so these
    /// build their fixtures from it rather than hard-coding someone else's.
    private static let home = NSHomeDirectory()
    /// A project path built the way the platform builds one.
    ///
    /// This used to interpolate "/" directly, which on Windows produced
    /// `C:\\Users\\runner/projects/app` — a path no OS would ever hand you, and
    /// one the matcher rightly failed to resolve. The test was manufacturing the
    /// failure it then reported.
    private static func project(_ name: String) -> String {
        URL(fileURLWithPath: home)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .path
    }

    @Test("Attributes a wave to the longest matching project name")
    func longestPrefixWins() {
        // "memory-os-verify" is ambiguous: it could be repo `memory` + slug
        // `os-verify`, or repo `memory-os` + slug `verify`. Longest match wins.
        let resolved = WaveReader.resolveProject(
            waveId: "memory-os-verify",
            taskText: nil,
            knownProjects: [Self.project("memory"), Self.project("memory-os")]
        )
        #expect(resolved == Self.project("memory-os"))
    }

    @Test("Falls back to a repo path named inside the brief")
    func fallsBackToTaskText() {
        let resolved = WaveReader.resolveProject(
            waveId: "unrecognisable-slug",
            taskText: "Work in \(Self.project("app")) and don't touch build/.",
            knownProjects: [Self.project("app")]
        )
        #expect(resolved == Self.project("app"))
    }

    /// The capability the fixed helper stopped exercising by accident.
    ///
    /// Fixing `project(_:)` to build native paths means the Windows shape is no
    /// longer covered incidentally on a Linux runner, so it is covered directly:
    /// a brief naming a backslash path must still resolve.
    @Test("A Windows path named in a brief resolves to its project")
    func resolvesWindowsPaths() {
        let repo = #"C:\Users\joe\projects\app"#
        let resolved = WaveReader.resolveProject(
            waveId: "unrecognisable-slug",
            taskText: #"Work in C:\Users\joe\projects\app and don't touch build/."#,
            knownProjects: [repo]
        )
        #expect(resolved == repo)
    }

    @Test("A path mentioned in the brief attributes to the deepest project, not an ancestor")
    func ancestorDoesNotClaimTheWave() {
        // The home directory becomes a tracked "project" as soon as a session runs
        // there. A substring match would let it claim every wave whose brief names
        // any path at all.
        let resolved = WaveReader.resolveProject(
            waveId: "memory-os-verify",
            taskText: "Grade the increment in \(Self.project("memory-os")).",
            knownProjects: [Self.home, Self.project("memory-os")]
        )
        #expect(resolved == Self.project("memory-os"))
    }

    @Test("The home directory never claims a wave, even as the only candidate")
    func homeIsNotAProject() {
        let resolved = WaveReader.resolveProject(
            waveId: "memory-os-verify",
            taskText: "Work under \(Self.home)/projects/memory-os.",
            knownProjects: [Self.home]
        )
        #expect(resolved == nil)
    }

    @Test("Leaves a wave unattributed rather than guessing")
    func noGuessing() {
        let resolved = WaveReader.resolveProject(
            waveId: "something-else",
            taskText: "no paths here",
            knownProjects: [Self.project("app")]
        )
        #expect(resolved == nil)
    }

    @Test("Trims markdown and punctuation off path tokens")
    func pathTokenTrimming() {
        let tokens = WaveReader.pathTokens(in: "See `/home/u/app`, and /home/u/other/ (also).")
        #expect(tokens.contains("/home/u/app"))
        #expect(tokens.contains("/home/u/other"))
    }

    /// Skipped where the filesystem will not backdate a timestamp — Windows.
    /// Staleness is read from mtimes, so there is nothing to exercise there, and
    /// reporting the test as skipped is more honest than failing it. Previously
    /// this failed the run, which is how it showed up as a Windows "bug".
    @Test("A wave untouched for more than a week collapses into past waves",
          .enabled(if: FilesystemCapabilities.canBackdate))
    func staleness() throws {
        let dir = TempDir()
        makeWave(dir)
        let old = now.addingTimeInterval(-30 * 24 * 3600)
        for file in ["TASK.md", "STATE.md", "agents/codex.md", "agents/agy.md"] {
            dir.setModificationDate(old, of: "app-audit-reader/\(file)")
        }
        dir.setModificationDate(old, of: "app-audit-reader")

        let wave = try #require(WaveReader(root: dir.url).read(now: now).first)
        #expect(wave.isStale)
    }

    @Test("Ignores a directory that isn't a context dir")
    func ignoresForeignDirectories() {
        let dir = TempDir()
        dir.write("hello", to: "not-a-wave/notes.txt")
        #expect(WaveReader(root: dir.url).read(now: now).isEmpty)
    }
}

@Suite("WorktreeReader — git plumbing")
struct WorktreeParsingTests {

    @Test("Parses the porcelain worktree list, marking the first as main")
    func parsesPorcelain() throws {
        let worktrees = WorktreeReader.parseWorktreeList(Fixtures.worktreePorcelain)

        #expect(worktrees.count == 3)
        #expect(worktrees[0].isMain)
        #expect(worktrees[0].branch == "main")
        #expect(worktrees[1].branch == "ai/claude")
        #expect(worktrees[1].agentName == "claude")
        #expect(worktrees[1].isMain == false)
        // A detached worktree has no branch, and so no agent.
        #expect(worktrees[2].branch == nil)
        #expect(worktrees[2].agentName == nil)
    }

    @Test("Reads ahead/behind out of rev-list's two counts")
    func parsesLeftRight() throws {
        let counts = try #require(WorktreeReader.parseLeftRightCount("3\t7\n"))
        #expect(counts.0 == 3)   // behind: on integration, not on the branch
        #expect(counts.1 == 7)   // ahead: on the branch, not on integration
        #expect(WorktreeReader.parseLeftRightCount(nil) == nil)
        #expect(WorktreeReader.parseLeftRightCount("garbage") == nil)
    }

    @Test("Finds converge conflict markers in the integration tree")
    func findsConflictMarkers() {
        let dir = TempDir()
        dir.write("", to: ".converge-conflict-ai-claude")
        dir.write("", to: ".converge-conflict-ai-codex")
        dir.write("", to: "README.md")

        let markers = WorktreeReader.conflictMarkers(in: dir.url.path)
        #expect(markers == [".converge-conflict-ai-claude", ".converge-conflict-ai-codex"])
    }

    @Test("A conflict marker makes the repository need attention on its own")
    func conflictIsAnAttentionCondition() {
        let clean = RepositoryState(path: "/p", name: "p", scannedAt: Date())
        let stalled = RepositoryState(path: "/p", name: "p",
                                      conflictMarkers: [".converge-conflict-ai-claude"],
                                      scannedAt: Date())
        #expect(clean.needsAttention == false)
        #expect(stalled.needsAttention)
    }
}

@Suite("RosterReader — delegates and routing")
struct RosterTests {

    @Test("Parses the bare CLI list, skipping comments and blanks")
    func parsesCLIs() {
        #expect(RosterReader.parseCLIs(Fixtures.clisFile) == ["codex", "agy", "claude", "agent"])
        #expect(RosterReader.parseCLIs("# comment\n\nclaude\n") == ["claude"])
    }

    @Test("Parses local models, with the throughput field optional")
    func parsesLocalModels() throws {
        let models = RosterReader.parseLocalModels(Fixtures.localModelsFile)
        #expect(models.count == 2)

        let first = try #require(models.first)
        #expect(first.name == "qwen-local")
        #expect(first.backend == "ollama")
        #expect(first.model == "qwen3:32b")
        #expect(first.tier == "mid")
        #expect(first.tokensPerSecond == 42.5)
        #expect(models[1].tokensPerSecond == nil)
    }

    @Test("Parses routing sections and their ranked CLIs")
    func parsesRouting() throws {
        let sections = RosterReader.parseRoutingSections(Fixtures.routingTable)
        #expect(sections.count == 2)

        let coding = try #require(sections.first { $0.title.contains("Hard coding") })
        #expect(coding.rows.count == 3)
        // A tie row names two CLIs in one cell.
        #expect(coding.rows[0].clis == ["claude", "codex"])
        // An unranked "—" row is excluded from the ranking.
        #expect(coding.rankedCLIs == ["claude", "codex", "agy"])
    }

    @Test("Pulls CLI names out of prose cells via their backticks")
    func extractsNamesFromProse() {
        #expect(RosterReader.extractCLINames(from: "no clear winner (`codex`/`claude`)") == ["codex", "claude"])
        #expect(RosterReader.extractCLINames(from: "no clear winner") == [])
    }

    @Test("Reads the table's own last-updated date and flags staleness")
    func staleness() throws {
        let dir = TempDir()
        dir.write(Fixtures.clisFile, to: "clis")
        dir.write(Fixtures.routingTable, to: "model-routing.md")

        let roster = RosterReader(directory: dir.url).read()
        let updated = try #require(roster.routingUpdatedAt)

        #expect(roster.delegates.map(\.name) == ["codex", "agy", "claude", "agent"])
        #expect(roster.isRoutingStale(now: updated.addingTimeInterval(30 * 24 * 3600)) == false)
        #expect(roster.isRoutingStale(now: updated.addingTimeInterval(90 * 24 * 3600)))
    }

    @Test("Looks up a ranking by task type, case-insensitively")
    func rankingLookup() {
        let dir = TempDir()
        dir.write(Fixtures.clisFile, to: "clis")
        dir.write(Fixtures.routingTable, to: "model-routing.md")

        let roster = RosterReader(directory: dir.url).read()
        #expect(roster.ranking(forTaskType: "hard coding") == ["claude", "codex", "agy"])
        #expect(roster.ranking(forTaskType: "nothing like this") == [])
    }

    @Test("A missing local-models file is silent; a missing routing table is noted")
    func missingFiles() {
        let dir = TempDir()
        dir.write(Fixtures.clisFile, to: "clis")

        let roster = RosterReader(directory: dir.url).read()
        #expect(roster.delegates.allSatisfy { !$0.isLocal })
        #expect(roster.notes.count == 1)
        #expect(roster.notes[0].contains("model-routing.md"))
    }
}

@Suite("SessionActivityReader — what a session did")
struct SessionActivityTests {
    /// A Claude Code transcript with real tool_use blocks.
    static let transcript = """
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/home/user/projects/app/README.md"}}]}}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Write","input":{"file_path":"/home/user/projects/app/Sources/New.swift"}}]}}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/home/user/projects/app/Sources/Old.swift"}}]}}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/home/user/.zshrc"}}]}}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"swift test"}}]}}
    """

    @Test("Separates files created from files edited")
    func createdVersusEdited() {
        let activity = SessionActivityReader.parse(Self.transcript, projectPath: "/home/user/projects/app")
        #expect(activity.created.map(\.name) == ["New.swift"])
        #expect(activity.edited.map(\.name) == ["Old.swift"])
        #expect(activity.summary == "wrote 1 file, edited 1")
    }

    @Test("A file that was only read is not reported as changed")
    func readsAreNotChanges() {
        let activity = SessionActivityReader.parse(Self.transcript, projectPath: "/home/user/projects/app")
        // README.md was Read, never written. Saying it changed would be a lie
        // that makes the whole signal untrustworthy.
        #expect(!activity.touched.contains { $0.name == "README.md" })
        #expect(activity.toolCounts["Read"] == 1)   // still counted as activity
    }

    @Test("Files outside the project aren't work on it")
    func outsideProjectIgnored() {
        let activity = SessionActivityReader.parse(Self.transcript, projectPath: "/home/user/projects/app")
        // The agent edited ~/.zshrc; that did not change this project.
        #expect(!activity.touched.contains { $0.path.contains(".zshrc") })
        #expect(SessionActivityReader.isInside("/home/user/projects/app/a.swift", projectPath: "/home/user/projects/app"))
        #expect(!SessionActivityReader.isInside("/home/user/projects/app-other/a.swift", projectPath: "/home/user/projects/app"))
    }

    @Test("Counts tools, which distinguishes exploring from rewriting")
    func toolHistogram() {
        let activity = SessionActivityReader.parse(Self.transcript, projectPath: "/home/user/projects/app")
        #expect(activity.toolCounts["Edit"] == 2)   // includes the one outside the project
        #expect(activity.toolCounts["Bash"] == 1)
        #expect(activity.messageCount == 5)
    }

    @Test("A session that only read things reports its dominant tool")
    func readOnlySession() {
        let readOnly = """
        {"message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/p/a"}}]}}
        {"message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/p/b"}}]}}
        """
        let activity = SessionActivityReader.parse(readOnly, projectPath: "/nowhere")
        #expect(activity.touched.isEmpty)
        #expect(activity.summary == "2× Read")
    }

    @Test("The Codex shape, nested under payload, parses the same way")
    func codexShape() {
        let codex = """
        {"payload":{"content":[{"type":"tool_use","name":"Write","input":{"path":"/p/x.swift"}}]}}
        """
        let activity = SessionActivityReader.parse(codex, projectPath: "/p")
        #expect(activity.created.map(\.name) == ["x.swift"])
    }

    @Test("No project path means nothing is attributable")
    func noProject() {
        let activity = SessionActivityReader.parse(Self.transcript, projectPath: nil)
        #expect(activity.touched.isEmpty)
    }
}

/// Path shapes the token scanner has to tell apart.
@Suite("Path tokens in prose")
struct PathTokenTests {

    @Test("Recognises the three absolute shapes, and nothing else")
    func absoluteShapes() {
        #expect(WaveReader.isAbsolutePathToken("/home/joe/projects/app"))
        #expect(WaveReader.isAbsolutePathToken(#"C:\Users\joe\app"#))
        #expect(WaveReader.isAbsolutePathToken("C:/Users/joe/app"))
        #expect(WaveReader.isAbsolutePathToken(#"\\build-server\share\app"#))

        // Relative paths and prose must not be mistaken for locations.
        #expect(!WaveReader.isAbsolutePathToken("projects/app"))
        #expect(!WaveReader.isAbsolutePathToken("./app"))
        #expect(!WaveReader.isAbsolutePathToken("build/"))
        #expect(!WaveReader.isAbsolutePathToken("C:"))
        #expect(!WaveReader.isAbsolutePathToken("ratio 3:1"))
        #expect(!WaveReader.isAbsolutePathToken(""))
        // A URL is not a filesystem path, and claiming one would attribute a
        // wave to a project because its brief linked to a website.
        #expect(!WaveReader.isAbsolutePathToken("https://example.com/app"))
    }

    @Test("Trailing separators and markdown punctuation come off either platform's paths")
    func trimming() {
        let tokens = WaveReader.pathTokens(in: #"See `/home/joe/app/` and (C:\Users\joe\app), then stop."#)
        #expect(tokens.contains("/home/joe/app"))
        #expect(tokens.contains(#"C:\Users\joe\app"#))
    }
}
