# Technical Brief

> Read this before writing code: stack, architecture, conventions, testing, performance,
> security. Unlike `DESIGN.md` this has no hard trigger, because tests, lint, and review already
> catch stack and architecture divergence — but the constraints marked **non-negotiable** below
> are load-bearing, and working around one produces something that has to be undone.

**Status:** written against the repository as built. Where a decision is still open it says so
under [Open decisions](#open-decisions).

---

## Stack

| Layer | Choice | Why this one |
|---|---|---|
| Engine | Swift 6, **Foundation only** | One implementation behind every client; Foundation-only is what lets it build and test on Linux in CI and run on Windows. |
| Package manager | SwiftPM, local package at `Packages/MultiTaskCore` | A local package rather than a monorepo target, so the app, the CLI, and the daemon consume the same versioned unit. |
| macOS client | SwiftUI, `MenuBarExtra`, `LSUIElement` | A menu bar utility with no dock presence. `MenuBarExtra` is the supported path; a hand-built `NSStatusItem` buys one API and loses the rest. |
| CLI | `swift-argument-parser` | Same engine, in-process. It is also the cheapest test of whether the engine's API is usable by something that is not the popover. |
| MCP server | Hand-rolled JSON-RPC 2.0 over stdio, newline-delimited | The protocol surface used is small and the dependency would be larger than the code. |
| Persistence | Markdown with YAML-ish front matter; JSON for machine records | Git-friendly and agent-editable. See [Persistence](#persistence). |
| Tests | swift-testing (`import Testing`) | `#expect`, `#require`, `@Suite`, `@Test`. Not XCTest. |
| Windows client | WinUI, planned | Consumes the same engine over IPC. Nothing is built yet. |

**No third-party dependencies in the core.** Not asceticism: every dependency is a thing that
has to build on Linux, on Windows, and inside an Xcode app target, and the core's job is to be
the one component that always compiles.

---

## Architecture

```
                      ┌──────────────────────────┐
   detectors ────────▶│      DetectionEngine     │  reads the machine
   readers   ────────▶│   (actor, Foundation)    │  → EngineSnapshot
                      └────────────┬─────────────┘
                                   │
                      ┌────────────▼─────────────┐
   stores    ────────▶│     InProcessEngine      │  owns actions, gates,
   launcher  ────────▶│  (actor, EngineClient)   │  notifications, control
                      └────────────┬─────────────┘
                                   │  EngineClient protocol
              ┌────────────────────┼────────────────────┐
              ▼                    ▼                    ▼
        SessionStore           mtm (CLI)          mtm-mcp (agents)
        (@MainActor)
              ▼
        SwiftUI views
```

**Everything goes through `EngineClient`.** The app, the CLI, and the MCP server all call
`act(_:)` and read `EngineSnapshot`. Nothing reaches around it to a store. This is what makes
the gates real — a confirmation that only the UI enforces is not a confirmation — and it is what
lets a daemon slot in later as a different `EngineClient` without touching a command.

**Detection reads; the engine decides.** `DetectionEngine` knows nothing about runs, approvals,
or gates; it observes the machine and produces a snapshot. Control state is attached by
`InProcessEngine` on the way out. Keep it that way: detection is the part that must stay cheap
and pure.

**The snapshot is whole, not a diff.** Tens of sessions is not a bandwidth problem, and a subtly
wrong diff is a bug you find weeks later in a UI that is missing one row.

**A view model, not a second engine.** `SessionStore` is `@MainActor`, holds `@Published`
properties, and does three things the engine cannot: activate an app, reveal a folder, and
publish to SwiftUI. It used to *be* the engine, and moving that out is what made any of it
testable. Do not put logic back in it.

### Non-negotiable constraints

- **`MultiTaskCore` imports Foundation only.** No SwiftUI, no AppKit, no `CoreGraphics`. A
  `Color` property on a model is exactly what made the models un-portable before. Platform types
  live in the app target; the core deals in `String`, `Double`, and `Date`.
- **The app calls no models.** Inference happens in delegates the app launches. Where a feature
  seems to need reasoning, dispatch an agent and read its file output.
- **Organising is free; spending is gated.** Filing, ranking, and reassigning need no approval.
  Starting a run, or writing to a repository, requires a confirmation token derived from the
  request. See [The gate](#the-gate).
- **Agents ask; people decide.** No MCP tool may approve a request or accept a confirmation
  token. `MCPServerTests` fails if one appears.
- **The primary unit is the project.** Sessions, waves, and worktrees are evidence *about* a
  project. Code that improves the session list at the expense of the project layer is going the
  wrong way.

---

## The gate

The single most important invariant in the codebase, and the one most easily broken by a
plausible convenience.

A gated action issued without a token returns a `ConfirmationRequest` — a summary, detail lines,
and a token — and **does nothing**. Re-issuing the same action carrying that token performs it.

The token is a **function of the request** (`Launcher.token(delegate:command:workingDirectory:)`,
FNV-1a over NUL-separated fields), which gives two properties that both matter:

- **Stable** — the same request yields the same token, so it round-trips. An earlier version
  minted a fresh run id per call, so the token was already stale by the time it was returned;
  every confirmed run was refused, the CLI exited 0 saying nothing, and the test suite stayed
  green because it only tested refusal.
- **Bound** — a different request yields a different token, so approving "run claude in repo A"
  cannot authorise "run codex in repo B". Fields are NUL-separated so regrouping characters
  across arguments cannot collide.

There is **no bypass literal.** `confirm == "yes"` used to pass in both gated paths and was
removed. If you find yourself adding one, the thing to change is the caller.

Over MCP the gate takes a different shape, because an agent handed a token can just replay it:
agents call `request_run` and `request_isolation`, which file an `ApprovalRequest` and start
nothing. A person decides, and approving mints the token *inside* the engine. Requests expire
after 24 hours (enforced on read **and** on decide), duplicates collapse, and an approval whose
action then fails leaves the request pending rather than consuming it.

---

## Persistence

State lives under `~/.multitaskmanager`, overridable with `$MTM_HOME`.

| What | Format | Where |
|---|---|---|
| Projects, tasks | Markdown + YAML-ish front matter | `projects/`, `tasks/` |
| Decisions | JSON Lines, append-only | `decisions.jsonl` |
| Runs | JSON, one directory each, plus `stdout.log` / `stderr.log` | `runs/<id>/` |
| Approvals | JSON, one file each | `approvals/` |
| Overrides | JSON | `state/` |

**Markdown for anything a person or an agent edits.** It diffs, it survives a merge, and an
agent can write it without a schema. JSON for records nothing hand-edits.

**Run output is a file.** Not an in-app terminal — building one is a great deal of work to end
up worse than the terminal already on the machine, and once output is a file the existing
detectors pick the run up like any other session.

**Writes are atomic** (`.atomic`), and **one writer per file**. The app writes into a context
directory only when it created it, marked by `.mtm-owned`; without that marker an app refresh
and a live agent would both believe they own the rolling summary.

**Reads tolerate corruption.** A malformed line is skipped and counted, never fatal. The audit
log is written concurrently by shell hooks; an interleaved line is expected, and losing one
record is better than blocking a launch.

**Merge, don't overwrite.** `upsert` merges: a tracker sync sending only a title must not erase
acceptance criteria, and local workflow state — claims, snoozes, waiting — is never overwritten
by an external source. This was a real bug.

---

## Concurrency

- **Engines are `actor`s.** `DetectionEngine` and `InProcessEngine`.
- **Stores are `final class … @unchecked Sendable` with an `NSLock`.** Deliberate: they are
  called from actors and from termination handlers, and an actor store would make every read an
  `await` for no benefit.
- **`@MainActor` for the view model only.**
- **`AsyncStream` for events**, one continuation per subscriber.
- **Never hold a lock through `weak self`.** Acquiring it and then finding `self` gone before the
  release wedges every other caller. Capture the lock strongly; keep `weak self` for state.
- **Install `terminationHandler` before `run()`.** A fast child exits before a handler attached
  afterwards is ever called, which left every short run stuck in `running`.
- **Retain child `Process` objects.** Foundation reaps a child through its `Process`; drop the
  object and the child becomes a zombie the OS reports as alive forever.
- **`Process.isRunning` and `waitUntilExit()` lie on Linux.** After `terminate()` the handler
  fires immediately with status 15, yet `isRunning` still answers `true` seconds later and
  `waitUntilExit` blocks for the child's full original lifetime. Wait on the handler.
- **Serialise writes to one record.** The pid write after `run()` clobbered the handler's
  outcome for fast children until both went through the same lock.

---

## Testing

`swift test` from `Packages/MultiTaskCore`. Linux is the primary target, and CI runs Linux and
Windows.

- **swift-testing, not XCTest.** `@Suite`, `@Test`, `#expect`, `#require`.
- **Name the behaviour, not the method.** `"A task waiting on a human is not offered to agents"`,
  not `testReady()`. The name is the specification.
- **Say why in the test.** A comment stating the failure the test prevents is what stops it being
  deleted as redundant later.
- **Test the invariant, not the count.** `#expect(tools.count == 9)` broke on every new tool and
  protected nothing; `"no MCP tool can approve a request"` is the property that matters.
- **A green suite is not evidence a feature works.** The gate was unpassable for a whole commit
  while every test passed, because the tests only covered refusal. Test the success path.
- **Never write to the real state directory.** `FileSupport.stateDirectory` resolves to a
  per-process temp root under a test bundle. Pass explicit store directories anyway.
- **Verify end to end through the CLI** before calling control work done. The engine's tests did
  not catch a CLI that exited 0 after doing nothing.

---

## Performance

The refresh loop runs every few seconds, forever, on someone's laptop.

- **Incremental readers.** The audit log is tailed from the last offset, with rotation detection.
  Never re-read a growing file.
- **Push only on real change.** `changeDigest` deliberately excludes timestamps that drift every
  tick. Without it a five-second cadence turns into a list that flickers under the cursor.
  **Anything added to the snapshot that a subscriber should react to must join the digest** — an
  approval that does not is an approval that never reaches the user.
- **Git shells out, so it is optional.** `--no-git` exists, and the worktree scan is skipped
  under it.
- **Bound everything read from disk.** Tails have byte limits, listings have counts.
- **Line-buffer stdout in the CLI** (`setvbuf(_IOLBF)`), or `mtm watch` produces nothing when
  piped.

---

## Security

- **Argument arrays, never shell strings.** A project directory containing a quote or a semicolon
  would otherwise be an injection.
- **Banned flags are refused, not just omitted.** `--dangerously-skip-permissions`,
  `--dangerously-bypass-approvals-and-sandbox`, `--yolo`. A delegate launched with permissions
  disabled would make this app a way around every other rule in the project.
- **Preflight before mutating a repository.** Not a repo, dirty tree, detached HEAD, branch
  exists, worktree exists — report and stop. Every one is fixable in seconds and none is safe to
  force.
- **Never log secrets, and never re-log the audit log.** Records the app writes describe what the
  app itself did.
- **Truncate anything untrusted** before it reaches a log line or a confirmation.
- **Treat MCP input as hostile.** Resolve ids through the store, validate enums, and return
  errors as content rather than transport failures — an agent recovers from "that task doesn't
  exist" far better than from a protocol error.

---

## Conventions

- **Comments explain why, not what.** The bar: would a competent reader wonder why this is like
  this? Every non-obvious decision in this codebase carries the reason and, where one exists, the
  bug that produced it.
- **Doc comments on every public API**, with the design reasoning where there is any.
- **Name for the domain.** `needsYou`, not `isBlocked`. `asks`, not `pendingApprovalRequests`.
- **Errors are `CustomStringConvertible`** and say what to do next, not just what went wrong.
- **British spelling in prose, US in identifiers** — matching Swift and Foundation.
- **Never edit on the default branch.** Feature branch or worktree, always.
- **The generated token file is generated.** Edit `DESIGN.json`, run
  `Scripts/generate-tokens.py`, commit both.

---

## Anti-patterns — banned

- **Reaching around `EngineClient`** to a store from the app, the CLI, or the MCP server.
- **A platform type in the core.** `Color`, `NSImage`, `View`.
- **A bypass for the gate** — a literal that always passes, a debug flag, an "internal" caller
  that skips it.
- **An MCP tool that decides an approval** or takes a confirmation token.
- **Calling a model from the app.** Dispatch a delegate.
- **Re-reading a growing file from the start.**
- **Pushing a snapshot on every tick** regardless of change.
- **A shell string built from a path.**
- **Silent failure.** Exiting 0 having done nothing is the worst outcome available, because
  nothing looks wrong.
- **Adding to the snapshot without adding to the digest.**
- **Tests that write to the user's real state.**

---

## Open decisions

- **The daemon and its IPC.** Planned, not built. The engine is already behind a protocol so it
  can slot in, but the transport (Unix socket, named pipe on Windows) and the framing are
  undecided. This is the point at which the Windows client stops being hypothetical, since a
  WinUI process cannot host a Swift engine in-process.
- **Windows state roots.** Where `$MTM_HOME` defaults, and how WSL paths are reconciled with
  Windows ones.
- **Steering a running session.** The riskiest item in the plan and deliberately last.
- **Whether tasks should sync bidirectionally** with a tracker, or stay one-way in.
