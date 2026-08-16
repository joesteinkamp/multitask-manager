import Foundation
import Testing
@testable import MultiTaskCore

@Suite("ProjectContextReader — goal extraction")
struct GoalExtractionTests {

    @Test("Skips headings, badges and HTML comments to reach the first real paragraph")
    func skipsChrome() throws {
        let goal = try #require(ProjectContextReader.extractGoal(from: Fixtures.readmeWithBadges))
        #expect(goal.hasPrefix("A macOS menu-bar app that watches"))
        #expect(!goal.contains("shields.io"))
        #expect(!goal.contains("#"))
    }

    @Test("Joins a wrapped paragraph into a single line and stops at the blank line")
    func joinsWrappedLines() throws {
        let goal = try #require(ProjectContextReader.extractGoal(from: Fixtures.readmeWithBadges))
        #expect(!goal.contains("\n"))
        #expect(!goal.contains("Install"))
    }

    @Test("Returns nil when a doc is nothing but chrome")
    func allChrome() {
        let text = """
        # Title
        > a quote
        | a | table |
        ```
        code
        ```
        """
        #expect(ProjectContextReader.extractGoal(from: text) == nil)
    }

    @Test("Truncates to 240 characters on a word boundary")
    func truncatesLongParagraph() throws {
        let long = String(repeating: "alpha beta ", count: 60)
        let goal = try #require(ProjectContextReader.extractGoal(from: long))
        #expect(goal.count <= 241)          // 240 + the ellipsis
        #expect(goal.hasSuffix("…"))
        #expect(!goal.hasSuffix(" …"))
    }

    @Test("Strips inline markdown links down to their label")
    func stripsLinks() throws {
        let goal = try #require(ProjectContextReader.extractGoal(from: "See [the docs](https://example.com) for **details**."))
        #expect(goal == "See the docs for details.")
    }

    @Test("Leaves a bracketed reference that isn't a link alone")
    func keepsNonLinkBrackets() throws {
        let goal = try #require(ProjectContextReader.extractGoal(from: "Fixes issue [42] in the parser."))
        #expect(goal == "Fixes issue [42] in the parser.")
    }
}

@Suite("ProjectContextReader — next steps")
struct NextStepsTests {

    @Test("Parses every unchecked bullet form and skips checked ones")
    func parsesAllBulletForms() {
        let items = ProjectContextReader.extractNextSteps(from: Fixtures.roadmapWithTasks, limit: nil)
        #expect(items == [
            "Notify when a session needs attention",
            "Read the audit log",
            "Render orchestration waves",
            "Discover worktrees",
            "Parse the delegate roster"
        ])
    }

    @Test("Honours the limit the popover applies")
    func honoursLimit() {
        let items = ProjectContextReader.extractNextSteps(from: Fixtures.roadmapWithTasks, limit: 3)
        #expect(items.count == 3)
    }

    @Test("A nil limit returns everything — the task importer needs all of them")
    func nilLimitReturnsAll() {
        let items = ProjectContextReader.extractNextSteps(from: Fixtures.roadmapWithTasks, limit: nil)
        #expect(items.count == 5)
    }

    @Test("Rejects lines that only look like tasks")
    func rejectsNearMisses() {
        #expect(ProjectContextReader.uncheckedTask(in: "-[ ] no space after the bullet") == nil)
        #expect(ProjectContextReader.uncheckedTask(in: "- [x] done") == nil)
        #expect(ProjectContextReader.uncheckedTask(in: "- [ ]") == nil)
        #expect(ProjectContextReader.uncheckedTask(in: "just prose") == nil)
        #expect(ProjectContextReader.uncheckedTask(in: "- [ ] real") == "real")
    }

    @Test("Truncates a long item to 160 characters")
    func truncatesItems() throws {
        let long = "- [ ] " + String(repeating: "word ", count: 80)
        let item = try #require(ProjectContextReader.extractNextSteps(from: long, limit: nil).first)
        #expect(item.count <= 161)
        #expect(item.hasSuffix("…"))
    }
}

@Suite("ProjectContextReader — transcripts")
struct TranscriptTests {

    @Test("Reads the newest user prompt from a Claude Code transcript")
    func claudeCodeTail() throws {
        let dir = TempDir()
        dir.write(Fixtures.claudeTranscript, to: "session.jsonl")
        let prompt = try #require(ProjectContextReader.latestUserPrompt(fromTranscript: dir.path("session.jsonl")))
        #expect(prompt == "add the audit reader")
    }

