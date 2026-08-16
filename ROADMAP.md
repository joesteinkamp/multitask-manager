# Roadmap

This is the *what* and *why*. For the *how* — design decisions, build order, and
the things most likely to go wrong — see **[docs/PLAN.md](docs/PLAN.md)**.

## The problem

AI turned working on one thing into working on five. Every project now has
agents doing parts of it and me doing others, and the state of all of it is
spread across terminals, repos, and whatever tracker the project actually lives
in. **Staying on top of the work has become harder than the work.**

That's a multitasking problem, not an agent problem, and it doesn't get solved
by a better agent. It gets solved by something that holds the whole picture and
is always within reach.

## Where this is going

MultiTask Manager is a control plane for a **small set of projects I'm running
in parallel with my agents**. It lives in the menu bar and the task bar so it is
never more than a glance or a keystroke away, and it answers three questions
continuously:

- **What's happening?** Across every project — my work and my agents' alike.
- **What needs me?** Which session is blocked, on what, and for how long.
- **What should I do next?** Not merely what's stuck — what's ready to pick up.

The third question is the one that makes this a project manager rather than a
session monitor. **Work here belongs to two kinds of actor: me and my agents.**
A task is assigned to one or the other, and the app manages both queues.
Sessions are how it *observes*; projects and tasks are what it *manages*.

