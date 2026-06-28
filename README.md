# MultiTask Manager

A lightweight macOS **menu bar** app for keeping track of all the AI coding/agent
sessions you're juggling across projects — Claude Code, Codex, the Claude/Codex
desktop apps, and any folder you're actively working in. It auto-detects ongoing
sessions, figures out which project each belongs to, and — most importantly —
flags the ones that have **gone quiet and are waiting on you**.

> **Status:** v1. Built to be compiled and run on your own Mac (macOS 13+). The app
> is non-sandboxed and intended for personal/local use, not the Mac App Store.

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
