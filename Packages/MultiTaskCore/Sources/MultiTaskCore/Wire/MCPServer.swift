import Foundation

/// The board, exposed to agents over the Model Context Protocol.
///
/// This is the surface the North Star runs on: an agent elsewhere — a session
/// with Notion and Linear also connected — works out what work exists, files it
/// here, takes the next task, and closes it out, without a human relaying any of
/// it. That makes the board an **input** surface, not only an output, which is
/// why the write tools ship alongside the read ones rather than after them.
///
/// ## The gate line
/// "Confirmation gates are inherited" cannot mean every write prompts — an agent
/// filing twelve tasks would produce twelve dialogs and the feature would be off
/// within a day. The line that holds is **organising work is free; spending is
/// gated.** Creating, updating and reprioritising need no approval. Anything
/// that starts a run, touches a repository, deletes work, or writes outward
/// stops and asks exactly as it would from a terminal — and none of those tools
/// exist here yet, deliberately.
///
/// Transport-free by design: this maps a decoded request to a decoded response,
/// so every tool is testable without a pipe.
public struct MCPServer: Sendable {
    public static let protocolVersion = "2024-11-05"
    public static let serverName = "multitask-manager"

    private let client: any EngineClient
    private let taskStore: TaskStore
    private let projectStore: ProjectStore
    /// Recorded on everything this server writes, so the board can always say
    /// where a row came from.
    private let origin: String

    public init(client: any EngineClient,
                taskStore: TaskStore = TaskStore(),
                projectStore: ProjectStore = ProjectStore(),
                origin: String = "mcp") {
        self.client = client
        self.taskStore = taskStore
        self.projectStore = projectStore
        self.origin = origin
    }

    // MARK: Tools

    /// A tool as MCP advertises it.
    ///
    /// Descriptions are written as **procedures, not API docs**. Agents follow
    /// numbered steps far more reliably than they infer a workflow from a
    /// parameter list, and the prior art this design learned from made exactly
    /// that discovery.
    /// Not `Sendable`: `schema` is a JSON fragment (`[String: Any]`) built and
    /// serialised synchronously on the way out. Making it Sendable would mean
    /// modelling JSON as an enum for no benefit — nothing hands a `Tool` across
    /// an isolation boundary.
    public struct Tool {
        public var name: String
        public var description: String
        public var schema: [String: Any]

        public init(name: String, description: String, schema: [String: Any]) {
            self.name = name
            self.description = description
            self.schema = schema
        }
    }

