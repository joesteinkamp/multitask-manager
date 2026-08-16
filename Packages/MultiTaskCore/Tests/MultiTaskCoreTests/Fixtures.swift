import Foundation
@testable import MultiTaskCore

/// Samples captured from real files on a working machine, redacted and dated.
///
/// Every format in here belongs to somebody else — the Claude Code transcript
/// layout, the Codex rollout layout, the harness audit log, the orchestration
/// context dir, the routing table. All of them have changed at least once already.
/// Keeping dated captures means the next change shows up as a named failing test
/// instead of as a feature quietly going blank.
enum Fixtures {

    // MARK: Audit log — field shapes captured 2026-08-16 from ~/.ai-logs/tool-calls.jsonl

    /// Every audit fixture below keeps its captured *field shape* verbatim but has
    /// its timestamps normalised onto one coherent timeline, because the reader
    /// prunes sessions older than a week and the real captures span two months.
    /// Tests pin the clock to `auditNow` rather than to the wall clock, so they
    /// don't start failing a week after they were written.
    static let auditNow = ISO8601DateFormatter().date(from: "2026-08-15T10:05:00Z")!

    /// Two paired records from one Claude Code session. Note that `input` and
    /// `response` are present in the real file and are deliberately never decoded.
    static let auditClaudePair = """
    {"ts":"2026-08-15T10:00:46Z","tool":"claude","session":"f9f9b53d-1831-4798-966e-45eddd79dd68","cwd":"/home/user/projects/app","event":"PreToolUse","tool_name":"Bash","tool_use_id":"toolu_01NcpPv4zAk1DVEoeNqG9FZL","input":"{\\"command\\":\\"echo hi\\"}","response":null}
    {"ts":"2026-08-15T10:00:48Z","tool":"claude","session":"f9f9b53d-1831-4798-966e-45eddd79dd68","cwd":"/home/user/projects/app","event":"PostToolUse","tool_name":"Bash","tool_use_id":"toolu_01NcpPv4zAk1DVEoeNqG9FZL","input":"{\\"command\\":\\"echo hi\\"}","response":"hi"}
    """

    /// A real `SessionEnd`: `tool_use_id` and `response` are null, and the reason
    /// rides in `tool_name` rather than in a field of its own.
    static let auditSessionEnd = """
    {"ts":"2026-08-15T10:01:00Z","tool":"claude","session":"f9f9b53d-1831-4798-966e-45eddd79dd68","cwd":"/home/user","event":"SessionEnd","tool_name":"prompt_input_exit","tool_use_id":null,"input":"session ended: prompt_input_exit","response":null}
    """

    /// The record that reopens the session after it ended.
    static let auditResumed = """
    {"ts":"2026-08-15T10:02:00Z","tool":"claude","session":"f9f9b53d-1831-4798-966e-45eddd79dd68","cwd":"/home/user","event":"PreToolUse","tool_name":"Read","tool_use_id":"q","input":"{}","response":null}
    """

    /// Lower-camel event names appear under the `claude` harness alongside the
    /// capitalised ones — 529 of them in the 24,585-line local log — and Cursor uses
    /// a different vocabulary entirely. Both must count as activity.
    static let auditMixedCasing = """
    {"ts":"2026-08-15T10:00:00Z","tool":"claude","session":"aaaaaaaa-0000-0000-0000-000000000001","cwd":"/home/user/projects/app","event":"preToolUse","tool_name":"Read","tool_use_id":"x","input":"{}","response":null}
    {"ts":"2026-08-15T10:00:05Z","tool":"cursor","session":"bbbbbbbb-0000-0000-0000-000000000002","event":"beforeShellExecution","tool_name":"Shell","tool_use_id":null,"input":"{}","response":null}
    {"ts":"2026-08-15T10:00:09Z","tool":"codex","session":"019f5666-0439-7512-9ae4-32359db41fe8","cwd":"/home/user/projects/other","event":"PostToolUse","tool_name":"Edit","tool_use_id":"y","input":"{}","response":null}
    """

    /// What two concurrent appends look like when they interleave. Stock macOS has
    /// no `flock`, so `log-tool.sh` falls back to a plain append and this is a real
    /// possibility rather than a hypothetical one.
    static let auditInterleaved = """
    {"ts":"2026-08-15T10:00:00Z","tool":"claude","session":"aaaa{"ts":"2026-08-15T10:00:01Z","tool":"claude","session":"cccccccc-0000-0000-0000-000000000003","cwd":"/home/user/projects/app","event":"PreToolUse","tool_name":"Grep","tool_use_id":"z","input":"{}","response":null}
    """

    // MARK: Claude Code transcript — captured 2026-08-16

    static let claudeTranscript = """
    {"type":"user","cwd":"/home/user/projects/app","message":{"role":"user","content":"first prompt"}}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"working on it"}]}}
    {"type":"user","isMeta":true,"message":{"role":"user","content":"injected meta that must not surface"}}
    {"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"tool output"},{"type":"text","text":"add the audit reader"}]}}
    """