    @Test("Ignores assistant turns, meta entries and tool results")
    func ignoresNonUserTurns() throws {
        let dir = TempDir()
        dir.write(Fixtures.claudeTranscript, to: "session.jsonl")
        let prompt = try #require(ProjectContextReader.latestUserPrompt(fromTranscript: dir.path("session.jsonl")))
        #expect(prompt != "working on it")
        #expect(prompt != "injected meta that must not surface")
        #expect(prompt != "tool output")
    }

    @Test("Reads the Codex shape, where the message hangs off payload")
    func codexShape() throws {
        let dir = TempDir()
        dir.write(Fixtures.codexTranscript, to: "rollout.jsonl")
        let prompt = try #require(ProjectContextReader.latestUserPrompt(fromTranscript: dir.path("rollout.jsonl")))
        #expect(prompt == "refactor the store")
    }

    @Test("Drops everything ahead of an injected system reminder")
    func stripsSystemReminder() {
        let raw = "<system-reminder>noise</system-reminder>the real question"
        #expect(ProjectContextReader.sanitizePrompt(raw) == "the real question")
    }

    @Test("Returns nil rather than surfacing a bare tag or a caveat line")
    func dropsNoiseOnlyPrompts() {
        #expect(ProjectContextReader.sanitizePrompt("<command-name>/loop</command-name>") == nil)
        #expect(ProjectContextReader.sanitizePrompt("Caveat: generated by a local command") == nil)
        #expect(ProjectContextReader.sanitizePrompt("   ") == nil)
    }

    @Test("A missing transcript yields nil instead of throwing")
    func missingTranscript() {
        #expect(ProjectContextReader.latestUserPrompt(fromTranscript: "/nonexistent/path.jsonl") == nil)
    }
}

@Suite("ProjectContextReader — assembly and caching")
struct ContextAssemblyTests {

    @Test("Assembles goal, next and now with their provenance")
    func assemblesFullContext() throws {
        let dir = TempDir()
        dir.write(Fixtures.readmeWithBadges, to: "project/README.md")
        dir.write(Fixtures.roadmapWithTasks, to: "project/ROADMAP.md")
        dir.write(Fixtures.claudeTranscript, to: "session.jsonl")

        let reader = ProjectContextReader()
        let ctx = try #require(reader.context(forProjectPath: dir.path("project"),
                                              transcriptPath: dir.path("session.jsonl")))
        #expect(ctx.goalSource == "README.md")
        #expect(ctx.nextSource == "ROADMAP.md")
        #expect(ctx.next.count == 3)
        #expect(ctx.now == "add the audit reader")
    }

    @Test("Rebuilds when a source file changes, serves the cache when it doesn't")
    func cacheInvalidation() throws {
        let dir = TempDir()
        dir.write("# T\n\nOriginal goal.\n", to: "project/README.md")
        let reader = ProjectContextReader()

        let first = try #require(reader.context(forProjectPath: dir.path("project"), transcriptPath: nil))
        #expect(first.goal == "Original goal.")

        // Same inputs, untouched files: the cached value comes back.
        let cached = try #require(reader.context(forProjectPath: dir.path("project"), transcriptPath: nil))
        #expect(cached.goal == "Original goal.")

        dir.write("# T\n\nRewritten goal.\n", to: "project/README.md")
        dir.setModificationDate(Date().addingTimeInterval(60), of: "project/README.md")
        let refreshed = try #require(reader.context(forProjectPath: dir.path("project"), transcriptPath: nil))
        #expect(refreshed.goal == "Rewritten goal.")
    }

    @Test("An empty project yields nil rather than an empty briefing")
    func emptyProjectIsNil() {
        let dir = TempDir()
        dir.makeDirectory("project")
        let reader = ProjectContextReader()
        #expect(reader.context(forProjectPath: dir.path("project"), transcriptPath: nil) == nil)
    }

    @Test("Falls through goal candidates in priority order")
    func goalFileOrder() throws {
        let dir = TempDir()
        // README has nothing usable, so CLAUDE.md should win.
        dir.write("# Only a heading\n", to: "project/README.md")
        dir.write("# Title\n\nThe fallback goal.\n", to: "project/CLAUDE.md")
        let reader = ProjectContextReader()
        let ctx = try #require(reader.context(forProjectPath: dir.path("project"), transcriptPath: nil))
        #expect(ctx.goalSource == "CLAUDE.md")
        #expect(ctx.goal == "The fallback goal.")
    }
}
