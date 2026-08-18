import Foundation
import Testing
@testable import MultiTaskCore

@Suite("DetectionEngine — merge")
struct MergeTests {
    let now = Fixtures.auditNow
    let config = Configuration()

    private func merge(_ raw: [Session],
                       overrides: UserOverrides = .empty,
                       audit: AuditIndex = AuditIndex(),
                       config: Configuration? = nil) -> [Session] {
        DetectionEngine.merge(raw: raw, overrides: overrides, audit: audit,
                              config: config ?? self.config, now: now)
    }

    @Test("Deduplicates by id, keeping the most recent activity")
    func dedupeById() throws {
        let older = Session.stub(id: "claude:/t.jsonl", lastActivity: now.addingTimeInterval(-100))
        let newer = Session.stub(id: "claude:/t.jsonl", lastActivity: now.addingTimeInterval(-10))

        let merged = merge([older, newer])
        #expect(merged.count == 1)
        #expect(merged[0].lastActivity == newer.lastActivity)
    }

    @Test("Hook records attach to a detected session by harness session id")
    func hookMatchesBySessionId() throws {
        let detected = Session.stub(id: "claude:/a.jsonl", path: "/p", lastActivity: now,
                                    harnessSessionId: "sess-1")
        let hook = Session.stub(id: "hook:sess-1", path: "/p", lastActivity: now,
                                harnessSessionId: "sess-1", hookStatus: .needsAttention, waiting: .approval)

        let merged = merge([detected, hook])
        #expect(merged.count == 1)
        #expect(merged[0].id == "claude:/a.jsonl")
        #expect(merged[0].status == .needsAttention)
        #expect(merged[0].waiting == .approval)
    }

    @Test("Session id wins over project path when a project has two sessions")
    func sessionIdBeatsPathAmbiguity() throws {
        // The v1 contract could only match by path, so it would have attached the
        // hook to whichever of these came first.
        let a = Session.stub(id: "claude:/a.jsonl", path: "/p", lastActivity: now, harnessSessionId: "sess-a")
        let b = Session.stub(id: "claude:/b.jsonl", path: "/p", lastActivity: now, harnessSessionId: "sess-b")
        let hook = Session.stub(id: "hook:sess-b", path: "/p", lastActivity: now,
                                harnessSessionId: "sess-b", hookStatus: .needsAttention, waiting: .question)

        let merged = merge([a, b, hook])
        #expect(merged.count == 2)
        let matched = try #require(merged.first { $0.id == "claude:/b.jsonl" })
        #expect(matched.waiting == .question)
        let untouched = try #require(merged.first { $0.id == "claude:/a.jsonl" })
        #expect(untouched.waiting == nil)
    }

    @Test("A hook record matching nothing is surfaced on its own")
    func unmatchedHookSurvives() throws {
        let hook = Session.stub(id: "hook:/orphan", project: "orphan", path: "/orphan",
                                lastActivity: now, hookStatus: .needsAttention)
        let merged = merge([hook])
        #expect(merged.count == 1)
        #expect(merged[0].id == "hook:/orphan")
    }

    @Test("Hidden sessions are dropped, manual ones are appended")
    func hiddenAndManual() throws {
        var overrides = UserOverrides.empty
        overrides.hidden = ["claude:/a.jsonl"]
        overrides.manual = [Session.stub(id: "manual:1", project: "hand-added", path: nil, source: .manual, lastActivity: now)]

        let merged = merge([Session.stub(id: "claude:/a.jsonl", lastActivity: now)], overrides: overrides)
        #expect(merged.count == 1)
        #expect(merged[0].id == "manual:1")
    }

    @Test("Renames and pins are applied")
    func renamesAndPins() throws {
        var overrides = UserOverrides.empty
        overrides.renames = ["claude:/a.jsonl": "The important one"]
        overrides.pinned = ["claude:/a.jsonl"]

        let merged = merge([Session.stub(id: "claude:/a.jsonl", lastActivity: now)], overrides: overrides)
        #expect(merged[0].title == "The important one")
        #expect(merged[0].isPinned)
    }

    @Test("Sorts pinned first, then by status, then by recency")
    func sortOrder() throws {
        var overrides = UserOverrides.empty
        overrides.pinned = ["pinned-idle"]

        // A session that genuinely needs a person — which now requires a hook to
        // say so, since a gap in activity no longer implies it.
        var asking = Session.stub(id: "asking", lastActivity: now.addingTimeInterval(-60))
        asking.hookStatus = .needsAttention

        let raw = [
            Session.stub(id: "working", lastActivity: now),
            asking,
            Session.stub(id: "pinned-idle", lastActivity: now.addingTimeInterval(-4000)),
            Session.stub(id: "quiet", lastActivity: now.addingTimeInterval(-120))
        ]

        let merged = merge(raw, overrides: overrides)
        // Pinned, then the one actually asking, then working, then quiet.
        #expect(merged.map(\.id) == ["pinned-idle", "asking", "working", "quiet"])
    }

