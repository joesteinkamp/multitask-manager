# Implementation plan

[ROADMAP.md](../ROADMAP.md) says *what* and *why*.
[CROSS-PLATFORM.md](CROSS-PLATFORM.md) says how it reaches Windows and Linux.
This says *how*: the design decisions, the order to build in, and the things
most likely to go wrong.

Each numbered item below is scoped to roughly one pull request — independently
shippable, with the app working at every step. Item numbers match roadmap
phases (P1.1 is the first item of Phase 1).

**Keep the destination in view while reading the early phases.** Phases 1–3 are
about sessions, which makes them look like a session monitor. They aren't the
product; they're how the app earns a trustworthy picture of what's happening.
The product is Phase 4 onward: work — mine and my agents' — tracked per project,
with a next action for each actor, reachable by agents through MCP. Every
decision in Phases 1–3 should be judged on whether it makes that easier, not on
whether it makes a better session list.

---

## Ground rules

These constrain every phase, so they're stated once.

1. **Never regress the fallback.** Every new signal is additive. A missing
   harness, a missing log, a renamed upstream path → fewer features, never a
   broken list. Concretely: each detector and reader returns "no data" rather
   than throwing, and status resolution always has the mtime heuristic at the
   bottom of the stack.
2. **The app calls no models.** Inference happens in delegates the app launches,
   never in the app itself. Where a phase seems to need reasoning (task
   decomposition, run summaries), the answer is to dispatch an agent and read
   its file output — see P4.2.
3. **Read-only until proven.** A capability ships as read-only first, and gains
   writes only after the read-only version has been in daily use.
4. **One writer per file.** Inherited from the harness orchestration contract.
   The app never writes into a context dir it didn't create, and never silently
   rewrites a repo file.
5. **Treat harness data as sensitive.** The audit log carries truncated tool
   inputs and responses — best-effort redacted, not guaranteed. Never re-log it,
   never copy it into app state that gets written elsewhere, never display it
   beyond what the user explicitly opens.

---

## Sequencing

```
P1 (independent, ship in any order) ─────────┐
                                             ├──> P3 ──> P4 ──> P5
P6.1 tests ──> P2 (core + daemon + IPC) ─────┘
P6.2-6.5 hardening: continuous
```

Two deliberate reorderings:

- **Pull P6.1 (tests) in front of P2.** Phase 2 moves nearly every file in the
  project. Doing that without tests on `ProjectContextReader` and
  `SessionStore.merge` is a blind rewrite — those two are the only places with
  real logic, and they have zero coverage today. Write the tests against the
  *current* code, then refactor until they pass again.
- **Spike P1.2's schema join before anything depends on it.** The audit log is
  the backbone of Phases 1, 3 and 5. Its record shape is now known (appendix A),
  but whether its `session` value matches the session ids the Claude Code and
  Codex detectors derive from transcript filenames is **unverified**. A
  half-day spike against a real `~/.ai-logs/tool-calls.jsonl` settles it. If the
  ids don't match, the join falls back to `cwd` → project path, which is
  coarser but always present — design for both from the start.

Within Phase 1, P1.1 (notifications) has no dependencies and delivers the
single biggest daily improvement. Start there.

---

## Phase 1 — Harness-native awareness

**Objective:** every signal the harness already writes to disk shows up in the
app, and the app tells you when you're the bottleneck. All read-only.

### P1.1 Notifications

`UNUserNotificationCenter`, fired on the *transition* into `needsAttention`.

- **Edge detection.** `SessionStore` keeps `previousStatus: [String:
  SessionStatus]` across refreshes and diffs after each merge. Only
  `working → needsAttention` and `unknown → needsAttention` fire. Entering
  `idle` never fires.
- **Debounce.** The mtime heuristic flaps: one slow tool call crosses the 45s
  threshold, the next write crosses back. Require the status to hold across two
  consecutive refreshes before notifying, and enforce a per-session cooldown
  (default 10 min) so one session can't repeat.
- **Coalesce.** If 3+ sessions cross within a 30s window, send one summary
  ("4 sessions need you") instead of a burst.
- **Mute + quiet hours.** Per-project mute lives in `UserOverrides` (persisted
  alongside hide/rename/pin); quiet hours is a `Preferences` time range.
- **Action.** One "Open" action routed to the existing `SessionStore.activate`.
  Requires a `UNUserNotificationCenterDelegate` installed at launch, before the
  first notification is scheduled.