    static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    static func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    public static var tools: [Tool] {
        [
            Tool(name: "whats_next",
                 description: """
                 Ask what to work on next. Start here.

                 1. Call this before deciding anything — it returns work already \
                 ranked, with the reason for each ranking.
                 2. Take the first item unless you have a reason not to.
                 3. Claim it with claim_task before starting, so nothing else \
                 picks up the same work.

                 Anything listed under `waitingOnHuman` is blocked on a person: \
                 do not attempt it, and do not treat it as available.
                 """,
                 schema: object([
                    "assignee": string("Whose queue: 'me' for the human, or a delegate name like 'claude'. Omit for everyone."),
                    "limit": ["type": "integer", "description": "How many to return. Default 5."]
                 ])),

            Tool(name: "list_projects",
                 description: """
                 List the projects being tracked, each with its status and the \
                 reason for that status. Use this to find the projectId you need \
                 before filing a task.
                 """,
                 schema: object([
                    "includeArchived": ["type": "boolean", "description": "Include archived and parked projects."]
                 ])),

            Tool(name: "list_tasks",
                 description: """
                 List tasks. Filter before you fetch: unfiltered listings get \
                 long, and you almost always want one project or one state.
                 """,
                 schema: object([
                    "projectId": string("Restrict to one project."),
                    "state": string("backlog | ready | running | review | done | blocked"),
                    "assignee": string("'me' or a delegate name."),
                    "includeDone": ["type": "boolean", "description": "Include completed tasks. Default false."]
                 ])),

            Tool(name: "get_task",
                 description: "Read one task in full, including its acceptance criteria, dependencies, and what it blocks.",
                 schema: object(["taskId": string("Task id, or any unique prefix.")], required: ["taskId"])),

            Tool(name: "create_task",
                 description: """
                 File a piece of work.

                 1. Always give `acceptance` — what has to be true for this to be \
                 done. Work filed without it gets delivered wrong and rejected, \
                 which costs more than writing the line.
                 2. Give `projectId` unless the work genuinely belongs to no \
                 project. Use list_projects to find it.
                 3. If this came from an external tracker, pass `externalRef` \
                 (e.g. 'linear:ENG-412'). Filing twice with the same ref updates \
                 the existing task instead of creating a duplicate — without it, \
                 a sync that runs twice doubles the board.
                 """,
                 schema: object([
                    "title": string("What needs doing, in a few words."),
                    "acceptance": string("What must be true for this to be done."),
                    "projectId": string("Owning project."),
                    "assignee": string("'me' for the human, or a delegate name."),
                    "body": string("The outcome in prose, and any context a delegate would need."),
                    "deps": ["type": "array", "items": ["type": "string"],
                             "description": "Task ids that must be done first."],
                    "externalRef": string("Idempotency key, e.g. 'linear:ENG-412'."),
                    "state": string("backlog (default) or ready.")
                 ], required: ["title"])),

            Tool(name: "update_task",
                 description: """
                 Change a task. Only the fields you pass are altered; everything \
                 else is left alone, so you cannot erase what you don't know about.

                 To hand something back to the human, set `waiting` to approval, \
                 question, or error, and say why in `waitingReason`. That is how \
                 you stop and ask rather than guessing.
                 """,
                 schema: object([
                    "taskId": string("Task id, or any unique prefix."),
                    "title": string("New title."),
                    "state": string("backlog | ready | running | review | done | blocked"),
                    "assignee": string("'me' or a delegate name."),
                    "acceptance": string("What done means."),
                    "body": string("Replace the task body."),
                    "waiting": string("approval | question | error | done, or empty to clear."),
                    "waitingReason": string("Why a human is needed, in a few words."),
                    "projectId": string("Move to another project.")
                 ], required: ["taskId"])),

            Tool(name: "claim_task",
                 description: """
                 Take a task before working on it. Claims expire after 30 minutes, \
                 so a crashed run returns its work to the queue rather than \
                 stranding it. Claiming something another agent already holds \
                 fails — pick the next item instead.
                 """,
                 schema: object([
                    "taskId": string("Task id, or any unique prefix."),
                    "owner": string("Who is taking it — your own delegate name.")
                 ], required: ["taskId", "owner"])),

            Tool(name: "complete_task",
                 description: """
                 Close a task out.

                 Before calling this, check the task's acceptance criteria and be \
                 honest about whether they are met. If they are not, use \
                 update_task with `waiting` instead and explain what is missing. \
                 Marking unfinished work done is worse than leaving it open.
                 """,
                 schema: object([
                    "taskId": string("Task id, or any unique prefix."),
                    "note": string("What you did, appended to the task body.")
                 ], required: ["taskId"])),

            Tool(name: "project_status",
                 description: "Everything about one project: status and why, progress, open tasks, live sessions.",
                 schema: object(["projectId": string("Project id or name prefix.")], required: ["projectId"])),

            Tool(name: "request_run",
                 description: """
                 Ask the human for permission to hand a task to a delegate.

                 This does NOT start anything. It files a request that appears in                  the human's app as something needing their decision. There is no                  tool to approve your own request — that is deliberate, and                  looking for one is not a productive use of your turn.

                 1. Give `rationale`: why this work, why now, why this delegate.                  A request with no reason takes longer to approve than to write.
                 2. Then move on to other work. Do not poll; check                  list_my_requests when you next need to know.
                 3. If it is declined, do not re-file the same request. Read the                  note and change something first.
                 """,
                 schema: object([
                    "taskId": string("Task id, or any unique prefix."),
                    "delegate": string("Which delegate should run it. Defaults to the task's assignee."),
                    "requestedBy": string("Your own name, so the human knows who asked."),
                    "rationale": string("Why this should happen. Write it as if the reader has not been following along.")
                 ], required: ["taskId", "requestedBy"])),

            Tool(name: "request_isolation",
                 description: """
                 Ask the human for permission to create an isolated git worktree                  and context directory for a task, so an editing delegate can                  work without colliding with anyone else.

                 Same shape as request_run: this files a request and starts                  nothing. Ask for this before requesting a run when the work                  edits files and other agents are active in the same repository.
                 """,
                 schema: object([
                    "taskId": string("Task id, or any unique prefix."),
                    "agent": string("Agent name — becomes the ai/<agent> branch."),
                    "requestedBy": string("Your own name."),
                    "rationale": string("Why isolation is needed here.")
                 ], required: ["taskId", "requestedBy"])),

            Tool(name: "list_my_requests",
                 description: """
                 The state of approval requests: pending, approved, declined, or                  expired. Call this to find out what the human decided, rather                  than asking them again.
                 """,
                 schema: object([
                    "requestedBy": string("Restrict to your own requests. Omit to see all."),
                    "includeDecided": ["type": "boolean", "description": "Include decided requests. Default true."]
                 ])),

            Tool(name: "list_runs",
                 description: """
                 Delegate runs, newest first, with state and exit code. Use this                  to find out how a run you asked for turned out.
                 """,
                 schema: object([
                    "limit": ["type": "integer", "description": "How many to return. Default 10."]
                 ]))
        ]
    }