    @Test("hideIdle removes idle sessions but never a pinned one")
    func hideIdleKeepsPinned() throws {
        var overrides = UserOverrides.empty
        overrides.pinned = ["pinned"]
        var config = Configuration()
        config.hideIdle = true

        let raw = [
            Session.stub(id: "pinned", lastActivity: now.addingTimeInterval(-9999)),
            Session.stub(id: "stale", lastActivity: now.addingTimeInterval(-9999))
        ]
        let merged = merge(raw, overrides: overrides, config: config)
        #expect(merged.map(\.id) == ["pinned"])
    }

    @Test("Audit activity moves the clock forward and names the last tool")
    func auditEnrichment() throws {
        let dir = TempDir()
        dir.write(Fixtures.auditClaudePair + "\n", to: "tool-calls.jsonl")
        let audit = AuditLogReader(path: dir.path("tool-calls.jsonl")).refresh(now: now)

        // The transcript looks two hours stale; the audit log knows better.
        let session = Session.stub(id: "claude:/a.jsonl", path: "/home/user/projects/app",
                                   lastActivity: now.addingTimeInterval(-7200),
                                   harnessSessionId: "f9f9b53d-1831-4798-966e-45eddd79dd68")

        let merged = merge([session], audit: audit)
        #expect(merged[0].lastToolName == "Bash")
        #expect(merged[0].evidence == .auditActivity)
        #expect(merged[0].lastActivity > now.addingTimeInterval(-7200))
    }
}

@Suite("DetectionEngine — status precedence")
struct ClassifyTests {
    let now = Fixtures.auditNow
    let config = Configuration()

    @Test("A hook status outranks every inferred signal")
    func hookWins() {
        var session = Session.stub(id: "a", lastActivity: now)   // would classify as working
        session.hookStatus = .needsAttention
        let verdict = DetectionEngine.classify(session, activity: nil, config: config, now: now)
        #expect(verdict.status == .needsAttention)
        #expect(verdict.evidence == .hook)
    }

    @Test("A finished run is complete, and does not claim to need you")
    func sessionEndOutranksActivityAge() {
        // Recent file activity would say "working"; the log says it ended.
        let session = Session.stub(id: "a", lastActivity: now)
        let activity = AuditActivity(lastEventAt: now, endedAt: now.addingTimeInterval(-5),
                                     endReason: "prompt_input_exit")

        let verdict = DetectionEngine.classify(session, activity: activity, config: config, now: now)
        // Was `.needsAttention`, which is how a Codex run that finished cleanly
        // lit the badge asking for a response it did not want.
        #expect(verdict.status == .complete)
        #expect(verdict.evidence == .sessionEnd)
        #expect(verdict.waiting == nil)
        #expect(verdict.reason == "prompt_input_exit")
    }

    @Test("A run that finished long ago ages out to idle instead of nagging forever")
    func endedLongAgoGoesIdle() {
        let session = Session.stub(id: "a", lastActivity: now)
        let activity = AuditActivity(lastEventAt: now.addingTimeInterval(-9999),
                                     endedAt: now.addingTimeInterval(-9999))

        let verdict = DetectionEngine.classify(session, activity: activity, config: config, now: now)
        #expect(verdict.status == .idle)
        #expect(verdict.waiting == nil)
    }

    @Test("Audit last-event age outranks transcript mtime")
    func auditAgeBeatsFileAge() {
        // The transcript hasn't been touched in an hour, but the agent is mid-Bash.
        let session = Session.stub(id: "a", lastActivity: now.addingTimeInterval(-3600))
        let activity = AuditActivity(lastEventAt: now.addingTimeInterval(-2))

        let verdict = DetectionEngine.classify(session, activity: activity, config: config, now: now)
        #expect(verdict.status == .working)
        #expect(verdict.evidence == .auditActivity)
    }

    @Test("Falls back to transcript mtime with no audit log at all")
    func fileActivityFallback() {
        let quiet = Session.stub(id: "a", lastActivity: now.addingTimeInterval(-60))
        let verdict = DetectionEngine.classify(quiet, activity: nil, config: config, now: now)
        // Quiet, and that is all this evidence can honestly support. It used to
        // read silence as a request for attention, which is indistinguishable
        // from an agent thinking or waiting on the network.
        #expect(verdict.status == .idle)
        #expect(verdict.evidence == .fileActivity)
    }

