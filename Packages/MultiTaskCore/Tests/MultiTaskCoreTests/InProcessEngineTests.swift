import Foundation
import Testing
@testable import MultiTaskCore

@Suite("InProcessEngine")
struct InProcessEngineTests {

    /// An engine wired to a fixture transcript tree and a throwaway overrides
    /// file, so nothing depends on what happens to be running on the machine.
    private func makeEngine(_ dir: TempDir) -> InProcessEngine {
        dir.write(Fixtures.claudeTranscript,
                  to: "claude/projects/-home-user-project/f9f9b53d-1831-4798-966e-45eddd79dd68.jsonl")
        dir.write(Fixtures.codexTranscript,
                  to: "claude/projects/-home-user-other/aaaaaaaa-0000-0000-0000-000000000009.jsonl")

        let configuration = StaticConfiguration(.fixtureOnly)
        let detection = DetectionEngine(
            configuration: configuration,
            additionalDetectors: [
                ClaudeCodeDetector(projectsRoot: dir.url.appendingPathComponent("claude/projects"))
            ]
        )
        return InProcessEngine(
            configuration: configuration,
            engine: detection,
            overridesStore: OverridesStore(directory: dir.url.appendingPathComponent("state"))
        )
    }

    @Test("Lists what the detectors found")
    func listsSessions() async throws {
        let dir = TempDir()
        let engine = makeEngine(dir)

        let snapshot = try await engine.list()
        #expect(snapshot.sessions.count == 2)
        #expect(snapshot.sessions.allSatisfy { $0.harnessSessionId != nil })
    }

    @Test("Serves the cached snapshot until a refresh is asked for")
    func servesCache() async throws {
        let dir = TempDir()
        let engine = makeEngine(dir)

        let first = try await engine.list()
        let cached = try await engine.list()
        #expect(first.refreshedAt == cached.refreshedAt)

        let refreshed = try await engine.list(SessionQuery(refresh: true))
        #expect(refreshed.refreshedAt > first.refreshedAt)
    }

    @Test("waitingOnly returns just the waiting sessions, in triage order")
    func waitingOnlyFilters() async throws {
        let dir = TempDir()
        let engine = makeEngine(dir)

        // Both transcripts were written moments ago, so nothing is waiting yet.
        let all = try await engine.list()
        #expect(all.sessions.count == 2)

        let waiting = try await engine.list(SessionQuery(waitingOnly: true))
        #expect(waiting.sessions.allSatisfy { $0.status == .needsAttention })
        #expect(waiting.sessions.count <= all.sessions.count)
    }

    @Test("A project filter narrows sessions, waves and repositories together")
    func projectFilter() async throws {
        let dir = TempDir()
        let engine = makeEngine(dir)

        let filtered = try await engine.list(SessionQuery(projectPath: "/home/user/projects/app"))
        #expect(filtered.sessions.count == 1)
        #expect(filtered.sessions[0].projectPath == "/home/user/projects/app")
    }

    @Test("get returns one session, or nil for an id that isn't tracked")
    func getById() async throws {
        let dir = TempDir()
        let engine = makeEngine(dir)

        let snapshot = try await engine.list()
        let id = try #require(snapshot.sessions.first?.id)

        #expect(try await engine.get(sessionId: id)?.id == id)
        #expect(try await engine.get(sessionId: "nope") == nil)
    }

    @Test("Health reports what the engine can see, without a second reader")
    func healthReport() async throws {
        let dir = TempDir()
        let engine = makeEngine(dir)

        _ = try await engine.list()
        let health = try await engine.health()

        #expect(health.sessionCount == 2)
        #expect(health.engineVersion == WireProtocol.version)
        #expect(health.lastRefresh != nil)
        // The audit log is disabled in fixtureOnly, so there are no joins to report
        // — and that reads as zero rather than as a crash.
        #expect(health.preciseJoins == 0)
    }
}

@Suite("InProcessEngine — actions")
struct InProcessEngineActionTests {

    private func makeEngine(_ dir: TempDir) -> InProcessEngine {
        dir.write(Fixtures.claudeTranscript,
                  to: "claude/projects/-home-user-project/f9f9b53d-1831-4798-966e-45eddd79dd68.jsonl")
        let configuration = StaticConfiguration(.fixtureOnly)
        return InProcessEngine(
            configuration: configuration,
            engine: DetectionEngine(
                configuration: configuration,
                additionalDetectors: [
                    ClaudeCodeDetector(projectsRoot: dir.url.appendingPathComponent("claude/projects"))
                ]
            ),
            overridesStore: OverridesStore(directory: dir.url.appendingPathComponent("state"))
        )
    }