It's built directly on my harness
([`agent-global-instructions`](https://github.com/joesteinkamp/agent-global-instructions)),
which already decides *how* agents behave — instructions, guardrail hooks, the
cross-tool orchestration contract, model routing, memory, `/loop` autonomy. What
the harness has no place for is **seeing and driving all of it at once**.

### The North Star

**Agents answer their own prompts and move to the next task themselves**, and
this app is what hands them that next piece of work — escalating to me only when
a decision genuinely needs a human.

Two things follow from that, and they shape everything downstream. The board has
to be **addressable by agents**, not just by me, which is what the MCP server is
for. And it has to reflect **everything a project actually needs**, not only what
the app could infer from disk, which is what syncing from external trackers
(Linear and friends) is for.

### Surfaces

One engine, four faces:

| Surface | For |
|---|---|
| **Menu bar / task bar popover** (macOS shipped) | Ambient awareness — what's running, what's stuck, what's next. Always at hand; if reaching it costs a context switch, the app has failed. |
| **Main window** | The long-run view: every project, the task board, run history |
| **CLI** (`mtm`) | Scripting, hooks, and agents themselves reading/writing state |
| **MCP server** | Agents reading and updating the board directly — the surface the North Star runs on |

### Platforms

macOS and Windows get a native GUI; Linux is served by the CLI and desktop
notifications. See **[docs/CROSS-PLATFORM.md](docs/CROSS-PLATFORM.md)** for the
plan and the reasoning.

### The arc

**watch → understand → control → delegate → schedule**

Ending at: I describe an outcome, it gets broken into tasks, each task is routed
to me or to an agent, and the agent ones run autonomously — on a schedule, in
isolated worktrees, converging back — while I see the whole board at a glance.

### Lineage

This starts where `agent watch` did — knowing which sessions are live — and
keeps going: from sessions to projects, from projects to tasks, from watching to
driving. Tracking live sessions is the floor here, not the ceiling.

### Principles

- **Two kinds of actor.** Every piece of work is assignable to me or to an
  agent. Features that only make sense for one of the two are usually a sign of
  a wrong abstraction.
- **The harness is the source of truth for agent behaviour.** Read what it
  already writes (`~/.ai-logs/`, `~/.ai-context/`, `~/.ai/`, `ai/*` branches).
  Don't invent a parallel state store where one exists; contribute conventions
  upstream instead. Tasks are the exception and are owned here, because no
  harness file describes work that hasn't started.
- **Local, no inference.** File reads and process control. Briefings stay
  model-free. Nothing leaves the machine except through an integration I
  explicitly configure.
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

A popover, a window, a CLI, and a scheduler can't all sit on one SwiftUI view
model. Split the engine out before building on it, not after.

- [ ] **Extract a `MultiTaskCore` Swift package.**
      Move models, detectors, store, and the context reader out of the app
      target; the menu bar app becomes a thin client.
- [ ] **Run detection in a background daemon (`mtmd`).**
      One process owns detection and state, runs under `launchd`, and survives
      the app being closed — which is also what scheduled runs need later.
      Surfaces subscribe to it.
- [ ] **Define the local IPC contract.**
      JSON over a Unix socket at `~/.multitaskmanager/sock` — `list`, `get`,
      `subscribe` (streaming updates), `act` — with a versioned envelope from
      day one. Keeping it transport-agnostic is what leaves the door open if
      remote access ever earns its way back in.
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
- [ ] **Audit every control-plane action.**
      Once the app can launch and steer agents, what it did on my behalf goes to
      the audit log in the harness's own JSONL format, so `audit.sh` shows one
      start-to-finish timeline whether a run started from a terminal or from here.

---

## Phase 4 — Tasks

**This is the phase where the app becomes what it's actually for.** Everything
before it manages *sessions*, which are transient and belong to one tool. Here
the unit becomes a piece of work that outlives any session, belongs to a
project, and is assigned to me or to an agent. "What should I do next" only has
a real answer once this exists — before it, the app can tell me what's stuck but
not what's ready.

It's also where the North Star becomes reachable: an agent can only take the
next task itself once there is a next task to take, addressable from outside.

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
- [ ] **Answer "what should I do next" explicitly.**
      A ranked ready-list for *me*, not just an attention queue: tasks whose
      dependencies are met, weighted by project, staleness, and how long
      something has been blocked on me. The attention badge says I'm the
      bottleneck; this says what to do about it.
- [ ] **Open a real main window for the board.**
      The task graph, agent activity timeline, and run history across every
      project — the long-run view a menu bar popover structurally can't hold.
      Same app, same engine: the popover stays the ambient glance, the window is
      where I actually plan. Reachable from the popover and from `mtm open`.

### Making the board addressable

- [ ] **Expose an MCP server.**
      The surface the North Star runs on. Agents read the board, claim the next
      task, report progress, and close work out — without me relaying any of it.
      Same engine, same confirmation gates: an agent asking to do something I'd
      have to approve still stops and asks. Read-only tools first, per
      *observe before you control*.
- [ ] **Sync tasks from external trackers.**
      A project's real task list often already lives in Linear, GitHub Issues,
      or similar. Import them as tasks so the board reflects what a project
      actually needs rather than only what the app could infer from disk.
      One-way in by default, with the same show-me-the-diff rule that governs
      writing back to a repo file — a sync that silently rewrites someone's
      tracker is a bug, not a feature.

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

## Phase 6 — Hardening & distribution

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
- **No cloud service.** No accounts, no telemetry, no data leaving the machine
  on its own. Outbound integrations — a Linear sync, say — exist only where I
  explicitly configure one, and are opt-in per project.
- **Not a *team* project manager.** This manages a small set of projects that
  one person is running in parallel with their agents. Sprints, cross-team
  assignment, capacity planning, reporting — all out. Note the distinction from
  an earlier version of this line: personal project management is squarely *in*
  scope and is the point of Phase 4. Syncing *from* a team tracker is in too,
  because that is often where a project's real task list already lives.
- **No web app, no server.** *Considered, cut, briefly reconsidered, and cut
  again.* Its two jobs were the long-run view and reaching the board from a
  phone. The first is a window in the native app, not a second UI to keep in
  sync. The second isn't worth a self-hosted server and auth for a tool this
  personal. It was reopened in Aug 2026 as a way to reach three platforms with
  one UI, and rejected a second time on the interaction that matters most: the
  popover has to appear instantly and correct, dozens of times a day, and that
  is the thing a webview is worst at. The daemon's transport-agnostic IPC keeps
  remote access reversible if it ever earns its place.
- **Not a replacement for the harness.** The harness owns agent behavior and
  guardrails. Where this app needs new agent-side convention, that convention
  ships upstream in `agent-global-instructions`.
- **No AI in the briefing path.** Goal / Now / Next stay pure file reads —
  fast, private, and correct. Decomposing an outcome into tasks *is* inference,
  and is done by dispatching a delegate that writes task files, never by the app
  calling a model itself.
