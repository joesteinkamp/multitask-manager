# Change Log

Changes made to this project by AI models, newest first.

Each entry records four things: **what changed**, **the ask** that prompted it,
**why this approach**, and **what was considered and rejected**. Read top to
bottom, it should explain how the project got here — not just what its files
did.

---

## Make Windows CI mean something, and get one diagnosis badly wrong

*(2026-08-17, Claude)*

### What changed

Windows CI ran the full suite for the first time and failed ten tests. All ten
are resolved: four were real cross-platform bugs, one was a test that cannot run
on Windows, and the rest were flakiness. `main` is now green on Linux, Windows,
macOS, design tokens and shellcheck together.

The real fixes: the search path is found whatever the platform calls it
(Windows spells it `Path`, and Swift's environment dictionary is case-sensitive,
so *every* executable lookup silently failed there — delegates and git alike);
`WaveReader.pathTokens` recognises drive letters and UNC shares, without which a
brief written on Windows named no paths at all; the launcher records that it
cancelled a run instead of re-deriving it from `terminationReason`; and
`ProjectStore.save` reports write failures instead of discarding them with
`try?`.

### The ask

*"fix the windows bugs"*, after CI first surfaced them.

### Why this approach

**Adapt tests to the platform; skip only what genuinely cannot run.** The
launcher's spawn tests are about plumbing — redirection, pid capture,
termination handling — none of which is POSIX-specific, so they pick a shell per
platform and keep their coverage on both. The reconcile test asserts the
*documented* Windows behaviour, that it deliberately does nothing rather than
guess a run has ended, so it will fail loudly the day someone implements
liveness there. Only the staleness test is skipped, gated on a probed
capability, because it needs to backdate a directory's mtime and Windows will
not.

The line held throughout: skipping a test for a capability the product has not
decided yet is honest; skipping one for a capability we have decided and broken
is not.

**Cancellation became something the launcher knows rather than infers.** The
termination handler read `terminationReason` to decide whether a run had been
cancelled, and that does not mean the same thing on every platform — on Windows
a plain `exit 3` came back as `.uncaughtSignal`, so a failed run was filed as
cancelled. `cancel` is what sends the signal, so it records the fact before
signalling. Deriving something you already know is how platform differences turn
into wrong data.

### What was considered and rejected

**Implementing Windows process liveness now.** `reconcile` cannot test liveness
by pid there, so runs sit in `running` forever after a crash. That is the
Windows-client milestone, not a CI fix; filed in `ROADMAP.md` with the test that
will fail when it lands.

**Making the Windows job non-blocking until someone builds the Windows client.**
A red check everyone ignores is worse than no check.

**"Paths do not survive the round trip on Windows."** Adopted, acted on, and
wrong — see below.

### The mistake worth recording

Two Windows tests failed with missing files, and the theory was that `URL.path`
returns forward slashes on Windows and those strings break when fed back to path
APIs. A `nativePath` helper went in, every filesystem call was rewritten around
it, and the PR description explained it confidently.

CI disagreed twice over. Detection went from finding one session on Windows to
finding none, in a test that had passed before — the change *caused* a
regression. And both failures it claimed to fix passed on that same run, while
`ProjectStore.save` had never touched `nativePath` at all, so the change could
not have been what fixed them. They were flaky, not path bugs. The whole thing
was reverted.

The likely real cause was mundane: `TempDir` deleted its directory in `deinit`,
and ARC may release the object after its last *textual* use — so a test that
hands `dir.url` to a store and then reads a file back can have the tree removed
mid-test, on whichever platform's optimiser releases earliest. Fixtures now live
under one per-process root that is swept on first use.

A second diagnosis was wrong the same way: the staleness gate probed whether a
*file* could be backdated, which Windows does, when what the test needs is a
*directory*, which it does not. The evidence had been in the CI output all along
— the delegate files were correctly backdated to July and only the directory
read as now.

