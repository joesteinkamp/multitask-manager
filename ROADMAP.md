# Roadmap

## Where this is going

MultiTask Manager starts as a menu bar app that *watches* agent sessions. It
becomes an **agentOS**: the control plane for the work I hand to agents, built
directly on top of my harness
([`agent-global-instructions`](https://github.com/joesteinkamp/agent-global-instructions)).

The harness already decides *how* agents behave — instructions, guardrail hooks,
the cross-tool orchestration contract, model routing, memory, `/loop` autonomy.
What it doesn't have is a place to **see and drive** all of it. That's this
project. Three surfaces over one engine:

| Surface | For |
|---|---|
| **Menu bar** (shipped) | Ambient awareness — what's running, what's stuck, what's next |
| **CLI** (`mtm`) | Scripting, hooks, and agents themselves reading/writing state |
| **Web app** | Remote control from a phone or another machine; the long-run view |

And the arc of capability:

**watch → understand → control → delegate → schedule**

Ending at: I describe an outcome, it gets broken into tasks, each task is routed
to me or to an agent, and the agent ones run autonomously — on a schedule, in
isolated worktrees, converging back — while I see the whole board at a glance.

### Principles

- **The harness is the source of truth.** Read what it already writes
  (`~/.ai-logs/`, `~/.ai-context/`, `~/.ai/`, `ai/*` branches). Don't invent a
  parallel state store where one exists; contribute conventions upstream instead.
- **Local, no inference.** File reads and process control. Briefings stay
  model-free. Nothing leaves the machine unless I explicitly wire it to.
- **Degrade gracefully.** Every signal is optional. Missing harness, missing
  hooks, missing CLIs → fewer features, never a broken app.
- **Confirmation gates are inherited, not reimplemented.** Anything the harness
  makes me approve, this app makes me approve too. Autonomy is bounded by an
  explicit done-condition, always.
- **Observe before you control.** A capability graduates from read-only to
  write-capable only after the read-only version has been in daily use.

---

## Phase 0 — v1: awareness (shipped)

- [x] Menu bar app, `MenuBarExtra`, no Dock icon, attention badge
- [x] Pluggable `SessionDetector` protocol with 5 detectors (Claude Code, Codex,
      running apps, dev folders, hook status files)
- [x] `SessionStore` merge pipeline + user overrides (add/remove/rename/pin)
- [x] Status heuristic: working / needs attention / idle, with hook override
- [x] Per-project briefings — Goal / Now / Next from plain file reads

---

## Phase 1 — Harness-native awareness

Everything here is **read-only** and reads artifacts the harness already
produces. Highest value per unit of risk; no new infrastructure.

- [ ] **Notify me when a session goes quiet and needs me.**
      `UNUserNotificationCenter` on the transition into needs-attention, with
      per-project mute and a quiet-hours window. The badge only works when I'm
      already looking at it — the whole point of the app is telling me when I'm
      the bottleneck.
- [ ] **Use the harness audit log as the activity signal, not file mtimes.**
      Read `~/.ai-logs/tool-calls.jsonl` (written by `log-tool.sh` on every tool
      event) for real per-session tool activity, harness/session id, and
      `SessionEnd` / `PreCompact` records — so "finished" stops being a guess.
      Tail incrementally by offset; never re-read the whole file.
- [ ] **Show an orchestration wave as one job, not N unrelated sessions.**
      Detect `~/.ai-context/<repo>-<task>/` dirs and render them first-class:
      `TASK.md` as the brief, `STATE.md` as live progress, one child row per
      `agents/<name>.md`, `artifacts/` as openable output.
- [ ] **Show parallel worktrees and flag stalled converges.**
      List `ai/*` branches and their sibling worktrees (`../<repo>-<agent>`) with
      ahead/behind against the integration branch, and surface
      `.converge-conflict-*` markers loudly — a blocked converge is exactly the
      "waiting on you" case this app exists to catch.
- [ ] **Know the delegate roster and its health.**
      Read `~/.ai/clis`, `~/.ai/local-models`, and `~/.ai/model-routing.md`;
      show which delegates are installed and reachable (`lm list` for local
      endpoints), and note when the routing table is stale (> ~2 months) the way
      the orchestration playbook asks.
- [ ] **Extend the hook status contract beyond working/needsAttention.**
      Add a short reason, the awaiting-input kind (approval gate vs. question
      vs. done), and a session id to `~/.multitaskmanager/status/*.json` so
      status attaches to a session rather than a whole project path. Ship the
      matching snippets upstream so `install-hooks.sh` wires them instead of me
      pasting JSON by hand.

---

## Phase 2 — Extract the core

Three surfaces can't sit on a SwiftUI view model. Split the engine out before
building the CLI and web app, not after.

- [ ] **Extract a `MultiTaskCore` Swift package.**
      Move models, detectors, store, and the context reader out of the app
      target; the menu bar app becomes a thin client.
- [ ] **Run detection in a background daemon (`mtmd`).**
      One process owns detection and state, runs under `launchd`, and survives
      the menu bar app being closed. Surfaces subscribe to it.
- [ ] **Define the local IPC contract.**
      JSON over a Unix socket at `~/.multitaskmanager/sock` — `list`, `get`,
      `subscribe` (streaming updates), `act` — with a versioned envelope from
      day one.
- [ ] **Ship the `mtm` CLI.**
      `mtm status`, `mtm ls --json`, `mtm watch`. Machine-readable output is the
      point: hooks, scripts, and agents are all callers. Also the fastest way to
      prove the IPC contract is right.

---

## Phase 3 — Control

Stop being read-only. The app launches and steers agents.

- [ ] **Launch a session straight from a project row.**
      Templated headless invocations following the orchestration playbook —
      `claude -p`, `codex exec --json`, `agy -p`, `agent -p`, `lm -p` — with the
      roster and routing table picking the default delegate.
- [ ] **Provision isolation in one click.**
      Create `../<repo>-<agent>` on `ai/<agent>`, seed
      `~/.ai-context/<repo>-<task>/` with `TASK.md` and an empty `STATE.md`, and
      launch delegates pointed at it, per the playbook's one-writer-per-file rule.
- [ ] **Manage the converge loop from the UI.**
      Start/stop `converge.sh` against the integration tree and show
      merged/conflicted state per branch — surfacing conflicts, never
      auto-resolving them.
- [ ] **Steer a running session without switching to its terminal.**
      Send input, interrupt, or answer a pending approval gate from the popover.
- [ ] **Triage attention when several sessions are waiting at once.**
      Rank by what's actually blocking — an approval gate outranks a run that
      merely finished.

---

## Phase 4 — Tasks

The unit stops being "a session" and becomes "a piece of work" — which may
outlive any one session, and may be mine or an agent's.

- [ ] **Add a task model and a plain-file task store.**
      Title, outcome, project, assignee (me | delegate), state, dependencies,
      provenance, and links to the sessions that worked it — under
      `~/.multitaskmanager/tasks/`, git-friendly and readable without the app.
- [ ] **Break an outcome down into a task graph.**
      Interactive decomposition with dependencies explicit, so independent tasks
      fan out in parallel and dependent ones queue behind.
- [ ] **Route each task to me or to a specific agent.**
      Consult `~/.ai/model-routing.md`, with cost and privacy (local-only work
      stays on `lm`) as inputs. Advisory, overridable, never silent.
- [ ] **Close the review loop with a different vendor.**
      A model is never the sole checker of its own work: a completed agent task
      opens a refutation review routed to another vendor, surfacing
      disagreements rather than picking a winner.
- [ ] **Import roadmap checkboxes as tasks.**
      The `ROADMAP.md` / `TODO.md` items the briefing already reads become real
      tasks — this file included.

---

## Phase 5 — Autonomy & scheduling

- [ ] **Schedule tasks and loops to run without me.**
      `launchd`-backed recurring runs — nightly maintenance, weekday morning
      sweeps, "keep this green until it merges" — each with an explicit
      done-condition, as `/loop` requires.
- [ ] **Drain an agent queue autonomously.**
      Agent-assigned tasks run without me starting each one: dependency-ordered,
      concurrency-capped, isolated per worktree.
- [ ] **Bound every autonomous run with a budget.**
      Wall-clock, iteration, and spend caps, with a hard stop and a report
      rather than an open-ended run.
- [ ] **Produce a reviewable report per run.**
      What ran, what changed, what it decided, what it wants from me — so
      waking up to eight completed runs is legible in one screen.
- [ ] **Feed outcomes back into the harness memory loop.**
      Route lessons into the memoryOS `LESSONS.md` and surface scorecard trends
      from `scorecards.jsonl`, so the system's own performance is visible over
      time.

---

## Phase 6 — Web app

- [ ] **Serve the same core contract over HTTP/WebSocket.**
      One engine, one API shape, three clients — the web adapter must not fork
      the model.
- [ ] **Build the board view.**
      The whole task graph, agent activity timeline, and run history — the
      long-run view a menu bar popover can't hold.
- [ ] **Make it usable remotely from my phone.**
      Bound to the tailnet by default, never the open internet: approve a gate,
      kick off a task, read a run report.
- [ ] **Authenticate and audit the control plane.**
      Even on a private tailnet — authenticated access, and every control-plane
      action written to the audit log.

---

## Phase 7 — Hardening & distribution

Ongoing, not last — pull items forward as the surface area grows.

- [ ] **Test the parsing and merge logic.**
      `ProjectContextReader` and `SessionStore.merge` are pure logic with zero
      coverage today, and they're exactly the code that breaks silently when an
      upstream on-disk format shifts.
- [ ] **Add CI.**
      GitHub Actions building the Xcode project and running tests on push, plus
      `shellcheck` on any shipped shell.
- [ ] **Make detectors resilient to upstream format changes.**
      Claude Code and Codex on-disk layouts move between versions: fixture-based
      parser tests, and a visible "detector degraded" state instead of a
      silently empty list.
- [ ] **Sign, notarize, and release a real build.**
      A downloadable app with a Sparkle-style update channel — not "open Xcode
      and press ⌘R".
- [ ] **Write a first-run setup flow.**
      Detect the harness, offer to wire the hooks, and explain what the app can
      and can't see.

---

## Non-goals

- **Not a coding agent.** It orchestrates agents; it doesn't write the code.
- **No cloud service.** No accounts, no telemetry, no data leaving the machine.
  The web app is self-hosted on my own network.
- **Not a replacement for the harness.** The harness owns agent behavior and
  guardrails. Where this app needs new agent-side convention, that convention
  ships upstream in `agent-global-instructions`.
- **Not a general project manager.** Jira-shaped features are out of scope. The
  task graph exists to route work to agents, not to track a team.
- **No AI in the briefing path.** Goal / Now / Next stay pure file reads —
  fast, private, and correct.