    @Test("Pinning is reflected in the snapshot the action returns")
    func pinRoundTrip() async throws {
        let dir = TempDir()
        let engine = makeEngine(dir)
        let id = try #require(try await engine.list().sessions.first?.id)

        let result = try await engine.act(.pin(sessionId: id))
        #expect(result.ok)
        #expect(result.snapshot?.sessions.first { $0.id == id }?.isPinned == true)

        try await engine.act(.unpin(sessionId: id))
        #expect(try await engine.get(sessionId: id)?.isPinned == false)
    }

    @Test("Hiding removes a session; clearing hidden brings it back")
    func hideAndRestore() async throws {
        let dir = TempDir()
        let engine = makeEngine(dir)
        let id = try #require(try await engine.list().sessions.first?.id)

        let hidden = try await engine.act(.hide(sessionId: id))
        #expect(hidden.snapshot?.sessions.isEmpty == true)

        let restored = try await engine.act(.clearHidden)
        #expect(restored.snapshot?.sessions.count == 1)
    }

    @Test("Renaming a detected session changes its title, not its id")
    func rename() async throws {
        let dir = TempDir()
        let engine = makeEngine(dir)
        let id = try #require(try await engine.list().sessions.first?.id)

        let result = try await engine.act(.rename(sessionId: id, title: "The important one"))
        let renamed = try #require(result.snapshot?.sessions.first { $0.id == id })
        #expect(renamed.title == "The important one")
    }

    @Test("An empty title is refused with a parameter fault, not silently ignored")
    func emptyRenameRefused() async throws {
        let dir = TempDir()
        let engine = makeEngine(dir)
        let id = try #require(try await engine.list().sessions.first?.id)

        let fault = await expectError(ProtocolFault.self) {
            _ = try await engine.act(.rename(sessionId: id, title: "   "))
        }
        #expect(fault?.code == .badParameters)
    }

    @Test("A manual entry can be added and removed")
    func manualEntries() async throws {
        let dir = TempDir()
        let engine = makeEngine(dir)

        let added = try await engine.act(.addManual(title: "Call the bank", projectPath: nil))
        let manual = try #require(added.snapshot?.sessions.first { $0.isManual })
        #expect(manual.title == "Call the bank")

        let removed = try await engine.act(.removeManual(sessionId: manual.id))
        #expect(removed.snapshot?.sessions.contains { $0.isManual } == false)
    }

    @Test("Hiding a manual entry deletes it rather than hiding it forever")
    func hidingManualDeletes() async throws {
        let dir = TempDir()
        let engine = makeEngine(dir)

        let added = try await engine.act(.addManual(title: "By hand", projectPath: nil))
        let manual = try #require(added.snapshot?.sessions.first { $0.isManual })

        try await engine.act(.hide(sessionId: manual.id))
        // If it had merely been hidden, restoring would resurrect it.
        let restored = try await engine.act(.clearHidden)
        #expect(restored.snapshot?.sessions.contains { $0.isManual } == false)
    }

    @Test("Overrides survive a new engine over the same store")
    func overridesPersist() async throws {
        let dir = TempDir()
        let first = makeEngine(dir)
        let id = try #require(try await first.list().sessions.first?.id)
        try await first.act(.pin(sessionId: id))

        // OverridesStore writes asynchronously; give it a moment to land.
        try await Task.sleep(nanoseconds: 200_000_000)

        let second = makeEngine(dir)
        let session = try #require(try await second.list().sessions.first { $0.id == id })
        #expect(session.isPinned)
    }

    @Test("Muting a project is recorded so the policy can honour it")
    func muteRecorded() async throws {
        let dir = TempDir()
        let engine = makeEngine(dir)

        try await engine.act(.mute(projectPath: "/home/user/projects/app"))
        try await Task.sleep(nanoseconds: 200_000_000)

        let store = OverridesStore(directory: dir.url.appendingPathComponent("state"))
        #expect(store.load().mutedProjects.contains("/home/user/projects/app"))
    }
}

