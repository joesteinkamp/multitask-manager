# MultiTask Manager

**Stay on top of every project you're running in parallel with your AI agents.**

AI turned working on one thing into working on five. Each project has agents
doing parts of it and you doing others, and the state of all of it is scattered
across terminals, repos, and trackers. Staying on top of the work has become
harder than the work.

MultiTask Manager is a control plane for that small set of parallel projects. It
lives in your menu bar — always a glance or a keystroke away — and answers three
questions continuously: **what's happening**, **what needs you**, and **what you
should do next**. The work it tracks belongs to two kinds of actor, you and your
agents, and it manages both queues.

Today it ships as a lightweight macOS **menu bar** app that auto-detects ongoing
sessions across Claude Code, Codex, the Claude/Codex desktop apps, and any folder
you're actively working in; figures out which project each belongs to; and flags
the ones that are **waiting on you**. Sessions are how it observes — projects and
tasks are what it manages, and the task layer is where it's headed. Where it goes
next is in [ROADMAP.md](ROADMAP.md).

> **Status:** v1 shipped, and built to be compiled and run on your own Mac
> (macOS 13+). The app is non-sandboxed and intended for personal/local use, not
> the Mac App Store.

## What it does

- **Lives in the menu bar** (no Dock icon). The icon shows a badge with the number
  of sessions that need your attention.
- **Auto-detects sessions** from several sources (each can be toggled in Settings):
  - **Claude Code (CLI)** — reads `~/.claude/projects/**` transcripts; project name
    comes from each session's working directory.
  - **Codex (CLI)** — reads `~/.codex/**` rollout/session files.
  - **AI desktop apps** — Claude, ChatGPT, Cursor, etc. via running-app detection
    (matched by name keyword or bundle id; add your own in Settings → Apps).
  - **Dev folders** — watches folders you designate for recently-edited files and
    treats each top-level subfolder as a project.
- **"Needs attention" detection.** A session that hasn't shown activity for a
  configurable window is flagged as **waiting for you** (orange), versus actively
  **working** (green) or long-**idle** (gray). See *How status works* below.
- **Per-project briefings.** Expand any session row to see, at a glance:
  - **Goal** — what the project is for, read from its description docs.
  - **Now** — what the live session is working on this moment (its latest prompt).
  - **Next** — what to pick up when it's waiting on you (your roadmap/todo).

  This is assembled from plain files on disk — **no AI/inference** — so it's fast
  and private. See *Project briefings* below.
- **Manual control.** Add your own items, remove auto-detected ones (they stay
  removed), rename, and pin. All of this persists across relaunches.

## Where this is going