- **Degrade.** If authorization is denied, the badge keeps working and Settings
  shows the denied state with a link to System Settings. Never silently no-op.

**Risk:** notification fatigue kills the feature's credibility on day one. The
debounce and cooldown defaults matter more than the plumbing — tune them against
a real day of use before considering this done.

**Done when:** a real session going quiet produces exactly one notification,
clicking it focuses the right session, and a chatty day produces no burst.

### P1.2 Audit log as the activity signal

Read `~/.ai-logs/tool-calls.jsonl` (path overridable by `AI_TOOL_LOG` — see
appendix A for the record shape and the environment caveat).

- **New type `AuditLogReader`** — an *enrichment source*, not a
  `SessionDetector`. It doesn't produce sessions; it annotates them, the way
  `ProjectContextReader` does.
- **Incremental tail.** Track `(deviceId, inode, offset)`. Each pass reads
  `offset → EOF`, parses whole lines only, and buffers any trailing partial
  line. If inode changes or size < offset, treat as rotation and reset. On first
  run, seek to the last 2 MB and discard the leading partial line rather than
  parsing history.
- **Tolerate corrupt lines.** The harness appends under `flock` where available,
  but *stock macOS has no `flock`* and falls back to a plain append — so
  parallel agents can interleave two records into one unparseable line. Skip
  malformed lines silently, count them, and surface the count in Settings as a
  health metric. Never abort the pass.
- **Index built per pass:** `session → {lastEventAt, lastToolName, eventCount,
  endedAt, cwd}`, plus a secondary `cwd → lastEventAt` index for the fallback
  join.
- **Status precedence,** highest first: hook status file → audit `SessionEnd`
  (definitively finished) → audit last-event age → transcript mtime. This makes
  "finished" a fact rather than an inference for the first time.
- **Never re-log.** Records contain redacted-but-sensitive tool input. Keep only
  the derived index in memory; drop `input`/`response` at parse time.

**Risk:** the `session` ↔ detector-session-id join is unproven. Mitigated by
the spike above and the `cwd` fallback.

**Done when:** a finished Claude Code session is marked finished within one
refresh of its `SessionEnd` record, and deleting the log leaves behavior
identical to today.

### P1.3 Orchestration waves

Render `~/.ai-context/<repo>-<task-slug>/` dirs as one unit instead of N
unrelated rows.

- **New model `Wave`**: id (dir name), title (first paragraph of `TASK.md`, via
  the existing `extractGoal`), progress (tail of `STATE.md`), delegates (one per
  `agents/*.md`), artifacts (files in `artifacts/`).
- **Delegate state from the contract:** the playbook has each delegate write its
  full output to `agents/<name>.md` when it finishes. So *file absent* = not
  started, *recently modified* = active, *stable* = done. No extra signal needed.
- **Wave → project mapping** is the fiddly part: the dir name is
  `<repo>-<task-slug>` and repo names contain dashes, so the split is ambiguous.
  Resolve by longest-prefix match against known project names, falling back to
  any repo path named inside `TASK.md`, then to showing the wave ungrouped.
- **Staleness.** These dirs are explicitly temporary. Anything untouched for
  more than 7 days collapses into a "past waves" disclosure, with a button that
  reveals it in Finder — the app never deletes them.
- **UI:** `MenuContentView` currently groups by project; waves become a second
  group kind rendered above loose sessions.

**Done when:** a four-delegate fan-out renders as one row with four children,
and its `STATE.md` progress line updates live.

### P1.4 Worktrees and converge conflicts

- **Discovery** per known project: `git worktree list --porcelain` and
  `git for-each-ref --format=… refs/heads/ai/*`.
- **Ahead/behind:** `git rev-list --left-right --count <integration>...<branch>`.
  Integration branch resolution: a local branch literally named `integration` if
  present, else the main worktree's current branch.
- **Conflicts:** glob `.converge-conflict-*` in the integration worktree root —
  written by `converge.sh` when a fold fails. A present marker is a
  `needsAttention` condition in its own right, independent of any session.
- **Cost control.** Shelling out to `git` per project on the 5s refresh is
  wasteful. Run this on its own slower cadence (30s default) and skip any repo
  whose `.git` directory mtime hasn't changed.
