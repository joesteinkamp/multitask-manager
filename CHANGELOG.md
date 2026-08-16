# Change Log

Changes made to this project by AI models, newest first.

Each entry records four things: **what changed**, **the ask** that prompted it,
**why this approach**, and **what was considered and rejected**. Read top to
bottom, it should explain how the project got here — not just what its files
did.

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