    // MARK: Dispatch

    /// Runs one tool call and returns the text an agent sees.
    ///
    /// Errors come back as content rather than as transport failures, because an
    /// agent recovers from "that task doesn't exist" far better than from a
    /// protocol-level error it has no vocabulary for.
    public func call(tool name: String, arguments: [String: Any]) async -> (text: String, isError: Bool) {
        do {
            switch name {
            case "whats_next":   return (try await whatsNext(arguments), false)
            case "list_projects": return (try await listProjects(arguments), false)
            case "list_tasks":   return (try await listTasks(arguments), false)
            case "get_task":     return (try await getTask(arguments), false)
            case "create_task":  return (try await createTask(arguments), false)
            case "update_task":  return (try await updateTask(arguments), false)
            case "claim_task":   return (try await claimTask(arguments), false)
            case "complete_task": return (try await completeTask(arguments), false)
            case "project_status": return (try await projectStatus(arguments), false)
            case "request_run":    return (try await requestRun(arguments, kind: "run"), false)
            case "request_isolation": return (try await requestRun(arguments, kind: "provision"), false)
            case "list_my_requests": return (try await listRequests(arguments), false)
            case "list_runs":      return (try await listRuns(arguments), false)
            default:
                return ("No tool named \(name). Call tools/list to see what exists.", true)
            }
        } catch let error as TaskStoreError {
            return (error.description, true)
        } catch {
            return ("\(error)", true)
        }
    }

    // MARK: Tool implementations