The pattern in both: asserting a cause from a plausible story instead of reading
what the log actually said. Every real step forward on this branch came from the
log, not from the theory.

**One failure remains unexplained.** "An approval consumed by an attempt that
failed stays pending" failed on Windows and then passed with no targeted fix.
The `TempDir` change is the plausible cause but was already in place for the run
where it failed, so it cannot be claimed. If it returns, `noWorkingDirectory`
now names whether the project is missing, pathless, or simply absent from the
snapshot.

---

## Make it do things — and split "agents can write" from "agents can spend"

*(2026-08-17, Claude)*

### What changed

The app stopped being read-only. Three gated actions land — run a task with a
delegate, cancel a run, provision an isolated worktree — with the launcher, run
store, shell-environment snapshot and audit writer behind them. Runs attach to
tasks, so the audit trail describes something somebody asked for rather than a
command that happened.

On top of that, an **approval queue**: agents file requests over MCP
(`request_run`, `request_isolation`) and only a person decides. The menu bar app
grew the surfaces for all of it — asks above everything, Approve and Decline on
the row, a run confirmation sheet, a runs section — and a new ask now notifies.

Also: `DESIGN.json` plus a generated Swift token file with CI enforcement,
`DESIGN.md`, and `CODE.md`. 152 tests to 334.

### The ask

*"Build the actual product!!! How many times do I have to tell you"*, then *"do
the task UI next and everything else!"*, then *"do phase 3 too"*. The plan had
been read, reconciled and re-planned enough; the instruction was to stop
reporting and start building.

### Why this approach

**The approval queue was not planned, and it is the entry's real subject.** The
MCP server needed write tools — *"MCP definitely needs write tools"* — and
writing them exposed a hole in the gate. The confirmation-token gate works
because the party that reads the description and the party that replays the
token is a person. Over MCP that assumption is simply false: an agent handed a
token calls again with it, and the gate becomes two round-trips of theatre.
Telling agents "show this to your human first" is a policy, and a policy is not
a mechanism.

So agents get a different verb. They **request**; only a person **decides**.
Approving is what mints the token, and it happens inside the engine, so the
token never reaches a caller. There is no MCP tool that decides, and a test
fails if one is ever added — including one that merely accepts a `confirm`
argument.

This is the foundation the North Star needs rather than a detour from it. Agents
answering their own prompts and moving to the next task requires them to be able
to *propose* their next step; it does not require them to be able to spend
without asking. Phase 5's standing authority now has something to be built on
top of instead of instead of.

**Design tokens got a generator, not a document.** The UI written earlier in the
session had invented its own spacing — gaps at 1, 2, 3, 4, 6, 8, 10, 12 and 22,
and `Color.orange` written out in four files — because the `DESIGN.md` the
project's own rules point at did not exist. Two hand-maintained constant files
do not drift dramatically; they drift by two points of padding and one shade of
orange, which nobody notices until the macOS and Windows apps sit side by side
and both have shipped. `DESIGN.json` is the source, the Swift file is generated,
and CI fails on divergence.

**Semantic system fonts and system colours, not a custom palette.** Both look
like shortcuts and are not. The semantic fonts follow the user's accessibility
text size, which a menu bar utility pinned to 11pt does not; system colours
already satisfy contrast in both appearances and already respond to Increase
Contrast and the colour-blind accommodations, none of which a hand-picked hex
re-earns for free.

### What was considered and rejected

**Returning the confirmation token to the agent with instructions to ask its
human first.** The obvious cheap answer, and it relies entirely on the agent's
goodwill. Rejected: the gate would be enforced by a sentence in a tool
description.

**A pre-approved allowlist of safe commands instead of an ask.** That is Phase
5's standing authority arriving early, and it should sit on top of a working ask
rather than replace one — otherwise the first version of the feature is the
version with no audit trail.

**A separate approvals daemon.** Nothing needs a second process yet, and the
daemon is already sequenced for when the Windows client makes it unavoidable.