- **Execution hygiene:** `Process` with an absolute `git` path and argument
  arrays — never a shell string, never interpolated paths.

**Done when:** a stalled converge shows up as needing attention without opening
a terminal.

### P1.5 Delegate roster

- Parse `~/.ai/clis` (bare names, one per line), `~/.ai/local-models`
  (`name|backend|base_url|model|tier[|tok/s]`), and `~/.ai/model-routing.md`
  (front-matter line `- **Last updated:** YYYY-MM-DD`, then `##` sections with
  `Rank | CLI | Evidence` tables).
- **Health checks are slow** — `lm list` probes endpoints. Never on the refresh
  path: on demand, plus a 5-minute background cadence, with the last result
  cached and visibly timestamped.
- **Staleness note** when the routing table is older than ~2 months, matching
  what the orchestration playbook already asks for.
- Ships as a Settings pane + a compact popover footer. This is mostly
  informational now; Phase 4 consumes the same parsed data for routing, so build
  the parser to be reusable rather than view-local.

### P1.6 Hook status contract v2

Current file: `{projectPath, project, status, updatedAt}`. Add
`schemaVersion: 2`, `sessionId`, `reason` (short free text), and `waiting`
(`approval` | `question` | `done` | `error`).

- **Backward compatible:** absent `schemaVersion` parses exactly as today.
- `waiting` is what makes P3.5 triage possible — an approval gate genuinely
  outranks a finished run, and only the hook knows which it is.
- **Upstream work.** The matching hook snippets belong in
  `agent-global-instructions` so `install-hooks.sh` wires them, rather than
  living as copy-paste JSON in this README. That's a separate PR against a
  separate repo, and it should land *after* this app can read v2, so the two
  never disagree.

---

## Phase 2 — Extract the core

**Objective:** one engine, usable by the popover, a window, a CLI, and a
scheduler. Nothing user-visible ships in this phase — which is exactly why it
needs tests in front of it.

### P2.1 `MultiTaskCore` package

Local SwiftPM package at `Packages/MultiTaskCore`, referenced by the Xcode
project.

- **Moves:** `Models/`, `Detection/`, and the detection half of `Store/`.
- **The `SessionStore` split.** Today it's `@MainActor` + `ObservableObject` +
  `Timer` + merge logic in one type. Split into `DetectionEngine` (pure,
  UI-free, `async`, lives in core) and a thin `SessionStore` in the app that
  subscribes and republishes. The merge logic moves wholesale; the timer and
  `@Published` stay in the app.
- **The `Preferences` split.** Core needs configuration values but must not
  depend on `UserDefaults` or SwiftUI. Core defines a `Configuration` struct and
  a `ConfigurationProviding` protocol; the app keeps the `ObservableObject`
  `Preferences` and conforms it. The daemon gets a plist-backed conformance.
- **Sync `detect()` → `async`.** Detectors currently block on file I/O behind a
  `DispatchQueue`. Moving to structured concurrency lets detectors run in
  parallel and become individually cancellable, which matters once git shelling
  (P1.4) is in the mix.

**Risk:** this is the highest-churn, lowest-visible-value change in the plan.
Ship it in one PR with tests passing before and after, not incrementally across
several — a half-migrated tree is worse than either end state.

### P2.2 Daemon (`mtmd`)

Executable target in the package; LaunchAgent at
`~/Library/LaunchAgents/com.multitaskmanager.mtmd.plist` with `RunAtLoad` and
`KeepAlive`.

- **Why now:** detection should survive the popover closing, and Phase 5's
  scheduler needs a resident process. Both fall out of the same daemon.
- **Optional, always.** The app must work with no daemon installed. Define
  `EngineClient` with two conformances — `IPCClient` (talks to `mtmd`) and
  `InProcessEngine` (runs the engine itself) — and pick at launch. This keeps
  the daemon an optimization rather than a hard dependency, and keeps the app
  debuggable without one.

### P2.3 IPC contract

Unix domain socket at `~/.multitaskmanager/sock`, `0600` in a `0700` directory.

- **Framing:** newline-delimited JSON. It matches every other format in this
  ecosystem, and it's debuggable with `nc`.
- **Envelope:** `{v, id, type: req|res|event, method, params}`. The `v` is
  present from the first commit; the server rejects unknown majors with an error
  naming what it supports.