    private func whatsNext(_ args: [String: Any]) async throws -> String {
        let snapshot = try await client.list()
        let assignee = (args["assignee"] as? String).map(Assignee.init(encoded:))
        let limit = args["limit"] as? Int ?? 5

        var lines: [String] = []

        let waiting = snapshot.tasksNeedingYou()
        if !waiting.isEmpty {
            lines.append("waitingOnHuman — do not start these:")
            for task in waiting.prefix(limit) {
                lines.append("  \(task.id) · \(task.title) · \(task.waitingReason ?? task.waiting?.label ?? "waiting")")
            }
            lines.append("")
        }

        let next = snapshot.whatNext(for: assignee, limit: limit)
        if next.isEmpty {
            lines.append("Nothing ready for \(assignee?.label ?? "anyone").")
            let blocked = TaskQueue.blocked(tasks: snapshot.tasks)
            if !blocked.isEmpty {
                lines.append("\(blocked.count) task(s) are blocked on dependencies.")
            }
        } else {
            lines.append("next for \(assignee?.label ?? "anyone"):")
            for (index, item) in next.enumerated() {
                lines.append("  \(index + 1). \(item.task.id) · \(item.task.title)")
                lines.append("     why: \(item.reason) · state: \(item.task.state.rawValue)")
                if let acceptance = item.task.acceptance {
                    lines.append("     done when: \(acceptance)")
                } else {
                    lines.append("     done when: NOT SPECIFIED — ask before assuming")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private func listProjects(_ args: [String: Any]) async throws -> String {
        let snapshot = try await client.list()
        let includeArchived = args["includeArchived"] as? Bool ?? false
        let projects = includeArchived ? snapshot.projects : snapshot.activeProjects
        guard !projects.isEmpty else { return "No projects tracked." }

        return projects.map { project in
            var line = "\(project.id) · \(project.name) · \(project.status.rawValue) — \(project.statusReason)"
            if let progress = project.progress { line += " · \(progress.summary)" }
            if let one = project.oneLiner { line += "\n    \(one)" }
            return line
        }.joined(separator: "\n")
    }

    private func listTasks(_ args: [String: Any]) async throws -> String {
        let snapshot = try await client.list()
        var tasks = snapshot.tasks
        if !(args["includeDone"] as? Bool ?? false) { tasks = tasks.filter { $0.state.isOpen } }
        if let projectId = args["projectId"] as? String { tasks = tasks.filter { $0.projectId == projectId } }
        if let state = args["state"] as? String, let parsed = TaskState(rawValue: state) {
            tasks = tasks.filter { $0.state == parsed }
        }
        if let assignee = args["assignee"] as? String {
            tasks = tasks.filter { $0.assignee == Assignee(encoded: assignee) }
        }
        guard !tasks.isEmpty else { return "No tasks match." }

        return tasks.map { task in
            var line = "\(task.id) · \(task.state.rawValue) · \(task.assignee.encoded) · \(task.title)"
            if let waiting = task.waiting { line += " · WAITING(\(waiting.rawValue))" }
            if !task.deps.isEmpty { line += " · deps: \(task.deps.joined(separator: ","))" }
            return line
        }.joined(separator: "\n")
    }

    private func getTask(_ args: [String: Any]) async throws -> String {
        guard let needle = args["taskId"] as? String else {
            throw TaskStoreError.notFound("(no taskId given)")
        }
        guard let task = taskStore.resolve(needle) else { throw TaskStoreError.notFound(needle) }
        let all = taskStore.load()

        var lines = [
            "id: \(task.id)",
            "title: \(task.title)",
            "state: \(task.state.rawValue)",
            "assignee: \(task.assignee.encoded)"
        ]
        if let project = task.projectId { lines.append("project: \(project)") }
        lines.append("acceptance: \(task.acceptance ?? "NOT SPECIFIED — ask before assuming")")
        if let waiting = task.waiting {
            lines.append("waiting: \(waiting.rawValue) — \(task.waitingReason ?? "")")
        }
        if !task.deps.isEmpty {
            let index = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            let described = task.deps.map { "\($0)(\(index[$0]?.state.rawValue ?? "missing"))" }
            lines.append("dependsOn: \(described.joined(separator: ", "))")
        }
        let blocks = all.filter { $0.deps.contains(task.id) && $0.state.isOpen }
        if !blocks.isEmpty { lines.append("blocks: \(blocks.map(\.id).joined(separator: ", "))") }
        if let claimed = task.claimedBy { lines.append("claimedBy: \(claimed)") }
        if !task.body.isEmpty { lines.append("\n\(task.body)") }
        return lines.joined(separator: "\n")
    }

    private func createTask(_ args: [String: Any]) async throws -> String {
        guard let title = args["title"] as? String, !title.isEmpty else {
            throw TaskStoreError.emptyTitle
        }
        let fields = EngineAction.CreateTask(
            title: title,
            projectId: args["projectId"] as? String,
            assignee: args["assignee"] as? String,
            body: args["body"] as? String,
            acceptance: args["acceptance"] as? String,
            deps: args["deps"] as? [String] ?? [],
            externalRef: args["externalRef"] as? String,
            origin: origin,
            state: args["state"] as? String
        )
        let result = try await client.act(.createTask(fields))
        let created = result.snapshot?.tasks.first { $0.title == title }

        var message = "Filed \(created?.id ?? title)."
        // Check the *stored* task rather than the arguments: a re-sync that omits
        // acceptance still has it, because upsert merges rather than replaces,
        // and warning about it then would send an agent to fix what isn't broken.
        if created?.acceptance?.isEmpty ?? true {
            // Not a refusal, but the omission that most reliably produces work
            // delivered wrong and rejected.
            message += " No acceptance criteria — add them with update_task before anyone starts."
        }
        return message
    }

    private func updateTask(_ args: [String: Any]) async throws -> String {
        guard let needle = args["taskId"] as? String,
              let task = taskStore.resolve(needle) else {
            throw TaskStoreError.notFound(args["taskId"] as? String ?? "(none)")
        }
        _ = try await client.act(.updateTask(.init(
            taskId: task.id,
            title: args["title"] as? String,
            state: args["state"] as? String,
            assignee: args["assignee"] as? String,
            acceptance: args["acceptance"] as? String,
            body: args["body"] as? String,
            deps: args["deps"] as? [String],
            waiting: args["waiting"] as? String,
            waitingReason: args["waitingReason"] as? String,
            projectId: args["projectId"] as? String
        )))
        return "Updated \(task.id)."
    }

    private func claimTask(_ args: [String: Any]) async throws -> String {
        guard let needle = args["taskId"] as? String,
              let task = taskStore.resolve(needle) else {
            throw TaskStoreError.notFound(args["taskId"] as? String ?? "(none)")
        }
        guard let owner = args["owner"] as? String, !owner.isEmpty else {
            throw TaskStoreError.notFound("(no owner given)")
        }
        _ = try await client.act(.claimTask(taskId: task.id, owner: owner))
        let minutes = Int(TaskQueue.leaseDuration / 60)
        return "Claimed \(task.id) for \(owner). The lease lasts \(minutes) minutes; "
             + "call complete_task when done, or update_task with `waiting` if you get stuck."
    }

    private func completeTask(_ args: [String: Any]) async throws -> String {
        guard let needle = args["taskId"] as? String,
              let task = taskStore.resolve(needle) else {
            throw TaskStoreError.notFound(args["taskId"] as? String ?? "(none)")
        }
        let result = try await client.act(.completeTask(taskId: task.id, note: args["note"] as? String))

        var message = "Completed \(task.id)."
        // Finishing usually frees something, and that is the moment the next
        // action is most obvious — so say it without being asked.
        if let snapshot = result.snapshot,
           let next = snapshot.whatNext(for: task.assignee, limit: 1).first {
            message += " Next for \(task.assignee.label): \(next.task.id) · \(next.task.title) (\(next.reason))."
        }
        return message
    }

    private func projectStatus(_ args: [String: Any]) async throws -> String {
        guard let needle = args["projectId"] as? String else { return "No projectId given." }
        let snapshot = try await client.list()
        let matches = snapshot.projects.filter {
            $0.id.hasPrefix(needle) || $0.name.lowercased().hasPrefix(needle.lowercased())
        }
        guard matches.count == 1, let project = matches.first else {
            return matches.isEmpty ? "No project matching \(needle)."
                                   : "\(needle) matches \(matches.count) projects."
        }

        var lines = [
            "project: \(project.id) · \(project.name)",
            "status: \(project.status.rawValue) — \(project.statusReason)"
        ]
        if let one = project.oneLiner { lines.append("oneLiner: \(one)") }
        if let progress = project.progress {
            lines.append("progress: \(progress.summary) from \(progress.source)")
        }
        if !project.briefs.meetsMinimum {
            lines.append("note: no PRODUCT.md — context for this project is scraped, not stated")
        }
        let open = project.openTasks
        lines.append("openTasks: \(open.count)")
        for task in open.prefix(10) {
            lines.append("  \(task.id) · \(task.state.rawValue) · \(task.title)")
        }
        if !project.sessions.isEmpty {
            lines.append("sessions: " + project.sessions.map { "\($0.status.rawValue)" }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Asking, not doing

    /// Files an approval request. The reply is written to be read by an agent
    /// that will otherwise try to find a way to proceed anyway: it says plainly
    /// that nothing started, that no self-approval exists, and what to do next.
    private func requestRun(_ args: [String: Any], kind: String) async throws -> String {
        guard let taskId = args["taskId"] as? String else { return "No taskId given." }
        guard let requestedBy = args["requestedBy"] as? String, !requestedBy.isEmpty else {
            return "No requestedBy given. Say who is asking — the human needs to know."
        }
        let delegate = (args["delegate"] as? String) ?? (args["agent"] as? String)
        let rationale = args["rationale"] as? String

        let result = try await client.act(.requestApproval(
            kind: kind, taskId: taskId, delegate: delegate,
            requestedBy: requestedBy, rationale: rationale))

        guard let request = result.approval else {
            return "The request was not filed."
        }

        var lines = ["filed \(request.id) — PENDING. Nothing has started."]
        lines.append("  \(request.summary)")
        for detail in request.details { lines.append("  \(detail)") }
        if request.rationale == nil {
            lines.append("  no rationale given — this will take the human longer to decide")
        }
        lines.append("")
        lines.append("The human decides this in their app. You cannot approve it yourself, "
                     + "and there is no tool that would let you.")
        lines.append("Do not wait on it. Pick up other work, and check list_my_requests later.")
        return lines.joined(separator: "\n")
    }

    private func listRequests(_ args: [String: Any]) async throws -> String {
        let snapshot = try await client.list()
        let requestedBy = args["requestedBy"] as? String
        let includeDecided = args["includeDecided"] as? Bool ?? true

        var requests = includeDecided ? snapshot.approvals : snapshot.pendingApprovals
        if let requestedBy { requests = requests.filter { $0.requestedBy == requestedBy } }
        guard !requests.isEmpty else { return "No requests." }

        return requests.prefix(20).map { request in
            var line = "\(request.id) · \(request.effectiveState().rawValue.uppercased()) · \(request.summary)"
            line += "\n    asked by \(request.requestedBy)"
            if let runId = request.runId { line += " · started \(runId)" }
            if let note = request.note { line += "\n    note: \(note)" }
            if request.effectiveState() == .expired {
                line += "\n    expired without a decision — ask again if it still matters"
            }
            if request.effectiveState() == .denied {
                line += "\n    declined — do not re-file this unchanged"
            }
            return line
        }.joined(separator: "\n")
    }

    private func listRuns(_ args: [String: Any]) async throws -> String {
        let limit = args["limit"] as? Int ?? 10
        let runs = try await client.list().runs
        guard !runs.isEmpty else { return "No runs yet." }

        return runs.prefix(limit).map { run in
            var line = "\(run.id) · \(run.state.rawValue)"
            if let code = run.exitCode { line += " · exit \(code)" }
            line += " · \(run.delegate)"
            if let note = run.note { line += " · \(note)" }
            return line + "\n    \(run.shortCommand)"
        }.joined(separator: "\n")
    }

}
