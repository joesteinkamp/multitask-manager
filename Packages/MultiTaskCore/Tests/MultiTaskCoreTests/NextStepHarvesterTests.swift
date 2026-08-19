import Foundation
import Testing
@testable import MultiTaskCore

@Suite("Harvesting next steps agents already wrote")
struct NextStepHarvesterTests {

    // MARK: Extraction

    @Test("A next-steps heading followed by bullets yields those bullets")
    func headingAndBullets() {
        let message = """
        I've finished the migration and all tests pass.

        ## Next steps
        - Wire the harvester into the project assembler
        - Add a dismissal ledger so rejected steps stay rejected
        - Backfill the Windows process liveness check

        Everything else is green.
        """
        let steps = NextStepHarvester.extract(from: message)
        #expect(steps.count == 3)
        #expect(steps.first == "Wire the harvester into the project assembler")
        #expect(steps.last == "Backfill the Windows process liveness check")
    }

    @Test("Numbered lists and checkboxes count as items")
    func otherListShapes() {
        let numbered = NextStepHarvester.extract(from: "Remaining:\n1. Rotate the audit log\n2) Ship the CLI flag")
        #expect(numbered == ["Rotate the audit log", "Ship the CLI flag"])

        let checked = NextStepHarvester.extract(from: "Still to do\n- [ ] Rebuild the token file\n- [ ] Verify on the Mac")
        #expect(checked.count == 2)
    }

    @Test("A cue introducing one sentence works without a list")
    func singleSentence() {
        let steps = NextStepHarvester.extract(from: "Next step: run the generator and commit both files.")
        #expect(steps == ["run the generator and commit both files."])
    }

    /// The failure mode that makes a suggestion queue worthless: filling it with
    /// the agent's own chatter.
    @Test("Prose with no cue yields nothing")
    func noCueNoSteps() {
        let message = """
        I fixed the bug in the detector and pushed the branch.
        The build is green and the tests all pass.
        """
        #expect(NextStepHarvester.extract(from: message).isEmpty)
    }

    @Test("Questions and offers to help are not steps")
    func rejectsChatter() {
        let message = """
        Next steps
        - Want me to open the PR?
        - Let me know if you'd like the Windows fix too
        - Nothing further
        - Regenerate the design tokens and commit
        """
        let steps = NextStepHarvester.extract(from: message)
        #expect(steps == ["Regenerate the design tokens and commit"])
    }

    @Test("The list ends at a blank line, not at the end of the message")
    func listTerminates() {
        let message = """
        Next steps
        - Merge the colour branch

        I also noticed the icon flickers on wake, which is unrelated.
        - this dash is prose, not a step
        """
        #expect(NextStepHarvester.extract(from: message) == ["Merge the colour branch"])
    }

    @Test("Repeated items across a summary and a list appear once")
    func deduplicates() {
        let message = """
        Next steps
        - Ship the harvester
        - Ship the harvester
        """
        #expect(NextStepHarvester.extract(from: message).count == 1)
    }

    // MARK: Transcript shapes

    @Test("Reads the Claude Code assistant shape")
    func claudeCodeShape() throws {
        let obj: [String: Any] = [
            "type": "assistant",
            "message": ["role": "assistant", "content": [
                ["type": "thinking", "text": "Next steps\n- do not harvest me"],
                ["type": "text", "text": "Done.\n\nNext steps\n- Verify the hook fires on the Mac"]
            ]]
        ]
        let text = try #require(NextStepHarvester.assistantText(from: obj))
        #expect(text.contains("Verify the hook fires"))
        // Thinking blocks are not advice to the user.
        #expect(!text.contains("do not harvest me"))
        #expect(NextStepHarvester.extract(from: text) == ["Verify the hook fires on the Mac"])
    }

    @Test("Reads the Codex payload shape and skips user turns")
    func codexShape() {
        let assistant: [String: Any] = [
            "type": "response_item",
            "payload": ["role": "assistant", "content": [
                ["type": "output_text", "text": "Remaining:\n- Rebase onto integration"]
            ]]
        ]
        #expect(NextStepHarvester.assistantText(from: assistant)?.contains("Rebase") == true)

        let user: [String: Any] = ["type": "user", "payload": ["role": "user", "content": "next steps please"]]
        #expect(NextStepHarvester.assistantText(from: user) == nil)
    }

    @Test("Walks a transcript back to the newest assistant message")
    func readsTranscriptTail() throws {
        let dir = TempDir()
        let file = dir.url.appendingPathComponent("session.jsonl")
        let lines = [
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Next steps\n- an older step nobody wants"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":"carry on"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Next steps\n- Publish the changelog entry"}]}}"#
        ]
        try FileSupport.write(lines.joined(separator: "\n") + "\n", to: file)

        let steps = NextStepHarvester.steps(fromTranscript: file.path,
                                            projectPath: "/w/demo", agent: "claude",
                                            sessionId: "s1", capturedAt: Date())
        #expect(steps.count == 1)
        #expect(steps[0].text == "Publish the changelog entry")
        #expect(steps[0].source == "Claude Code")
        #expect(steps[0].projectPath == "/w/demo")
    }

    @Test("A session listing a dozen follow-ups is capped")
    func capsPerSession() throws {
        let dir = TempDir()
        let file = dir.url.appendingPathComponent("chatty.jsonl")
        let body = (1...12).map { "- Step number \($0) of the plan" }.joined(separator: "\\n")
        try FileSupport.write(
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Next steps\n"# + body + #""}]}}"# + "\n",
            to: file)
        let steps = NextStepHarvester.steps(fromTranscript: file.path, projectPath: "/w/x",
                                            agent: "codex", sessionId: nil, capturedAt: Date())
        #expect(steps.count == NextStepHarvester.maxPerSession)
    }