v1 *watches* sessions. The direction is to **manage the work** — yours and your
agents' — built on top of a portable AI harness
([`agent-global-instructions`](https://github.com/joesteinkamp/agent-global-instructions))
that already owns how agents behave: instructions, guardrail hooks, the
cross-tool orchestration contract, model routing, memory, long-autonomy loops.
What it has no place for is seeing and steering all of it at once.

**The North Star:** agents answer their own prompts and move to the next task
themselves, and this app is what hands them that next piece of work — escalating
to you only when a decision genuinely needs a human.

One engine, four surfaces:

| Surface | For |
| --- | --- |
| **Menu bar / task bar popover** (macOS shipped) | Ambient awareness — what's running, what's stuck, what's next. If reaching it costs a context switch, the app has failed. |
| **Main window** | The long-run view: every project, the task board, run history |
| **CLI** (`mtm`) | Scripting and hooks; agents reading and writing state themselves |
| **MCP server** | Agents reading and updating the board directly — the surface the North Star runs on |

Native GUIs on macOS and Windows; Linux is served by the CLI and desktop
notifications. Deliberately **no web app** — see
[Non-goals](ROADMAP.md#non-goals) and
[docs/CROSS-PLATFORM.md](docs/CROSS-PLATFORM.md) for the reasoning.

The arc is **watch → understand → control → delegate → schedule**, ending at:
describe an outcome, have it broken into tasks, route each to yourself or an
agent, and let the agent ones run autonomously — scheduled, isolated in their own
worktrees, converging back — while you watch the whole board.

It starts where a tool like `agent watch` did, knowing which sessions are live,
and keeps going: from sessions to projects, from projects to tasks, from
watching to driving.

Near-term work reads what the harness already writes to disk: the
`~/.ai-logs/tool-calls.jsonl` audit log as a real activity signal, `~/.ai-context/`
dirs as single orchestration waves instead of N unrelated rows, `ai/*` worktrees
and their converge conflicts, and the `~/.ai/` delegate roster.

Phases and rationale: **[ROADMAP.md](ROADMAP.md)**. Design decisions and build
order: **[docs/PLAN.md](docs/PLAN.md)**. Reaching Windows and Linux:
**[docs/CROSS-PLATFORM.md](docs/CROSS-PLATFORM.md)**.

Everything stays local and inference-free; the harness stays the source of truth
(new agent-side conventions ship upstream there, not here); and confirmation
gates are inherited rather than reimplemented.

## How status works

Each session has a *last activity* timestamp. Status is derived from how long ago
that was:

| Status | Meaning | Default timing |
| --- | --- | --- |
| 🟢 Working | recent activity | < "needs attention" window |
| 🟠 Needs attention | alive but quiet — likely waiting on you | ≥ 45s |
| ⚪️ Idle | long quiet / finished | ≥ 30m |

All thresholds and the refresh cadence are adjustable in **Settings → Status**.

Where that timestamp comes from is decided by precedence, strongest first. Each
step is optional; with none of them available the app behaves exactly as it did
when the transcript's modification time was the only signal.

1. **A hook status file** — the harness told us outright.
2. **A `SessionEnd` record in the harness audit log** — the run is definitively
   over. This is the one signal that makes "finished" a fact rather than an
   inference.
3. **The age of the session's last audit-log event** — the agent's own tool
   calls, which keep ticking through a long operation that never writes to the
   transcript.
4. **The transcript's modification time** — the original heuristic, still the
   floor.

Steps 2 and 3 read `~/.ai-logs/tool-calls.jsonl` (override with `$AI_TOOL_LOG`)
and join to a session by the harness's own session id. Run `mtm doctor` to see
how many of your sessions join precisely.

### Optional: precise signals via hooks

The timeout heuristic is the reliable default. If your environment allows Claude
Code / Codex **hooks**, you can get exact "waiting" signals that override the
timing. Drop a small JSON file into `~/.multitaskmanager/status/`:

```json
{ "projectPath": "/Users/you/dev/app", "project": "app",
  "status": "needsAttention", "updatedAt": 1719240000 }
```

For example, a Claude Code **Stop** hook (in `~/.claude/settings.json`) that marks
a project as waiting when the agent finishes:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command",
        "command": "mkdir -p ~/.multitaskmanager/status && f=~/.multitaskmanager/status/$(echo \"$CLAUDE_PROJECT_DIR\" | shasum | cut -d' ' -f1).json; printf '{\"projectPath\":\"%s\",\"status\":\"needsAttention\",\"updatedAt\":%s}' \"$CLAUDE_PROJECT_DIR\" \"$(date +%s)\" > \"$f\"" } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command",
        "command": "mkdir -p ~/.multitaskmanager/status && f=~/.multitaskmanager/status/$(echo \"$CLAUDE_PROJECT_DIR\" | shasum | cut -d' ' -f1).json; printf '{\"projectPath\":\"%s\",\"status\":\"working\",\"updatedAt\":%s}' \"$CLAUDE_PROJECT_DIR\" \"$(date +%s)\" > \"$f\"" } ] }
    ]
  }
}
```

The app reads these when the **Hook status files** detector is enabled. It works
fully without any hooks configured.

#### Contract v2

A record can say more, which is what makes triage possible — an approval gate
genuinely outranks a finished run, and only the hook knows which it is:

```json
{ "schemaVersion": 2,
  "projectPath": "/Users/you/dev/app", "project": "app",
  "sessionId": "f9f9b53d-1831-4798-966e-45eddd79dd68",
  "status": "needsAttention",
  "waiting": "approval",
  "reason": "Bash(rm -rf build/)",
  "updatedAt": 1719240000 }