- **Methods:** `list`, `get`, `subscribe` (server-pushed events), `act`.
- **Transport implementation:** BSD sockets plus `DispatchSource` read sources.
  Network.framework can do unix sockets but adds surface for no gain here.
- **Security boundary is the filesystem** — same-user access via socket
  permissions, nothing more. That is adequate for a local socket and *only* for
  a local socket; the moment any network transport is considered, this needs
  real authentication. Written down so it isn't rediscovered later.
- **Transport-agnostic on purpose.** Keeping the method layer independent of the
  socket is what makes remote access a later adapter rather than a rewrite —
  the reason cutting the web app cost no architecture.

### P2.4 `mtm` CLI

Executable target using `swift-argument-parser`.

- **Commands:** `mtm status` (human), `mtm ls --json`, `mtm watch` (streams
  `subscribe`). Later phases add `open`, `task`, `run`.
- **`--json` output is an API,** consumed by hooks, scripts, and agents. Version
  it in the payload, document the shapes, and don't break them casually.
- **Install** via a "Install `mtm` command" button in Settings that symlinks
  from the app bundle into `/usr/local/bin` — the VS Code pattern. Shipping a
  separate installer for a personal tool isn't worth it.
- Building this immediately after P2.3 is the cheapest way to find out whether
  the IPC contract is actually usable.

---

## Phase 3 — Control

**Objective:** the app launches and steers agents instead of only watching them.
First phase with writes, so ground rules 3 and 4 start doing real work.

### P3.1 Launch a session from a project row

- **Templated invocations** per the orchestration playbook: `claude -p`,
  `codex exec --json`, `agy -p`, `agent -p`, `lm -p`. The default delegate comes
  from the roster and routing table parsed in P1.5.
- **The PATH problem.** A GUI app launched from Finder does not inherit the
  user's shell environment, so `claude` and `codex` won't be on `PATH` and
  `AI_TOOL_LOG` won't be set. Resolve once at startup by running the user's
  login shell (`$SHELL -l -c 'printenv'`), cache the result, and re-resolve if a
  launch fails with ENOENT. This bites every Mac app that shells out; handle it
  deliberately rather than discovering it in the field.
- **Output goes to files,** not an in-app terminal:
  `~/.multitaskmanager/runs/<run-id>/{stdout,stderr}.log`. The existing
  detectors then pick the session up like any other. For interactive work,
  offer "open in Terminal/iTerm" instead of pretending to be a terminal.
- **Every launch is gated** the way the harness gates them, and never uses
  `--dangerously-skip-permissions` or equivalent.

### P3.2 Provision isolation

One action that creates `../<repo>-<agent>` on `ai/<agent>`, seeds
`~/.ai-context/<repo>-<slug>/` with `TASK.md` and an empty `STATE.md`, and
launches delegates pointed at it.

- **Ownership marker.** Write `.mtm-owned` into context dirs the app creates.
  The app writes `TASK.md`/`STATE.md` only in dirs carrying that marker — so it
  can never fight an orchestrating session for the same file (ground rule 4).
- **Preflight** every git operation: existing branch, existing worktree, dirty
  tree, detached HEAD, not-a-repo. Report and stop; never force.

### P3.3 Converge control

Start/stop `converge.sh` against the integration tree as a managed child
process; show merged/conflicted state per branch. Locate the script in the repo
root or `~/.ai/`, and offer to write it if absent (it's short and the harness
documents its body). Surface conflicts, never resolve them.

### P3.4 Steer a running session

The riskiest item in the plan, and worth scoping honestly:

- **App-launched sessions:** full support. Own the pty at spawn (`forkpty`),
  keep the handle, and send input, interrupts, and gate answers directly.
- **Sessions started elsewhere:** best-effort only, via AppleScript into
  Terminal or iTerm, behind an off-by-default setting. Requires Automation
  permission and breaks when window/tab identification is ambiguous.
- **Everything else:** out of scope. There is no general mechanism to type into
  an arbitrary process's terminal, and pretending otherwise would produce a
  feature that works in demos and fails in use.

Ship the app-launched case first; treat the AppleScript path as a separate,
clearly-labeled experiment.

### P3.5 Attention triage

Rank waiting sessions rather than listing them: `waiting == approval` outranks
`question`, which outranks `done`, which outranks anything inferred from mtime.
Break ties by wait duration, with pinned projects weighted. Consumes the P1.6
hook field — which is why P1.6 comes first.