    // MARK: Identity and the dismissal ledger

    @Test("The same step from a later session is the same step")
    func identityIgnoresSession() {
        let a = SuggestedStep(text: "Ship the harvester", projectPath: "/w/demo",
                              agent: "claude", sessionId: "one", source: "Claude Code", capturedAt: Date())
        let b = SuggestedStep(text: "Ship  the   harvester.", projectPath: "/w/demo",
                              agent: "codex", sessionId: "two", source: "codex", capturedAt: Date())
        #expect(a.id == b.id)
    }

    @Test("Different projects proposing the same words are different steps")
    func identityIsScopedToProject() {
        let a = SuggestedStep(text: "Update the README", projectPath: "/w/one",
                              source: "Claude Code", capturedAt: Date())
        let b = SuggestedStep(text: "Update the README", projectPath: "/w/two",
                              source: "Claude Code", capturedAt: Date())
        #expect(a.id != b.id)
    }

    /// The bug that would make the feature intolerable: a dismissed step comes
    /// back on the next refresh, because it is re-derived from a file that hasn't
    /// changed.
    @Test("A dismissed step never returns")
    func dismissalSticks() {
        let dir = TempDir()
        let store = SuggestionStore(file: dir.url.appendingPathComponent("s.json"))
        let step = SuggestedStep(text: "Rewrite the onboarding copy", projectPath: "/w/demo",
                                 source: "Claude Code", capturedAt: Date())
        #expect(store.pending([step]).count == 1)
        store.dismiss(step)
        #expect(store.pending([step]).isEmpty)

        // Re-harvested from the same transcript on the next refresh: still gone.
        let again = SuggestedStep(text: "Rewrite the onboarding copy", projectPath: "/w/demo",
                                  agent: "codex", sessionId: "later", source: "codex", capturedAt: Date())
        #expect(store.pending([again]).isEmpty)
    }

    @Test("Decisions survive a restart")
    func ledgerPersists() {
        let dir = TempDir()
        let file = dir.url.appendingPathComponent("s.json")
        let step = SuggestedStep(text: "Add the Windows liveness check", projectPath: "/w/demo",
                                 source: "Claude Code", capturedAt: Date())
        SuggestionStore(file: file).accept(step)
        #expect(SuggestionStore(file: file).isDecided(step.id))
        #expect(SuggestionStore(file: file).pending([step]).isEmpty)
    }

    @Test("Reconsidering offers the step again")
    func reconsider() {
        let dir = TempDir()
        let store = SuggestionStore(file: dir.url.appendingPathComponent("s.json"))
        let step = SuggestedStep(text: "Retire the unbriefed status", projectPath: "/w/demo",
                                 source: "Claude Code", capturedAt: Date())
        store.dismiss(step)
        store.reconsider(step.id)
        #expect(store.pending([step]).count == 1)
    }
}

@Suite("Suggested steps reaching the project layer")
struct SuggestedStepAssemblyTests {

    /// The end-to-end claim: an agent wrote down what it thought came next, the
    /// person closed the terminal, and the project row can still tell them.
    @Test("A project assembles the steps its session proposed")
    func assemblesFromSession() throws {
        let dir = TempDir()
        dir.makeDirectory("app")
        dir.write("# Demo", to: "app/README.md")
        let path = dir.path("app")

        let transcript = dir.url.appendingPathComponent("app/session.jsonl")
        try FileSupport.write(
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Shipped it.\n\nNext steps\n- Verify the notification opens Warp\n- Retire the unbriefed status"}]}}"# + "\n",
            to: transcript)

        var session = Session.stub(id: "s1", lastActivity: Date(), status: .idle)
        session.projectPath = path
        session.transcriptPath = transcript.path
        session.source = .claudeCode

        let store = SuggestionStore(file: dir.url.appendingPathComponent("ledger.json"))
        let assembler = ProjectAssembler(suggestions: store)
        let record = ProjectRecord(id: "p1", name: "Demo", path: path)

        let projects = assembler.assemble(records: [record], sessions: [session],
                                          waves: [], repositories: [], config: Configuration())
        let project = try #require(projects.first)

        #expect(project.suggestedSteps.count == 2)
        #expect(project.suggestedSteps.first?.text == "Verify the notification opens Warp")
        #expect(project.suggestedSteps.first?.source == "Claude Code")

        // Dismiss one; reassembling from the same unchanged transcript must not
        // bring it back.
        store.dismiss(project.suggestedSteps[0])
        let again = assembler.assemble(records: [record], sessions: [session],
                                       waves: [], repositories: [], config: Configuration())
        #expect(again.first?.suggestedSteps.count == 1)
        #expect(again.first?.suggestedSteps.first?.text == "Retire the unbriefed status")
    }

    @Test("A README-only project reports a real state, not a question mark")
    func readmeIsEnough() throws {
        let dir = TempDir()
        dir.makeDirectory("app")
        dir.write("# Demo\n\nA thing.", to: "app/README.md")

        let record = ProjectRecord(id: "p1", name: "Demo", path: dir.path("app"))
        let projects = ProjectAssembler(suggestions: SuggestionStore(
            file: dir.url.appendingPathComponent("l.json")))
            .assemble(records: [record], sessions: [], waves: [],
                      repositories: [], config: Configuration())

        #expect(projects.first?.status == .ready)
        #expect(projects.first?.statusReason.contains("PRODUCT.md") == false)
    }
}