**Forcing a reason on every decline.** Rejected for the same reason acceptance
criteria are prompted rather than required: a queue that demands a sentence
before it will clear is a queue that stops getting cleared.

**Giving Approve the Return key.** Written, then removed one commit later after
arguing in the run sheet that a stray Return must never spend. A popover appears
under whatever you were already typing into.

**Opening the popover from a notification.** `MenuBarExtra` exposes no supported
way to present its own window, and the unsupported routes trade a working menu
bar for one click. A first draft set a `wantsPopover` flag nothing observed,
which is worse than the limitation because it looks like it works.

**Squashing the branch on merge.** The repository merges PRs with merge commits,
and these commit messages carry the reasoning this log exists to preserve.

### Bugs worth recording

Each was found by building rather than by reading, and each is a design lesson:

- **The gate could never be passed.** The token was a freshly minted run id, so
  it differed between the describe pass and the do pass. Every confirmed run was
  silently refused and the CLI exited 0 saying nothing — while the whole suite
  stayed green, because the tests only covered refusal, which is what a broken
  gate does perfectly. Tokens now derive from the request, which makes them
  stable *and* bound: approving one run cannot authorise another.
- **`confirm == "yes"` was a literal that always passed**, in both gated paths.
- **`Process.isRunning` and `waitUntilExit()` are unreliable on Linux.** After
  `terminate()` the handler fires at once with status 15, yet `isRunning` still
  answers `true` seconds later and `waitUntilExit` blocks for the child's full
  original lifetime — a `sleep 30` killed at 200ms held the caller 30 seconds.
  Everything waits on the handler now; the suite went from 31s to 4.4s.
- **A discarded `Process` left a zombie** the OS reported as alive forever, so
  runs never closed out.
