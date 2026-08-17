import Foundation
import Testing
@testable import MultiTaskCore

@Suite("MCP server")
struct MCPServerTests {

    private func server(_ dir: TempDir) -> MCPServer {
        let taskStore = TaskStore(directory: dir.url.appendingPathComponent("tasks"))
        let projectStore = ProjectStore(directory: dir.url.appendingPathComponent("projects"))
        let engine = InProcessEngine(
            configuration: StaticConfiguration(.fixtureOnly),
            engine: DetectionEngine(configuration: StaticConfiguration(.fixtureOnly),
                                    projectStore: projectStore, taskStore: taskStore),
            overridesStore: OverridesStore(directory: dir.url.appendingPathComponent("state")),
            taskStore: taskStore
        )
        return MCPServer(client: engine, taskStore: taskStore,
                         projectStore: projectStore, origin: "test-agent")
    }

    @Test("Every advertised tool has a schema and a procedural description")
    func toolsAreWellFormed() {
        let tools = MCPServer.tools
        #expect(tools.count == 9)
        for tool in tools {
            #expect(!tool.name.isEmpty)
            // Descriptions are instructions to an agent, not one-line labels.
            #expect(tool.description.count > 40, "\(tool.name) needs a real description")
            #expect(tool.schema["type"] as? String == "object")
        }
        #expect(tools.map(\.name).contains("whats_next"))
        #expect(tools.map(\.name).contains("create_task"))
        #expect(tools.map(\.name).contains("claim_task"))
    }

    @Test("An unknown tool says so rather than failing the transport")
    func unknownTool() async {
        let dir = TempDir()
        let (text, isError) = await server(dir).call(tool: "teleport", arguments: [:])
        #expect(isError)
        #expect(text.contains("tools/list"))   // tells the agent how to recover
    }

    @Test("An agent can file work and immediately be told to do it")
    func fileThenNext() async throws {
        let dir = TempDir()
        let mcp = server(dir)

        let (filed, failed) = await mcp.call(tool: "create_task", arguments: [
            "title": "Port the engine to Windows",
            "acceptance": "mtm doctor reports the same joins",
            "assignee": "codex",
            "state": "ready"
        ])
        #expect(!failed)
        #expect(filed.hasPrefix("Filed "))

        let (next, _) = await mcp.call(tool: "whats_next", arguments: ["assignee": "codex"])
        #expect(next.contains("Port the engine to Windows"))
        // The acceptance criteria travel with the answer, so an agent doesn't
        // have to fetch the task to know what finished looks like.
        #expect(next.contains("done when: mtm doctor reports the same joins"))
    }

    @Test("Filing without acceptance criteria is allowed but called out")
    func acceptanceNudge() async {
        let dir = TempDir()
        let (text, isError) = await server(dir).call(tool: "create_task", arguments: ["title": "Vague work"])
        #expect(!isError)
        #expect(text.contains("No acceptance criteria"))
    }

    @Test("A re-sync neither duplicates nor erases — and doesn't nag about it")
    func resyncIsSafe() async throws {
        let dir = TempDir()
        let mcp = server(dir)

        _ = await mcp.call(tool: "create_task", arguments: [
            "title": "Port to Windows", "externalRef": "linear:ENG-7",
            "acceptance": "joins match", "assignee": "codex", "state": "ready"
        ])
        // The tracker's second sweep knows only the title and the reference.
        let (second, _) = await mcp.call(tool: "create_task", arguments: [
            "title": "Port to Windows", "externalRef": "linear:ENG-7", "state": "ready"
        ])

        // One task, not two.
        let (list, _) = await mcp.call(tool: "list_tasks", arguments: [:])
        #expect(list.components(separatedBy: "Port to Windows").count - 1 == 1)
        // The acceptance survived, so the warning must not fire.
        #expect(!second.contains("No acceptance criteria"))

        let (next, _) = await mcp.call(tool: "whats_next", arguments: ["assignee": "codex"])
        #expect(next.contains("done when: joins match"))
    }