    /// Codex nests the message a level deeper under `payload`.
    static let codexTranscript = """
    {"payload":{"cwd":"/home/user/projects/other"},"type":"session_meta"}
    {"payload":{"role":"user","content":[{"type":"text","text":"refactor the store"}]}}
    """

    // MARK: Markdown docs

    static let readmeWithBadges = """
    # MultiTaskManager

    [![build](https://img.shields.io/badge/build-passing-green)](https://example.com)

    <!-- a comment -->

    A macOS menu-bar app that watches every AI coding session you have running and
    tells you which one is waiting on you.

    ## Install
    """

    static let roadmapWithTasks = """
    # Roadmap

    ## Phase 1
    - [x] Ship the popover
    - [ ] Notify when a session needs attention
    * [ ] Read the audit log
    + [ ] Render orchestration waves
    1. [ ] Discover worktrees
    2) [ ] Parse the delegate roster
    - [x] Already done
    """

    // MARK: ~/.ai roster — captured 2026-08-16

    static let clisFile = """
    codex
    agy
    claude
    agent
    """

    static let localModelsFile = """
    # name|backend|base_url|model|tier|tok/s
    qwen-local|ollama|http://127.0.0.1:11434|qwen3:32b|mid|42.5
    tiny|llamacpp|http://127.0.0.1:8080|phi-4|small
    """

    static let routingTable = """
    # Model routing — advisory reference

    - **Last updated:** 2026-07-24
    - **Method:** deep web research over current public benchmarks.

    ## Hard coding & refactoring
    *Multi-file implementation, debugging, agentic terminal work.*

    | Rank | CLI | Evidence |
    |------|-----|----------|
    | 1 (tie) | `claude` / `codex` | Independent boards split at the top. |
    | 3 | `agy` | Gemini 3.1 Pro + Gemini CLI 65.8% on TB2.1. |
    | — | `agent` | Vendor-reported only. |

    ## Code review & refutation

    | Rank | CLI | Evidence |
    |------|-----|----------|
    | — | no clear winner | Pick the strongest vendor that didn't author the work. |
    """

    // MARK: git plumbing — captured 2026-08-16

    static let worktreePorcelain = """
    worktree /home/user/projects/app
    HEAD 1111111111111111111111111111111111111111
    branch refs/heads/main

    worktree /home/user/projects/app-claude
    HEAD 2222222222222222222222222222222222222222
    branch refs/heads/ai/claude

    worktree /home/user/projects/app-codex
    HEAD 3333333333333333333333333333333333333333
    detached

    """
}

/// A throwaway directory that cleans itself up.
final class TempDir {
    let url: URL

    init() {
        url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mtm-tests-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func write(_ contents: String, to relativePath: String) -> URL {
        let target = url.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? contents.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    func append(_ contents: String, to relativePath: String) {
        let target = url.appendingPathComponent(relativePath)
        guard let handle = try? FileHandle(forWritingTo: target) else {
            write(contents, to: relativePath)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(contents.utf8))
    }

    @discardableResult
    func makeDirectory(_ relativePath: String) -> URL {
        let target = url.appendingPathComponent(relativePath, isDirectory: true)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    func setModificationDate(_ date: Date, of relativePath: String) {
        let target = url.appendingPathComponent(relativePath)
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: target.path)
    }

    func path(_ relativePath: String) -> String {
        url.appendingPathComponent(relativePath).path
    }
}

extension Configuration {
    /// Everything that reads the real home directory turned off, so a test only
    /// sees the detectors it injects. Without this, results would depend on what
    /// happened to be running on the machine.
    static var fixtureOnly: Configuration {
        Configuration(
            enableClaudeCode: false,
            enableCodex: false,
            enableRunningApps: false,
            enableDevFolders: false,
            enableHooks: false,
            enableAuditLog: false,
            enableWaves: false,
            enableWorktrees: false
        )
    }
}

extension Session {
    /// Compact constructor for tests — only the fields a given test cares about.
    static func stub(id: String,
                     project: String = "app",
                     path: String? = "/home/user/projects/app",
                     source: SessionSource = .claudeCode,
                     lastActivity: Date = Date(),
                     harnessSessionId: String? = nil,
                     hookStatus: SessionStatus? = nil,
                     waiting: WaitingReason? = nil,
                     evidence: StatusEvidence = .none,
                     status: SessionStatus = .unknown,
                     isPinned: Bool = false) -> Session {
        Session(id: id, title: project, projectName: project, projectPath: path,
                source: source, lastActivity: lastActivity,
                harnessSessionId: harnessSessionId, hookStatus: hookStatus,
                waiting: waiting, evidence: evidence, status: status, isPinned: isPinned)
    }
}