- **Tests wrote to the real `~/.multitaskmanager`.** 378 fixture decisions ("Do
  a thing", "Vague work") had accumulated in a live home and would have appeared
  in the app's own feed. Stores now resolve to a per-process temp root under a
  test bundle — a mechanism, rather than a convention every test must remember.
- **`mtm projects add <directory>` discarded the path**, saved a project named
  after it with no checkout, and explained that it was "an idea, not a checkout".

### Two things that came in from elsewhere

**Another session's work landed on `main` mid-flight.** PR #3 built the same
Phase 1 features — notifications, audit-log activity — inside the *app target*,
while this branch had moved that logic into `MultiTaskCore` and deleted the app
copies. Eleven files conflicted. Resolved toward the core, per `AGENTS.md`'s
"Foundation only … not negotiable": the app-target implementation cannot build
on Linux or Windows, so keeping it would have forfeited CI and the Windows
client both. Only one thing was genuinely missing from this side and was ported
— a list of muted projects in Settings, since muting happens on a project's row
and a muted project is by definition one you have stopped looking at.

**CI had never actually run.** The workflow arrived on this branch, and its
first run earned its keep immediately: a test target that could not compile on
the Swift version the package declares, a design-token check that could not run
inside its own container, a macOS job that had been reporting "skipped" rather
than passing, and — once Windows got far enough to execute anything — the
cross-platform bugs above. `swift build` had stayed green throughout, because
build never compiles the test target.

---

## Restate what the project is for: parallel projects, two kinds of actor

*(2026-08-16, Claude)*

### What changed

`ROADMAP.md`, `README.md`, `docs/PLAN.md` and `docs/CROSS-PLATFORM.md` now tell
one story instead of four. The framing moves from "a control plane for the work
I hand to agents" to **a control plane for a small set of projects run in
parallel by one person and their agents**, and the docs say so consistently.

Concretely: a new problem statement (AI turned working on one thing into working
on five; staying on top of the work has become harder than the work); three
standing questions the app answers, of which "what should I do next" is now
first-class rather than a side effect of "what's blocked"; an explicit North
Star; the MCP server added as a fourth surface; external tracker sync added to
Phase 4; the cross-platform direction reconciled into the roadmap; and two
non-goals rewritten.

### The ask

Two corrections in one conversation. First, that `ROADMAP.md` and
`docs/CROSS-PLATFORM.md` disagreed about whether this is a Mac app or a
multi-platform one. Second, and more fundamental: *"you don't really understand
it's not simply for managing agents — it's for managing for humans and AI
agents."*

### Why this approach

**The second correction is the load-bearing one, and it changes what the early
phases are for.** The unit of work is not the session. Sessions are how the app
*observes*; projects and tasks are what it *manages*. Written the old way, every
feature decision in Phases 1–3 was being judged on whether it made a better
session list — which is how the app quietly becomes a session monitor with
ambitions. `docs/PLAN.md` now opens by saying Phases 1–3 exist to earn a
trustworthy picture, and that the product starts at Phase 4.

**"Two kinds of actor" is stated as a principle** because it is the test that
catches the wrong abstraction early: a feature that only makes sense for a human
or only for an agent is usually modelling the wrong thing.

**The North Star is written down as a destination rather than a phase**, because
two long-lead decisions hang off it. Agents answering their own prompts and
taking the next task requires the board to be addressable *by agents* — hence
MCP as a surface, not a plugin — and requires the board to reflect what a
project actually needs rather than what the app could infer from disk — hence
syncing from Linear and similar.

**The lineage is named.** This starts where `agent watch` did, tracking live
sessions, and that is recorded as the floor rather than the ceiling.

### Considered and rejected

**Keeping "agentOS" as the headline framing.** Dropped. It is a good phrase but
it points at the wrong half of the product: the correction was explicitly that
this is not simply for managing agents. It survives as the direction, not as the
definition.

**Leaving `docs/CROSS-PLATFORM.md` marked as a proposal** rather than reconciling
it into the roadmap. Rejected on instruction — cross-platform is desired, so the
roadmap now states it and the non-goals that assumed a single Mac were rewritten
rather than left to contradict it.

**Softening "not a general project manager" by deleting it.** Rejected in favour
of narrowing it to *"not a **team** project manager"*, with a note that the line
changed. Personal project management is now squarely in scope and is the point
of Phase 4; what stays out is sprints, cross-team assignment and reporting. The
distinction matters enough to leave a trail rather than quietly reverse.

**Re-recording the web app as merely "cut".** Rejected. The non-goal now records
that it was cut, reconsidered in Aug 2026 as a way to reach three platforms with
one UI, and cut again on the interaction that matters most — the popover has to
appear instantly and correct, dozens of times a day, which is what a webview is
worst at. A decision reopened and re-closed should show both, or the next reader
reopens it a third time.

---

## Put every face of the app behind one engine interface, and build the daemon's message layer

*(2026-08-16, Claude)*

### What changed

New `Client/` and `Wire/` directories in `MultiTaskCore`.

`EngineClient` is now the single interface the popover and the CLI both talk
to — `list`, `get`, `health`, `subscribe`, `act`. `InProcessEngine` is the
conformance in use: it runs detection in the calling process and owns the three
things a bare `DetectionEngine` doesn't — the refresh loop, the user's
overrides, and the notification policy.

`Wire/` holds what a daemon would speak: a versioned envelope that rejects an
unknown major by name, a codec, and a frame reader. No socket, no daemon
process.

`mtm` now goes through `EngineClient` instead of reaching for `DetectionEngine`
directly, and gains `mtm watch`, which streams changes and notifications.
`EngineSnapshot` grew an `AuditSummary` so a client can report health without
running a second audit-log reader of its own.

Two bugs, both found by running `watch` rather than by testing it:

- Its output vanished entirely when piped or redirected. stdout is
  block-buffered to a non-TTY, and a command that only ever ends by being
  interrupted never flushes. Now line-buffered.
- Snapshots were pushed on every tick despite a "suppress identical" guard,
  because `lastActivity` drifts constantly and plain equality therefore always
  reported a change. Replaced with a change digest. Verified live: one push in
  22 seconds where there had been four.

### The ask

"Do step one now" — the first of three steps proposed for the daemon and IPC
work (P2.2, P2.3): define the interface, ship the in-process conformance, and
build the message layer, holding the socket and the resident process until
something needs them.

### Why this approach

**The interface comes first because that's what keeps the daemon optional.**
With `EngineClient` in place, a daemon is a second conformance rather than a
dependency — and a machine with no `mtmd`, or one whose daemon just died, loses
the shared-state and cold-start benefits without losing the feature. Building
the daemon first would have inverted that: the interface would have been
shaped by the socket instead of the other way round.

**The notification policy moved into the engine because it is stateful.** Its
whole job is remembering what it has already told you about, so two evaluators
would notify twice about the same session. The engine decides; the app
delivers. This also settles a question the plan never addressed, and it is what
makes always-on notification possible once a daemon exists.

**The wire layer is transport-free so every case is testable without a file
descriptor** — partial frames, byte-at-a-time delivery, multi-byte characters
split across reads, oversized frames, and resync after one is dropped. These
are exactly the cases that are miserable to debug against a live socket and
trivial to pin down against a byte buffer.

**`act` covers only the override mutations the app already performs.** Phase
3's launch and steer actions are deliberately absent, with a note where they
will go: their confirmation gates belong behind the action handling, not in the
UI that calls it, or the engine becomes a way around the gate.

**Subscribers are woken by a change digest, not by snapshot equality.** A
client renders "3m ago" from the `lastActivity` it already holds and needs no
new snapshot for its clock to move. What it genuinely needs to hear about is a
session appearing or leaving, a status or wait reason changing, a wave
advancing, or a converge breaking.

### Considered and rejected

**Network.framework for the transport.** Rejected — and this replaces the
reasoning in the implementation plan, which called it "surface for no gain."
That undersells it: `NWListener` would genuinely handle framing and
backpressure. The decisive problem is that it is Darwin-only, and this
package's whole value is that it builds and tests on Linux in CI. A transport
written against it could only be tested on the scarce macOS runner. POSIX
sockets keep the framing tests running on every push, which is worth more than
the framing help.

**Building the socket and the daemon in this step.** Rejected, consistent with
the previous entry's finding that the CLI needed neither. This step refines
rather than reverses that call: the message layer is worth having now because
it is what the interface is designed against, while the resident process still
waits on a second concurrent consumer or Phase 5's scheduler.

**Diff-based subscription events.** Rejected in favour of whole snapshots plus
the change digest. A snapshot here is tens of sessions, so the bandwidth
argument is theoretical, while a subtly wrong diff shows a stale list — the
exact failure this app exists to prevent. Worth revisiting only if a real
workload complains.

**Registering subscribers lazily so `subscribe()` could stay synchronous.**
Rejected in favour of replaying the latest snapshot to a new subscriber
immediately. It removes a race from the tests and means a newly-opened popover
draws at once instead of waiting a full refresh cadence.

---

## Extract the detection engine into MultiTaskCore, and read the harness audit log

*(2026-08-16, Claude)*

### What changed

New `Packages/MultiTaskCore`, a Foundation-only Swift package holding the
models, detectors, merge logic, and the Phase 1 signals from `docs/PLAN.md`,
covered by 113 tests. Adds an `mtm` CLI, GitHub Actions CI, hook status contract
v2, and doc updates to `README.md` and `docs/PLAN.md`.

Covers plan items P6.1 (tests), P2.1 (core extraction), P1.1–P1.6, P3.5
(triage), P2.4 (CLI) and P6.2 (CI). The macOS app is deliberately untouched and
still builds against its own copies of the moved files.

The largest functional change: status is no longer inferred from a transcript
going quiet. It resolves by precedence — hook status file, then the audit log's
`SessionEnd` record, then the age of the last audit event, then transcript
mtime as the floor. The second step makes "finished" a fact rather than a
guess for the first time.

### The ask

"Run the plan" — execute `docs/PLAN.md`, the six-phase implementation plan
committed the day before.

### Why this approach

**Tests and the spike came first because the plan says so, and both earned it.**
The plan pulls P6.1 ahead of Phase 2 on the grounds that refactoring
`ProjectContextReader` and the merge logic without tests is a blind rewrite, and
it asks for a spike on the audit-log join before anything depends on it. Both
paid off immediately: the spike settled two open questions with real data, and
the first test written against `extractGoal` found a bug where a README opening
with a code fence presented those shell commands as the project's goal.

**The core imports Foundation only — no SwiftUI, no AppKit.** This was the
load-bearing decision. It means the package builds and tests on Linux, which is
the only reason this work could be verified rather than written blind for a
platform not present. It also means CI can check the detection logic on every
push in under a minute instead of waiting on a scarce macOS runner, and it
forced genuinely better boundaries: `SessionStatus.color` had to leave the model
layer, `NSString` path bridging had to become explicit helpers, and
`SessionStore` had to split into a pure `DetectionEngine` and a thin observable
wrapper — exactly the split P2.1 wanted, arrived at by constraint rather than
by discipline.

**The join is on the harness's own session id, not on `cwd`.** The spike found
the audit log's `session` value matches 95 of 97 local Claude Code transcript
ids, and every Codex rollout filename ends with the same uuid the log records.
Both detectors now carry `harnessSessionId`. `cwd` stays implemented as the
fallback, but it is a fallback rather than the common path — which matters,
because `cwd` cannot distinguish two sessions running in one project, and that
ambiguity is precisely what hook contract v2's `sessionId` field exists to fix.

**Unrecognised audit events count as activity rather than being ignored.** The
real log writes event names in two casings under the same harness, and Cursor
uses a different vocabulary entirely. Enumerating every harness's spellings is
a losing game; an unknown event still proves the agent was alive at that
timestamp, which is the signal that actually matters.

**The notification rules are a pure, testable policy object rather than logic
inside the notification plumbing.** The plumbing is the easy part. What decides
whether the feature is kept or muted on day one is the debounce, cooldown and
coalescing defaults, and those only get tuned if they can be tested.

### Considered and rejected

**Migrating the macOS app onto the package in the same change.** Rejected. It
requires editing `project.pbxproj`, which cannot be compiled or verified from a
Linux box, and the plan is explicit that a half-migrated tree is worse than
either end state. The cost is that the core is additive and correct but is not
yet what the app runs; the benefit is that nothing regressed and the migration
can land as one reviewable, compiled change.

**Building the daemon and IPC (P2.2, P2.3) before the CLI.** Rejected, and the
rejection turned into evidence. `mtm` was built against an in-process engine and
wanted nothing the daemon or socket layer would have provided — recorded against
the plan's fifth open question as an argument for deferring both until Phase 5's
scheduler needs a resident process.

**Swift 6 strict concurrency for the package.** Rejected for now in favour of
`swiftLanguageMode(.v5)`, matching what the existing app code assumes. Adopting
Swift 6 mode is a separate change that should move the app and the package
together, not one that silently diverges them.

**Checked-in fixture files loaded as SwiftPM resources.** Rejected in favour of
dated string constants in `Fixtures.swift`. Same goal — a captured, dated sample
so an upstream format change fails a named test — without the resource-bundle
plumbing. Their timestamps are normalised onto one timeline and tests pin the
clock, because the reader prunes sessions older than a week and wall-clock
fixtures would have started failing seven days after they were written.

**Attributing an orchestration wave by substring-matching project paths in
`TASK.md`.** Written, then rejected once the CLI ran on a real machine: every
wave was claimed by the home directory, because `/home/me` is a substring of
every path beneath it and home becomes a tracked "project" the moment a session
runs there. Replaced with whole-path-token matching, longest project wins, and
home excluded outright. A wave is now left unattributed rather than attributed
wrongly.