### P3.6 Audit control-plane actions

Once the app acts on your behalf, those actions belong in the same log as
everything else: append to `~/.ai-logs/tool-calls.jsonl` in the exact record
shape (appendix A) with `tool: "mtm"`, so `audit.sh` renders one start-to-finish
timeline regardless of whether a run started from a terminal or from the app.
Match the field names exactly — a near-miss produces records that parse but
don't display.

---

## Phase 4 — Tasks

**Objective:** the unit of work stops being a session and becomes a task that
outlives sessions and can be assigned to a person or an agent.

### P4.1 Task model and store

One markdown file per task at `~/.multitaskmanager/tasks/<id>.md`, YAML front
matter plus a body.

```yaml
---
id: 20260815-notify-on-attention
title: Notify when a session needs attention
project: /Users/joe/dev/multitask-manager
assignee: me            # or: claude | codex | agy | agent | lm
state: ready            # backlog | ready | running | review | done | blocked
deps: [20260815-audit-reader]
privacy: normal         # or: local-only  → forces an `lm` delegate
created: 2026-08-15T10:00:00Z
sessions: [abc123]
runs: [run-0007]
source: {file: ROADMAP.md, anchor: "sha256:…"}
---
The outcome, in prose. This body is what gets written into TASK.md when the
task is dispatched to a delegate.
```

- **Why files, not a database:** git-friendly, readable without the app,
  editable by the agents themselves with the tools they already have, and
  survives the app being uninstalled. Consistent with how the harness stores
  everything.
- **Single writer** is the daemon. External edits are picked up via an FSEvents
  watch on the tasks directory.
- **Cycle detection** on every dependency write; a cycle is rejected at write
  time, not discovered at scheduling time.

### P4.2 Decomposition — dispatched, not inferred

Ground rule 2 says the app calls no models, and breaking an outcome into tasks
obviously requires reasoning. The resolution is the same one the whole project
is built on: **the app orchestrates, the delegate thinks.**

"Break this down" dispatches a planning delegate (routed per P4.3) into a
context dir with the outcome as `TASK.md` and an instruction to write task files
to the tasks directory. The app then reads those files like any others. No model
call ever happens inside the app, the decomposition is reviewable as a diff
before acceptance, and the planning step is itself a run with a report.

### P4.3 Routing

Consume the parsed `~/.ai/model-routing.md` from P1.5: task type → ranked
vendors, advisory and overridable, with the choice always shown.

- **Privacy:** `privacy: local-only` forces an `lm` delegate and excludes cloud
  vendors entirely.
- **On "cost":** there is no reliable local source of per-call spend. Route by
  the routing table's tiers and be explicit in the UI that this is a tier
  heuristic, not dollars. Inventing a spend number would be worse than omitting
  one.

### P4.4 Cross-vendor review

When an agent task completes, automatically create a linked review task assigned
to a *different* vendor, prompted to refute rather than confirm — the harness
rule that a model is never the sole checker of its own work, made structural
instead of remembered. Disagreements surface as a diff between the two outputs;
the app never picks a winner.

### P4.5 Import roadmap checkboxes

Reuse `extractNextSteps` without the 3-item limit to import `- [ ]` items from
`ROADMAP.md` / `TODO.md` as tasks.

- **Identity** by content hash of the item text plus its file, so re-importing
  updates rather than duplicates.
- **One-way by default.** Completing a task in the app *offers* to tick the box
  in the repo file and shows the diff; it never rewrites a repo file silently
  (ground rule 4). Two-way sync between a task store and a hand-edited markdown
  file is a well-known source of lost edits — don't build it.

### P4.6 Board window

A real `Window` scene: task graph, agent activity timeline, run history across
every project.

- **Activation policy.** The app is `LSUIElement` (accessory) with no Dock icon.
  Opening a real window requires switching `NSApp.setActivationPolicy` to
  `.regular` while a window is open and back to `.accessory` when it closes,
  otherwise the window can't take focus properly. Small detail, easy to miss,
  visibly broken when wrong.
- The popover stays the ambient glance; the window is where planning happens.
  Reachable from the popover and from `mtm open`.

---

## Phase 5 — Autonomy and scheduling

**Objective:** agent-assigned tasks run without being started by hand, bounded
and reviewable.

### P5.1 Scheduling