```

- `waiting` is one of `approval`, `question`, `done`, `error`, and orders the
  attention queue.
- `reason` is short free text, shown on the row and used as the notification body.
- `sessionId` is the harness's own session id (for Claude Code, the transcript
  filename's uuid). Without it a hook can only address a *project*, so a project
  running two sessions gets its status attached to whichever was found first.

A record with no `schemaVersion` parses exactly as it always did, so there's no
rush to upgrade a working hook.

## Project briefings

The point of this app is to keep you in flow across many parallel projects, so each
session row can expand into a three-line briefing — answering "what is this, what's
happening, and what's next" without you opening the project. **It uses no model or
inference**; it just reads files that are already in your repo:

| Line | Where it comes from |
| --- | --- |
| 🎯 **Goal** | First real paragraph of the first of these that exists: `README.md`, `CLAUDE.md`, `AGENTS.md`, `PROJECT.md`, `PRODUCT.md`, `GOAL.md` |
| 〰️ **Now** | The most recent user prompt in the live session transcript (Claude Code / Codex). Reads only the tail of the file, so it's cheap |
| ➡️ **Next** | The first unchecked task(s) — `- [ ] …` — in `ROADMAP.md`, then `TODO.md` |

Notes:

- Reading is done on a background thread and **cached by file modification time**, so
  expanding a row and the periodic refresh stay snappy even with many projects.
- **Dev-folder** projects (no transcript) still show Goal and Next — handy for repos
  you're editing without an agent attached.
- Toggle the whole feature in **Settings → Detection → Project briefing**.
- Nothing is sent anywhere; it's all local file reads.

To get the most out of it, keep a one-line purpose near the top of your project's
README (or a dedicated `GOAL.md`) and track work as markdown checkboxes in
`ROADMAP.md` / `TODO.md`:

```markdown
## Roadmap
- [x] Ship v1 menu bar app
- [ ] Add per-project briefings   ← shown as "Next"
- [ ] Notarize and distribute
```

Because the parser is line-based and truncates each item at 160 characters, write
each task so its **first line stands on its own** and put the detail on
continuation lines. This repo's own [ROADMAP.md](ROADMAP.md) is written that way —
the app reads it like any other project.

## Build & run

1. Open `MultiTaskManager/MultiTaskManager.xcodeproj` in Xcode 15+ (macOS 13+).
2. Select the **MultiTaskManager** scheme and press **Run** (⌘R).
   - The project is set to sign **locally** (`CODE_SIGN_IDENTITY = "-"`). If Xcode
     prompts about signing, either keep "Sign to Run Locally" or pick your own
     Team under *Signing & Capabilities*.
3. A menu bar icon appears (no Dock icon). Click it to see your sessions.

### Permissions
The app is **non-sandboxed** on purpose — it reads `~/.claude`/`~/.codex`, scans
your designated dev folders, lists running apps, and can activate them. The first
time it reads files or controls another app, macOS may prompt for permission;
allow it.

## Project layout

```
Packages/MultiTaskCore/           # the engine — Foundation only, no SwiftUI/AppKit
├── Sources/MultiTaskCore/
│   ├── Models/                   # Session, SessionStatus, ProjectContext, UserOverrides
│   ├── Detection/                # SessionDetector + the file-based detectors
│   ├── Enrichment/               # AuditLogReader, WaveReader, WorktreeReader
│   ├── Roster/                   # ~/.ai delegate + routing-table parsers
│   ├── Engine/                   # DetectionEngine, Configuration, triage, notification policy
│   ├── Client/                   # EngineClient protocol + InProcessEngine
│   └── Wire/                     # daemon protocol: envelope, codec, frame reader
├── Sources/mtm/                  # the CLI
└── Tests/                        # 152 tests, incl. opt-in checks against real harness data