    @Test("Thresholds map gaps to statuses at their boundaries")
    func thresholdBoundaries() {
        func status(after gap: TimeInterval) -> SessionStatus {
            DetectionEngine.classify(Session.stub(id: "a", lastActivity: now.addingTimeInterval(-gap)),
                                     activity: nil, config: config, now: now).status
        }
        #expect(status(after: 0) == .working)
        #expect(status(after: config.attentionThreshold - 1) == .working)
        // Past the threshold it is quiet, not demanding. Nothing inferred from a
        // gap may claim to need a person — only a hook or a waiting task can.
        #expect(status(after: config.attentionThreshold) == .idle)
        #expect(status(after: config.idleThreshold) == .idle)
    }

    @Test("A session with no activity signal at all is unknown, not idle")
    func noSignalIsUnknown() {
        let session = Session.stub(id: "a", lastActivity: .distantPast)
        let verdict = DetectionEngine.classify(session, activity: nil, config: config, now: now)
        #expect(verdict.status == .unknown)
        #expect(verdict.evidence == .none)
    }
}

@Suite("DetectionEngine — end to end")
struct EngineTests {

    @Test("Runs detectors against a fixture tree and produces a classified snapshot")
    func fullRefresh() async throws {
        let dir = TempDir()
        // A Claude Code transcript in the encoded-cwd layout.
        dir.write(Fixtures.claudeTranscript,
                  to: "claude/projects/-home-user-project/f9f9b53d-1831-4798-966e-45eddd79dd68.jsonl")

        // Every built-in detector points at the real home directory, so they are all
        // disabled and a fixture-rooted one is injected instead.
        let engine = DetectionEngine(
            configuration: StaticConfiguration(.fixtureOnly),
            additionalDetectors: [
                ClaudeCodeDetector(projectsRoot: dir.url.appendingPathComponent("claude/projects"))
            ]
        )

        let snapshot = await engine.refresh()
        #expect(snapshot.sessions.count == 1)
        let session = try #require(snapshot.sessions.first)
        #expect(session.harnessSessionId == "f9f9b53d-1831-4798-966e-45eddd79dd68")
        // Read from the transcript's own `cwd`, not from the encoded directory name.
        #expect(session.projectPath == "/home/user/projects/app")
        #expect(session.status == .working)          // just written
        #expect(snapshot.degraded.isEmpty)
    }

    @Test("A detector whose backing directory is missing degrades with a reason")
    func degradedDetector() async throws {
        let engine = DetectionEngine(
            configuration: StaticConfiguration(.fixtureOnly),
            additionalDetectors: [ClaudeCodeDetector(projectsRoot: URL(fileURLWithPath: "/nonexistent/claude"))]
        )
        let snapshot = await engine.refresh()

        #expect(snapshot.sessions.isEmpty)
        #expect(snapshot.degraded.count == 1)
        #expect(snapshot.degraded[0].detectorId == "claudeCode")
        #expect(snapshot.degraded[0].message.contains("/nonexistent/claude"))
    }
}

/// The rule the false alarms came from: only something that *says so* may claim
/// a person is needed.
@Suite("Attention is reported, never inferred")
struct AttentionSourceTests {
    let now = Fixtures.auditNow
    var config: Configuration { .fixtureOnly }

    @Test("No gap in activity, however long, produces needs-attention")
    func silenceNeverDemands() {
        for gap in [0.0, 60, 600, 3600, 86_400] {
            let session = Session.stub(id: "a", lastActivity: now.addingTimeInterval(-gap))
            let verdict = DetectionEngine.classify(session, activity: nil, config: config, now: now)
            #expect(verdict.status != .needsAttention,
                    "a \(Int(gap))s gap claimed to need a person")
        }
    }

    @Test("A hook saying so is what produces needs-attention")
    func hooksDemand() {
        var session = Session.stub(id: "a", lastActivity: now.addingTimeInterval(-86_400))
        session.hookStatus = .needsAttention
        session.waiting = .approval
        session.reason = "Bash(rm -rf build/)"

        let verdict = DetectionEngine.classify(session, activity: nil, config: config, now: now)
        // Quiet for a day, and still correct — because the harness said so
        // rather than the clock.
        #expect(verdict.status == .needsAttention)
        #expect(verdict.evidence == .hook)
        #expect(verdict.waiting == .approval)
        #expect(verdict.reason == "Bash(rm -rf build/)")
    }

    @Test("A finished run is complete, then ages out to idle")
    func completeThenIdle() {
        let session = Session.stub(id: "a", lastActivity: now)
        let justEnded = AuditActivity(lastEventAt: now, endedAt: now.addingTimeInterval(-5),
                                      endReason: "done")
        #expect(DetectionEngine.classify(session, activity: justEnded,
                                         config: config, now: now).status == .complete)

        let longEnded = AuditActivity(lastEventAt: now, endedAt: now.addingTimeInterval(-99_999),
                                      endReason: "done")
        #expect(DetectionEngine.classify(session, activity: longEnded,
                                         config: config, now: now).status == .idle)
    }
}