The daemon is already resident, so it owns an internal scheduler; `launchd` only
guarantees the daemon is alive. Simpler than a plist per schedule and far more
flexible.

- Schedule spec per task or loop: interval or calendar.
- **A done-condition is mandatory at creation** — the roadmap principle enforced
  by the type system rather than by discipline. No unbounded loops, ever.

### P5.2 Autonomous queue

- Ready set = tasks whose dependencies are all `done`, ordered topologically.
- Concurrency caps, global and per-project.
- **Leases.** A runner claims a task with an expiring lease so two runners can't
  take the same one; on daemon start, expired leases are reclaimed and their
  tasks returned to `ready`. Without this, a crash mid-run strands tasks in
  `running` forever.
- One worktree per running agent task, per P3.2.

### P5.3 Budgets

Wall-clock, iteration count, and a spend proxy — with the same honesty as P4.3:
tier-and-duration, labeled as an estimate. Hard stop is SIGTERM, then SIGKILL
after a grace period, then a written reason in the run report. A run that dies
silently is worse than one that fails loudly.

### P5.4 Run reports

`~/.multitaskmanager/runs/<run-id>/report.md`, assembled from artifacts —
`git diff --stat`, the delegate's `agents/*.md`, `STATE.md`, exit status, budget
consumption. Assembled, not summarized: no inference (ground rule 2). The board
window aggregates them so eight overnight runs are legible in one screen.

### P5.5 Feed the memory loop

Append lessons to the memoryOS `LESSONS.md` by resolving `~/.ai/memory-os` the
way `hooks/memory-os.sh` already does — reuse the harness's resolution order
rather than reimplementing it, or the two will drift. Read `scorecards.jsonl`
for rating trends and display them. Read-only for scorecards; the survey stays
the human's.

---

## Phase 6 — Hardening and distribution

Continuous, not final. P6.1 in particular runs *before* Phase 2.

### P6.1 Tests

Swift Testing (or XCTest) against `MultiTaskCore`, with fixtures under
`Tests/Fixtures/`:

- `ProjectContextReader`: goal extraction across README shapes, the 240-char
  truncation, unchecked-task parsing across `-`/`*`/`+`/numbered forms, the
  160-char item truncation, transcript tail parsing for both Claude Code and
  Codex.
- `SessionStore.merge`: dedupe by id, hook-status precedence, hidden sessions,
  manual entries, rename/pin application, sort order.
- `AuditLogReader`: incremental offsets, rotation, and — importantly —
  interleaved/corrupt lines, since macOS's missing `flock` makes those real.

Fixtures are captured from real files, checked in, and dated, so an upstream
format change shows up as a failing test naming the version that broke.

### P6.2 CI

GitHub Actions on `macos-latest`: `swift test` for the package, `xcodebuild
-scheme MultiTaskManager build` for the app, `shellcheck` for any shipped shell.
Cheap, and the only thing that makes the Phase 2 refactor safe to review.

### P6.3 Format resilience