MultiTaskManager/                 # the macOS app
├── MultiTaskManagerApp.swift     # @main, MenuBarExtra + Settings scenes
├── Models/ Detection/ Store/     # ← still the app's own copies; see below
├── Support/                      # Preferences, LaunchAtLogin
└── Views/                        # MenuContentView, SessionRowView, SettingsView
```

The engine lives in `MultiTaskCore` so the popover, a window, `mtm` and a future
daemon can be faces of one implementation rather than four. Because the core
imports Foundation only, it builds and tests on Linux — which is what makes the
detection logic verifiable in CI on every push instead of only on a Mac.

**The app has not yet been migrated onto the package.** `MultiTaskManager/`
still contains its original copies of the models and detectors, and building the
app uses those. Moving it over means editing `project.pbxproj` to add the
package dependency and drop the duplicated files — a step that can only be
verified by compiling on a Mac, and one the implementation plan is explicit
should land in a single tested change rather than half-done.

Detectors conform to `SessionDetector` — implement `detect()` and register it in
`DetectionEngine.makeDetectors()`, or inject it when the detector needs AppKit
(as `RunningAppsDetector` does).

## The `mtm` CLI

The same engine, without the menu bar. Useful on its own, and the cheapest way to
check what the app can actually see on a given machine.

```
swift build --package-path Packages/MultiTaskCore -c release
```

| Command | What it shows |
| --- | --- |
| `mtm status` | what's waiting on you, in triage order |
| `mtm ls [--json]` | every tracked session; `--json` is a versioned API |
| `mtm watch` | streams status changes and notifications until interrupted |
| `mtm waves [--all]` | orchestration waves under `~/.ai-context` |
| `mtm roster` | delegates available, and how the routing table ranks them |
| `mtm doctor` | which signals are readable, and how many sessions join precisely |

`mtm ls --json` is meant to be consumed by hooks, scripts and agents, so it
carries a `payloadVersion` and its shape doesn't change casually.

`mtm watch` only prints when something you'd react to changes — a session
appearing or leaving, a status or wait-reason changing, a wave advancing, a
converge breaking. Activity timestamps drift on every tick and are deliberately
not treated as changes.

## One engine, several faces

Every face of this app talks to the same `EngineClient` interface rather than to
the detection engine directly:

```
        popover / window        mtm CLI
                  \               /
                   ▼             ▼
                  EngineClient (protocol)
                   │                    │
        InProcessEngine            IPCClient → mtmd  ← not built yet
                   │
            DetectionEngine
```

`InProcessEngine` runs detection in the calling process and is what everything
uses today. It owns three things the bare engine doesn't: the refresh loop, the
user's overrides, and the notification policy.

The notification policy lives there rather than in the UI because it is
*stateful* — its whole job is remembering what it already told you about — so
two evaluators would notify you twice about the same session. The engine
decides; the app delivers.

A daemon (`mtmd`) would be a second conformance behind the same interface, which
is what keeps it an optimisation rather than a dependency. It isn't built:
nothing about the CLI needed it, and the case for it rests on sharing stateful
readers between processes and on Phase 5's scheduler, neither of which exists
yet. The wire protocol it would speak — newline-delimited JSON, versioned
envelope, frame reader — is implemented and tested, so the remaining work is the
socket and the process lifecycle.

## Notes & limitations

- Desktop-app detection is app-level, not per-session; bundle ids vary across
  builds, so name-keyword matching is the fallback (configurable).
- Codex's on-disk layout has shifted across versions; the detector scans
  `~/.codex/sessions` recursively and degrades gracefully if the path is absent.
- Removing an auto-detected session hides it permanently; use **Restore** in the
  footer to bring hidden ones back.