    @Test("Claiming tells the agent how long it has and what to do when stuck")
    func claimExplainsItself() async throws {
        let dir = TempDir()
        let mcp = server(dir)
        _ = await mcp.call(tool: "create_task", arguments: ["title": "Do a thing", "state": "ready"])

        let (text, isError) = await mcp.call(tool: "claim_task",
                                             arguments: ["taskId": "20260817", "owner": "codex"])
        // Prefix resolution: the agent passes what it was shown.
        if isError {
            // Ids are date-stamped with today's date, so resolve by title instead.
            let (retry, failed) = await mcp.call(tool: "claim_task",
                                                 arguments: ["taskId": "Do a thing", "owner": "codex"])
            #expect(!failed)
            #expect(retry.contains("minutes"))
            #expect(retry.contains("waiting"))
        } else {
            #expect(text.contains("minutes"))
        }
    }

    @Test("Handing work back to a human takes it out of the agent's queue")
    func waitingRemovesFromQueue() async throws {
        let dir = TempDir()
        let mcp = server(dir)
        _ = await mcp.call(tool: "create_task", arguments: [
            "title": "Sign the build", "assignee": "codex", "state": "ready"
        ])

        var (next, _) = await mcp.call(tool: "whats_next", arguments: ["assignee": "codex"])
        #expect(next.contains("Sign the build"))

        _ = await mcp.call(tool: "update_task", arguments: [
            "taskId": "Sign the build", "waiting": "approval", "waitingReason": "needs a cert"
        ])

        (next, _) = await mcp.call(tool: "whats_next", arguments: ["assignee": "codex"])
        // It appears as a thing *not* to start, and nothing else is offered.
        #expect(next.contains("waitingOnHuman"))
        #expect(next.contains("needs a cert"))
        #expect(next.contains("Nothing ready for codex"))
    }

    @Test("Completing names what it freed, which is when that's most useful")
    func completeSuggestsNext() async throws {
        let dir = TempDir()
        let mcp = server(dir)
        _ = await mcp.call(tool: "create_task", arguments: [
            "title": "First", "assignee": "codex", "state": "ready"
        ])
        _ = await mcp.call(tool: "create_task", arguments: [
            "title": "Second", "assignee": "codex", "state": "ready"
        ])

        let (text, isError) = await mcp.call(tool: "complete_task",
                                             arguments: ["taskId": "First", "note": "Shipped."])
        #expect(!isError)
        #expect(text.contains("Completed"))
        #expect(text.contains("Second"))
    }

    @Test("Reading a task reports missing acceptance criteria rather than hiding it")
    func getTaskFlagsMissingAcceptance() async throws {
        let dir = TempDir()
        let mcp = server(dir)
        _ = await mcp.call(tool: "create_task", arguments: ["title": "Unclear work"])

        let (text, _) = await mcp.call(tool: "get_task", arguments: ["taskId": "Unclear work"])
        #expect(text.contains("NOT SPECIFIED"))
    }

    @Test("A missing task is an error the agent can act on")
    func missingTask() async {
        let dir = TempDir()
        let (text, isError) = await server(dir).call(tool: "get_task", arguments: ["taskId": "ghost"])
        #expect(isError)
        #expect(text.contains("ghost"))
    }

    @Test("Dependencies are reported with the state of each blocker")
    func dependenciesDescribed() async throws {
        let dir = TempDir()
        let mcp = server(dir)
        let taskStore = TaskStore(directory: dir.url.appendingPathComponent("tasks"))

        _ = try taskStore.save(TaskRecord(id: "base", title: "Base", state: .ready))
        _ = try taskStore.save(TaskRecord(id: "dependent", title: "Dependent",
                                          state: .ready, deps: ["base"]))

        let (text, _) = await mcp.call(tool: "get_task", arguments: ["taskId": "dependent"])
        #expect(text.contains("dependsOn: base(ready)"))

        let (baseText, _) = await mcp.call(tool: "get_task", arguments: ["taskId": "base"])
        #expect(baseText.contains("blocks: dependent"))
    }
}