Detectors report a `degraded` state with a reason ("no sessions found at
`~/.codex/sessions`") that the UI shows, instead of returning an empty array
indistinguishable from "nothing running". Every upstream layout this app depends
on has already moved at least once; assume it will again.

### P6.4 Distribution

Developer ID signing, `notarytool` stapling, GitHub Releases, and a Sparkle
appcast for updates. Signing keys stay out of the repo, in the keychain and CI
secrets. Until this lands, "install" means Xcode, which caps the audience at one.

### P6.5 First-run setup

Detect the harness, offer to wire the P1.6 hooks, explain what the app can and
can't see, and request notification authorization in context rather than at
first launch — a permission prompt with a reason attached is far more likely to
be granted.

---

## Open questions

**1 and 2 are now settled** — the spike ran on 2026-08-16 against a real
35 MB `~/.ai-logs/tool-calls.jsonl` (24,585 records, 161 sessions, four
harnesses) and 97 real Claude Code transcripts.

1. ~~**Does the audit log's `session` match detector session ids?**~~
   **Yes — join precisely.** 95 of 97 Claude Code transcript ids (97.9%)
   appear verbatim as `session` values. The two misses are transcripts that
   predate the logging hook, not mismatches. `cwd` remains implemented as the
   fallback, but it is a fallback rather than the common path.
2. ~~**Does the Codex detector's session id survive its format changes?**~~
   **Yes, and better than expected.** The rollout filename
   (`rollout-<timestamp>-<uuid>.jsonl`) ends with exactly the uuid the log
   records: 3 of 3 local Codex sessions join. Both detectors now carry
   `harnessSessionId`, so the precise join covers both harnesses. Note the
   uuid must be matched on its 8-4-4-4-12 shape from the end, because the
   timestamp ahead of it also contains dashes.
3. **How much does the git shelling in P1.4 actually cost** across ~20 repos?
   Still open. Implemented on a 30s cadence with a `.git`-mtime skip, which
   should make the common case free; unmeasured at real repo counts.
4. **Is `forkpty` (P3.4) worth it,** or is "open in Terminal" enough in
   practice? Answerable only after using P3.1 for a week.
5. **Does the daemon earn its complexity** before Phase 5, or should P2.2 ship
   as in-process-only with the daemon deferred until scheduling needs it?
   Leaning deferred: `mtm` shipped against an in-process engine and needed
   nothing the daemon would have provided.

### What the real log taught us that this plan didn't say

Three things the appendix-A record shape didn't capture, all now handled:

- **Event names arrive in more than one casing, under the same harness.**
  `preToolUse`/`postToolUse` appear alongside `PreToolUse`/`PostToolUse` in
  529 records written by `claude`. Matching is case-insensitive over a known
  set.
- **Cursor uses a different vocabulary entirely** — `beforeShellExecution`,
  `afterFileEdit`. Rather than enumerate every harness's names, any
  unrecognised event still counts as activity: an unknown event still proves
  the agent was alive at that timestamp, which is the signal that matters.
- **`cwd` is absent from several hundred records** (557 `claude`, 31
  `cursor`), so the fallback index genuinely can miss. Appendix A says "most
  records", which is right; the reader must not assume otherwise.

Also worth recording: **zero of 24,585 lines were unparseable** on Linux,
where `flock` exists. The interleaving tolerance is still correct — it is a
macOS concern — but the malformed-line counter is the thing that will tell us
whether it ever actually bites, which is why it surfaces in Settings.

---

## Appendix A — Audit log record

Written by `hooks/log-tool.sh`. Path: `$AI_TOOL_LOG`, default
`~/.ai-logs/tool-calls.jsonl`.

```json
{"ts":"2026-08-15T12:00:00Z","tool":"claude","session":"abc123",
 "cwd":"/Users/joe/dev/app","event":"PreToolUse","tool_name":"Edit",
 "tool_use_id":"toolu_01…","input":"{…}","response":"{…}"}
```

- `tool` is the harness (`claude` | `codex` | `cursor` | `antigravity`), not the
  tool being called — `tool_name` is that.
- `event` carries `PreToolUse`, `PostToolUse`, `SessionEnd`, `PreCompact`, and
  `Scorecard` records, so the log spans a full session lifecycle.
- `cwd` is present on most records and is the reliable join to a project when
  session ids don't line up.
- `input` / `response` are truncated to 2000 chars and pattern-redacted —
  best-effort, not a guarantee. Sensitive (ground rule 5).
- **The file is not reliably line-atomic on macOS** (no `flock`), so parsers
  must tolerate interleaved lines.
- The app cannot read `$AI_TOOL_LOG` from its own environment when launched from
  Finder; resolve it via the login-shell environment snapshot from P3.1.

## Appendix B — Files this app reads and writes

| Path | Direction | Phase |
|---|---|---|
| `~/.claude/projects/**`, `~/.codex/**` | read | shipped |
| `~/.multitaskmanager/status/*.json` | read | shipped, extended P1.6 |
| `~/.ai-logs/tool-calls.jsonl` | read → append | P1.2 → P3.6 |
| `~/.ai-context/*/` | read → write (owned dirs only) | P1.3 → P3.2 |
| `~/.ai/clis`, `local-models`, `model-routing.md`, `memory-os` | read | P1.5 |
| `ai/*` branches, `../<repo>-<agent>`, `.converge-conflict-*` | read → write | P1.4 → P3.2 |
| `~/.multitaskmanager/sock` | write | P2.3 |
| `~/.multitaskmanager/tasks/*.md` | read/write | P4.1 |
| `~/.multitaskmanager/runs/<id>/` | write | P3.1, P5.4 |
| memoryOS `LESSONS.md`, `scorecards.jsonl` | append / read | P5.5 |