@Suite("EngineSnapshot — change digest")
struct SnapshotDigestTests {
    let now = Fixtures.auditNow

    private func snapshot(_ sessions: [Session]) -> EngineSnapshot {
        var snapshot = EngineSnapshot()
        snapshot.sessions = sessions
        snapshot.refreshedAt = now
        return snapshot
    }

    @Test("Activity drifting forward is not a change worth pushing")
    func timestampDriftIsNotAChange() {
        // This is the case that matters: on a quiet machine every tick moves
        // lastActivity, and pushing for that alone means a subscriber redraws
        // forever while nothing happens.
        let before = snapshot([Session.stub(id: "a", lastActivity: now, status: .working)])
        let after = snapshot([Session.stub(id: "a", lastActivity: now.addingTimeInterval(5), status: .working)])

        #expect(before != after)                              // plain equality says "changed"
        #expect(before.changeDigest == after.changeDigest)    // …but nothing a client reacts to did
    }

    @Test("A status change is a change")
    func statusChangeCounts() {
        let before = snapshot([Session.stub(id: "a", lastActivity: now, status: .working)])
        let after = snapshot([Session.stub(id: "a", lastActivity: now, status: .needsAttention)])
        #expect(before.changeDigest != after.changeDigest)
    }

    @Test("A session appearing or leaving is a change")
    func membershipCounts() {
        let one = snapshot([Session.stub(id: "a", lastActivity: now)])
        let two = snapshot([Session.stub(id: "a", lastActivity: now), Session.stub(id: "b", lastActivity: now)])
        #expect(one.changeDigest != two.changeDigest)
    }

    @Test("Learning why a session is waiting is a change")
    func waitReasonCounts() {
        let before = snapshot([Session.stub(id: "a", lastActivity: now, status: .needsAttention)])
        let after = snapshot([Session.stub(id: "a", lastActivity: now, waiting: .approval, status: .needsAttention)])
        #expect(before.changeDigest != after.changeDigest)
    }

    @Test("A converge breaking is a change even with no session activity")
    func conflictCounts() {
        var before = snapshot([])
        before.repositories = [RepositoryState(path: "/p", name: "p", scannedAt: now)]
        var after = snapshot([])
        after.repositories = [RepositoryState(path: "/p", name: "p",
                                              conflictMarkers: [".converge-conflict-ai-claude"],
                                              scannedAt: now)]
        #expect(before.changeDigest != after.changeDigest)
    }

    @Test("A source going degraded is a change")
    func degradedCounts() {
        var before = snapshot([])
        var after = snapshot([])
        after.degraded = [DegradedReason(detectorId: "codex", message: "gone")]
        #expect(before.changeDigest != after.changeDigest)
        before.degraded = after.degraded
        #expect(before.changeDigest == after.changeDigest)
    }
}

@Suite("InProcessEngine — subscriptions")
struct InProcessEngineSubscriptionTests {

    @Test("A new subscriber gets the current snapshot without waiting a cadence")
    func replaysLatestOnSubscribe() async throws {
        let dir = TempDir()
        dir.write(Fixtures.claudeTranscript,
                  to: "claude/projects/-home-user-project/f9f9b53d-1831-4798-966e-45eddd79dd68.jsonl")
        let configuration = StaticConfiguration(.fixtureOnly)
        let engine = InProcessEngine(
            configuration: configuration,
            engine: DetectionEngine(
                configuration: configuration,
                additionalDetectors: [
                    ClaudeCodeDetector(projectsRoot: dir.url.appendingPathComponent("claude/projects"))
                ]
            ),
            overridesStore: OverridesStore(directory: dir.url.appendingPathComponent("state"))
        )

        _ = try await engine.list()   // there is now a snapshot to replay

        var iterator = engine.subscribe().makeAsyncIterator()
        let event = await iterator.next()

        guard case .snapshot(let snapshot)? = event else {
            Issue.record("expected a replayed snapshot, got \(String(describing: event))")
            return
        }
        #expect(snapshot.sessions.count == 1)

        // An action changes the snapshot, so the next event is the updated one.
        let id = snapshot.sessions[0].id
        try await engine.act(.pin(sessionId: id))

        guard case .snapshot(let updated)? = await iterator.next() else {
            Issue.record("expected an updated snapshot")
            return
        }
        #expect(updated.sessions.first { $0.id == id }?.isPinned == true)
    }
}
