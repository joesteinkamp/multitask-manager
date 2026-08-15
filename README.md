# MultiTask Manager

An **agentOS**: the control plane for the work you hand to AI agents. It turns a
pile of parallel sessions into one board you can see and drive — starting with the
thing you always need first, which agent has gone quiet and is waiting on you.

Today that ships as a lightweight macOS **menu bar** app. It auto-detects ongoing
sessions across Claude Code, Codex, the Claude/Codex desktop apps, and any folder
you're actively working in; figures out which project each belongs to; and flags
the ones that are **waiting on you**. Where it goes next — a CLI, a web app, and
agents you can launch and schedule rather than just watch — is in
[ROADMAP.md](ROADMAP.md).

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

v1 *watches* agent sessions. The direction is to **drive** them — one engine
behind three surfaces, built on top of a portable AI harness
([`agent-global-instructions`](https://github.com/joesteinkamp/agent-global-instructions))
that already owns how agents behave: instructions, guardrail hooks, the
cross-tool orchestration contract, model routing, memory, long-autonomy loops.
What it has no place for is seeing and steering all of it at once.

| Surface | For |
| --- | --- |
| **Menu bar** (shipped) | Ambient awareness — what's running, what's stuck, what's next |
| **CLI** (`mtm`) | Scripting and hooks; agents reading and writing state themselves |
| **Web app** | Remote control from a phone or another machine; the long-run view |

The arc is **watch → understand → control → delegate → schedule**, ending at:
describe an outcome, have it broken into tasks, route each to yourself or an
agent, and let the agent ones run autonomously — scheduled, isolated in their own
worktrees, converging back — while you watch the whole board.

Near-term work reads what the harness already writes to disk: the
`~/.ai-logs/tool-calls.jsonl` audit log as a real activity signal, `~/.ai-context/`
dirs as single orchestration waves instead of N unrelated rows, `ai/*` worktrees
and their converge conflicts, and the `~/.ai/` delegate roster. Full plan and
phases: **[ROADMAP.md](ROADMAP.md)**.

Everything stays local and inference-free; the harness stays the source of truth
(new agent-side conventions ship upstream there, not here); and confirmation
gates are inherited rather than reimplemented.

## How status works

Each session has a *last activity* timestamp (the modification time of its
transcript/log, or the newest edited file in a dev folder). Status is derived from
how long ago that was:

| Status | Meaning | Default timing |
| --- | --- | --- |
| 🟢 Working | recent activity | < "needs attention" window |
| 🟠 Needs attention | alive but quiet — likely waiting on you | ≥ 45s |
| ⚪️ Idle | long quiet / finished | ≥ 30m |

All thresholds and the refresh cadence are adjustable in **Settings → Status**.

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
MultiTaskManager/
├── MultiTaskManagerApp.swift     # @main, MenuBarExtra + Settings scenes
├── Models/                       # Session, SessionStatus, SessionSource, ProjectContext
├── Detection/                    # SessionDetector protocol + 5 detectors + ProjectContextReader
├── Store/                        # SessionStore (merge + heuristic), UserOverrides
├── Support/                      # Preferences, LaunchAtLogin
└── Views/                        # MenuContentView, SessionRowView (+ ProjectBriefView), SettingsView
```

Detectors conform to `SessionDetector` and are easy to add — implement `detect()`
and register it in `SessionStore.makeDetectors()`.

## Notes & limitations

- Desktop-app detection is app-level, not per-session; bundle ids vary across
  builds, so name-keyword matching is the fallback (configurable).
- Codex's on-disk layout has shifted across versions; the detector scans
  `~/.codex/sessions` recursively and degrades gracefully if the path is absent.
- Removing an auto-detected session hides it permanently; use **Restore** in the
  footer to bring hidden ones back.
