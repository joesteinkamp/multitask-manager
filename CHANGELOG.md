# Change Log

Changes made to this project by AI models, newest first.

Each entry records four things: **what changed**, **the ask** that prompted it,
**why this approach**, and **what was considered and rejected**. Read top to
bottom, it should explain how the project got here — not just what its files
did.

---

## Idle is a failure state, and "suggestions" stop being a promise

*(2026-08-19, Claude)*

### What changed

Three things the project layer was getting wrong, all of them the same mistake
in different clothes: reporting the absence of a problem instead of the presence
of one.

**`PRODUCT.md` no longer gates anything.** It was a hard requirement —
`meetsMinimum` was literally `product` — and failing it produced a status,
`unbriefed`, reading *"No PRODUCT.md — add one to get suggestions"*. Three of
four real projects reported that as their state, so the app's answer to "what is
happening here?" was a demand for paperwork. `AGENTS.md`, `CLAUDE.md`,
`CODE.md`, and a README now all count as knowing what a project is.

**The suggestions that file was gating did not exist.** Ten occurrences of the
word in the entire repository: two in the string telling the user they could not
have any, eight in `DecisionLog.suggestionAccepted` / `.suggestionRejected` —
accept and reject verbs for an object no code ever constructed. The gate was
guarding an empty room.

So `NextStepHarvester` was built to make the word mean something: it reads the
newest assistant message from a transcript, in either the Claude Code or Codex
shape, finds a next-steps cue, and offers the list under it for a yes or a no.
`SuggestionStore` persists the answer. **Then it was measured against 165 real
transcripts and produced nothing** — recorded below, because the measurement is
the more useful artefact than the code.

**`idle` exists, and ranks second.** The ladder's terminal verdict was `.ready`
with the reason *"Nothing blocked"* — reached when nothing is running, nothing
is queued, and nothing is suggested. An idle project got the same blue arrow as
one with work waiting to start. It now reads **"Idle 4h — nothing queued"**, in
`systemYellow`, behind only work blocked on the person. Ready reasons gained
"— nothing running" for the same reason.

`unbriefed` was deleted outright, along with the grey question mark that drew it.

### The ask

*"is the PRODUCT.md absolutely necessary for suggestions? I feel like we'd be
able to extract enough context from the sessions and other context files, like
AGENTS.md. Lastly, can this app consider encouraging recommended next steps from
the agent sessions to feed back into the app."*

Then, on seeing the result: *"If the file is even there, what does this app do as
there is not AI baked into it. How is it providing suggestions."* — which is the
question that exposed the empty room.

Then: *"I believe part of this is showing a question mark icon next to the
project. That makes it seem like something is wrong or unidentifiable."*

And finally the correction that produced `idle`: *"'Nothing blocked' is not
really the best state… we need to denote projects that are idle as idle is
wasting time. Are you forgetting the context and goal of this app? The goal
should be that we're moving through the projects faster and never have them stop
working until their goal or task is achieved."*

### Why this approach

**Harvesting, not reasoning.** The app calls no models and will not — that
constraint is in `AGENTS.md` and is what lets the engine build on Linux and
Windows. But it does not need to reason about next steps, because the reasoning
already happened: an agent that finishes a turn writes down what it thinks comes
next, and that text sits in a transcript the person has since closed the terminal
on. Reading it is reading, not inference, and it was the only honest sense in
which this app could offer a suggestion.

**No cue, no suggestion.** Extraction requires an explicit next-steps heading.
Guessing which of an agent's closing sentences was a recommendation is how a
queue fills with noise, and a queue full of noise stops being read — which
costs more than having no queue.

**Dismissal is permanent, keyed to project plus normalised text.** Steps are
re-derived from disk on every refresh, so without a ledger every rejection
undoes itself within the minute. Session id and timestamp are deliberately
excluded from identity: the same step proposed again by a later session is the
same step.

**Idle ranks second because it is the state only a person can clear.**
Everything below it either knows its next move (`ready`), waits on something
legible (`blocked`), or is moving (`working`). And the elapsed time carries the
weight — "Idle" alone invites a shrug, while "Idle 4h" separates a project that
just finished a turn from one that stopped after breakfast.

`PRODUCT.md` already named this as the failure to drive to zero: *"a stuck
project makes noise; a forgotten one goes silent, and silence reads exactly like
fine."* The engine was not honouring its own brief. `dormant` covered the same
absence but waited seven days, by which point the week is gone.

**Yellow, not orange or grey.** Orange remains the only role permitted to
interrupt — idle is waste, not a question. Grey belongs to `dormant` and means
"reported, never highlighted", which is exactly the reading that let idle pass
as healthy. A test now pins the two apart. The glyph is an hourglass rather than
a pause, because nothing is holding the project up; time is simply passing.

### Considered and rejected

**Loosening the cue to match prose.** The measurement forced this decision:
probed against 63 real Claude Code sessions, twelve used a next-steps phrase
somewhere in prose and **zero** used one as a heading above a list. The cause is
upstream of the parser — the operating instructions in this repository tell
agents to reach for a long-running primitive *"instead of ending with a list of
next steps"*, so closing summaries are deliberately prose. Matching prose would
mean deciding which sentence was a recommendation, which is inference this
module cannot do and must not fake. The harvester was kept with its measured
yield written next to it in the source: cheap and correct where the pattern
occurs, wrong to rely on. The reliable path — dispatch a delegate and read its
file output — is the architecture's own answer and remains unbuilt.

**Removing only the question mark icon.** That would have left a status still
meaning "we cannot identify this", drawn some other way. The problem was never
the glyph; it was that whether the app has read a description of a project says
nothing about whether that project needs anything, so it could not be a status
at all.

**Keeping a softened "no README" note in the expanded row.** Dropped for the
same reason — `doc.badge.plus` carries the same implication that the user owes
the app a file.

**Leaving `ready` alone.** A queue nobody is working is stopped too, just with a
known next move. "3 tasks ready" read as healthy when it is not.

---

## Say it in the menu bar, and give green one job

*(2026-08-19, Claude)*

### What changed

The menu bar icon answers **"is anything waiting on me?"** without being opened,
and answers nothing else. Calm is an outlined stack with no colour; working is a
filled stack with a count; complete is a check; needs-you is an orange bell with
a count.

Underneath it, the colour system was rebalanced in `DESIGN.json` so both clients
inherit it. Green had been doing three jobs — a working agent, an empty queue,
and a healthy detector — so a glance at green said nothing about which. It was
also on the wrong state entirely: green reads as *finished* everywhere else in
software, and this app used it for work in progress.

| Role | Was | Now |
|---|---|---|
| `working` | systemGreen | controlAccentColor |
| `complete` | *(borrowed the accent)* | **systemGreen** |
| all clear | systemGreen | **no colour** |

### The ask

*"The menu bar should highlight when things are active so I can tell what's
going on without having to opening the menu popover. Let's ideate on how to
signal activity in the icon space"* — and then, on the first proposal: *"You use
green for in progress and nothing waiting for me, which that should be fixed."*

### Why this approach

**Colour appears only when you must act.** That is what makes a menu bar with no
colour in it a fact you can read without focusing — the most valuable thing the
surface offers. It only works if exactly one state is ever coloured, so a test
asserts it. Calm is the absence of a signal, not a signal of its own.

**The glyph changes with the state as well as the colour**, so the signal
survives greyscale, a colour-blind reader, and a screenshot. Colour is the
accelerator, never the message.

**Counts appear only where a number implies something to do.** "3 finished"
invites an action that is not there, so `complete` and `calm` carry none.

**The precedence rule lives in `MultiTaskCore`, not the macOS app** — blocked on
you, then work in flight, then work finished, then silence. It is pure logic and
therefore testable, and the planned Windows taskbar has to answer the same
question; a second implementation would answer it differently within a month.
The badge count reads from the same rule, so the number and the glyph cannot
tell different stories.

Drawn as an `NSImage` because macOS renders a menu bar label as a template and
discards a SwiftUI tint. Non-template rendering is the supported way to keep a
colour, used for exactly one state.

### Considered and rejected

**A dot per project** — a dashboard in a space with room for one fact.
**A pulse while working** — motion in the periphery is unignorable by design,
which is the opposite of what a calm state needs.
**A progress ring** — a run has no known duration, so the ring would be a
decoration shaped like information.

Options were mocked in situ before choosing rather than argued in prose.

---

## Debug from evidence: write down what the app decided, and why

*(2026-08-19, Claude)*

### What changed

The app records its own verdicts — to a ring buffer, and to
`~/.multitaskmanager/diagnostics.log` — reachable from `mtm diagnostics` and
from Settings → Reporting a problem. The unit is a verdict and its reason, not
an event:

```
projects   refused ~/dev/scratch — no project marker (.git, AGENTS.md, …)
status     other: idle — 240s since its last tool call (inferred; no hook)
terminal   found claude in ~/dev/app but no known terminal above it —
           chain: claude ← zsh ← SomeTerminal
```

It immediately paid for itself. Two bugs were found by reading a log from the
Mac rather than by reasoning — the first time this project was debugged from
evidence:

**Every Codex session was named after its own filename.** Sixteen of twenty-two
sessions showed as `rollout-2026-08-18T11-28-12-…`, attached to no project.
Codex writes its session metadata as one JSON object on line one, measuring
17–18.6 KB on this machine; the reader used a 16 KB window, truncated the line
mid-object, and never found `cwd`. That was what *"I have multiple agent
sessions open and nothing is shown"* actually was — they were there,
unrecognisable.

**The log was burying its own signal.** Every refresh re-derived a verdict for
every session and recorded all of them: 22 sessions on a five-second cadence
wrote 264 lines a minute, filling a 500-entry buffer in under two minutes.

### The ask

*"I don't care about this machine's sessions. We're testing it on the mac. Get
it through your thick skull. You are running on not a Mac but you need to be
able to troubleshoot so why don't you add some sort of logging within the app
that I can send you so you can have the information you need to diagnose
issues."*

The frustration was earned. Every hard bug in this project has been a wrong
*conclusion* drawn from correct data, and reporting one meant describing a
symptom in prose and having me guess at the cause — which I did wrongly three
times in one afternoon, once shipping a regression on the strength of a guess.

### Why this approach

**A verdict and its reason, not an event stream.** An event log answers "what
happened"; these bugs all needed "what did you conclude, and from what". The
terminal line above answers *"why didn't it switch to Warp"* without another
round trip — it names the executable to add to the catalog.

**Written to a file, not just held in memory.** A problem is noticed, the app
runs on for an hour, and by the time anyone looks the evidence has rolled out of
the buffer or the app has restarted. Which is exactly when someone goes looking.
It rotates at 2 MB keeping one previous file, so a rotation mid-investigation
does not destroy the thing being investigated.

**Transitions, not states.** `recordChange` keys a decision by session and files
it only when it differs. Elapsed seconds came out of the message for the same
reason — they tick every pass, which made every line look new.

**A 512 KB metadata window, and drop the trailing partial line.** A byte window
rarely lands on a newline, and half a JSON object parses as nothing — which is
the same failure one size larger.

### Considered and rejected

**Including prompt or tool content.** The log carries no prompt text, tool
input, tool result, or file content. Home is redacted *on disk*, not only in the
export, because the file is what gets sent. Paths and project names are included
— they are usually the bug.

**Letting write failures surface.** They are swallowed deliberately: a
diagnostics log that can break the app it is diagnosing is worse than no log.

**Leaving it on under tests.** Disabled under a test bundle, or a suite fills
the buffer with reports about its own fixtures.

---

## Report status from the harness instead of inferring it from silence

*(2026-08-18, Claude)*

### What changed

The app decided a session needed you by **how long its transcript had gone
unmodified**. That cannot distinguish an agent thinking, an agent waiting on the
network, and an agent waiting on a person — so it called all three "needs
attention".

Claude Code will simply say. `Notification` carries the matchers
`permission_prompt`, `agent_needs_input`, `idle_prompt` and `agent_completed`;
`Stop` fires when a turn ends; `SessionStart` and `SessionEnd` bound the
session. The app already read a v2 status file — what was missing was anything
*writing* one. `Scripts/hooks/mtm-status.sh` maps every event to the contract,
and `mtm hooks install` wires it up.

Two rules changed, and they are the point:

- **A gap in activity can never be `needsAttention`.** It resolves to working or
  idle, full stop. Attention now requires something that *says so* — a hook, or
  a task explicitly waiting on a human.
- **Finished is not needing you.** A completed run was reported as
  `needsAttention` for the entire idle window after it ended. There is now a
  `complete` state, reading as settled rather than as an interruption.

### The ask

*"I ran an agent in Codex and the app didn't change the menu bar until it was
done"*, and *"There are hook events that codex and claude have that tell you if
things need things. AgentWatch does this super well for Claude… It color codes
status by 'Ready' 'Running' 'Complete'."*

### Why this approach

**An alert that is wrong often enough teaches you to ignore the one that is
not.** Without hooks the app now interrupts for nothing and reports activity
honestly; with them, attention is a fact rather than an inference. That is the
right way round.

**`hooks install` merges rather than overwrites.** `settings.json` belongs to
the user and already has hooks in it — it found nine on this machine and left
them alone. `uninstall` removes only what this app wrote.

**One script for all events, never blocking a tool call, always exiting 0.** A
status reporter that can fail a tool call is a status reporter that gets
uninstalled.

### Considered and rejected

**Keeping silence as a weak attention signal**, on the theory that a long enough
gap probably means a prompt. Rejected outright, and a test now asserts that *no
gap of any length* may produce needs-attention. "Probably" is what produced the
badge that lit for a Codex run that had finished cleanly.

---

## Take you to the terminal running the session, not to its folder

*(2026-08-18, Claude)*

### What changed

Clicking a notification revealed the project folder in Finder. For a CLI session
that is the wrong answer to the wrong question — it says where the project
*lives*, when you wanted the window that needs you.

The app now finds a process whose working directory is the project, walks up its
parent chain, stops at the first process a catalog recognises as a terminal, and
activates **that process**. Shipping with Warp, Terminal, iTerm2, Ghostty, kitty,
WezTerm, Alacritty, Hyper, Tabby, plus VS Code and Cursor.

### The ask

*"the notification should take you to the terminal of the session, not to the
projects parent folder. We need to support many terminals, I use Warp primarily
but we should support Terminal, Ghosty, iTerm2, etc… Make it easy to support
more."*

### Why this approach

**A CLI session carries no pid.** It is detected from a transcript file, and the
harness audit log records a working directory and a session id but no process.
So the terminal cannot be remembered when the session is found — it has to be
*located* when you ask to go there, from the processes running at that moment.
That constraint shaped everything else.

**Activate the process, not the bundle.** With two Warp windows open on two
projects, launching the app raises whichever was last used — wrong half the time.

**Adding a terminal is one entry.** `TerminalCatalog.all` carries bundle ids
(several per terminal: they ship stable and preview builds under different ids)
and executable names separately, because a bundled app's executable is rarely
named after its bundle id. A test checks every entry's shape, so a malformed
addition fails loudly rather than silently never matching.

**Split for testability.** `TerminalCatalog` and `TerminalResolver` are
Foundation-only and run on Linux in CI — including the case that would otherwise
hang a click handler: a cycle in reported parentage, which a snapshot taken
while processes exit can produce. Only gathering the process table is Darwin.

### Considered and rejected

**Falling back to whatever process sits above an unrecognised parent.** It
resolves to *nothing* instead. Activating an arbitrary application because it
happened to be in the chain is worse than doing nothing, and the diagnostics
line names the executable to add to the catalog instead.

**Raising the specific tab.** Not done. The catalog records the distinction —
`precision: .tab` marks Terminal and iTerm2, which expose a tab's tty to
AppleScript — but everything else can only be brought forward as an application.
With several Warp tabs you land in Warp, not necessarily the right tab.

---

## Run the app for the first time, and fix everything that fell out

*(2026-08-18, Claude)*

### What changed

The app had been built, migrated onto the shared package, and never once run.
The first real session on a Mac produced a cascade of failures, fixed across
seven pull requests:

- **The project list rendered at zero height.** `ScrollView { … }.frame(maxHeight:)`
  sets a *ceiling, not a floor*; a `ScrollView` has no intrinsic height and a
  `MenuBarExtra` sizes to its content's ideal height. One cause, three reported
  symptoms — no visible projects, a dead "+ Task" button, and a working
  "+ Project" (a panel, outside the popover).
- **Every dormant project was collapsed behind a row reading "4 gone quiet"**,
  so the common case showed a count with no list, labelled like an archive.
- **The app could not add a project.** `+` added a *task*; a project appeared
  only when a session happened to run in its directory.
- **Projects were being invented** from any working directory a session ran in —
  a `~/.hermes` skills path, a `/tmp` scratchpad. One stopped existing when its
  session ended, which is how a stale row ends up opening `~/Applications`.
- **A git worktree showed as its own project** — and the parallel-agent workflow
  this project is built around puts every agent in one, so it would keep
  happening.
- **The list reordered between refreshes**, because projects sharing a status
  sorted on raw `lastActivity` and several sat fractions of a second apart.
- **Tasks could belong to no project**, landing in a central list belonging
  nowhere — which breaks what the product is built on.
- **macOS 14 APIs were reachable from the macOS 13 path**, breaking `main`.

### The ask

Reported directly, over several rounds: *"The menu bar says there are 4 projects
but I cannot see them anywhere?"*, *"Add button doesn't do anything"*, *"I have
a random 'instructions' project that when clicked open `~/Applications`"*,
*"'practical-chaplygin-eb0c7d' worktree keeps showing up as separate"*, and
*"Add task adds it to a central list and not to a project. It should always be
with a project."*

### Why this approach

**A discovered directory must look like a project** — a VCS directory, a
manifest, a Makefile, or one of the brief files. Discovery only: a project added
by hand is a project because you said so.

**A worktree is folded into the repository it is a checkout of.** Its `.git` is
a *file* pointing at `<repo>/.git/worktrees/<name>`, which is now read. A
submodule uses the same mechanism with a different target and is deliberately
left alone rather than folded into a parent it has nothing to do with.

**Recency is compared by the minute**, with a deterministic tiebreak on name
below that. An hour's difference still sorts first; a fraction of a second no
longer does. A list that rearranges itself under the cursor is unusable for
glancing at, which is the only way this one is used.

**"Not a project — forget it" removes any row outright**, whatever created it
and whatever the rules think. Archiving keeps a project you still have; this is
for a row that should never have existed. That is the important half: every rule
for guessing what a project is will be wrong sometimes, and the answer cannot be
waiting for a better heuristic.

**The composer asks which project**, defaulting to the most recently active, and
cannot be submitted without one. From a project's own row it does not ask,
because the answer is known.

### Considered and rejected

**Banning temp locations from discovery.** Tempting, since a `/tmp` scratchpad
was one of the offending rows — but the marker rule already rejects a
scratchpad, a repo cloned to `/tmp` is a real project, and a location ban would
have banned that too while being untestable. A path *through* a dot-directory is
still excluded marker-or-not: that is tool state, and it is the shape that
produced the `~/.hermes` row.

**Showing the project's README in an expanded row.** It pushed the sessions —
the thing the row was expanded to see — below the fold. You already know what
your project is.

**Repurposing "Reveal in Finder" for the terminal.** The context menu grew a
second entry instead. A label that stops meaning what it says is worse than a
longer menu.

### Mistakes worth recording

**Work was reported as shipped that never reached `main`.** The worktree
migration and "forget it" were written locally, were not part of the pull
request that was merged, and were reported to the user as landed. Two rows the
user reported as stuck stayed stuck, across six repetitions of the same
complaint, because the fix existed only on this machine. Recovered as a separate
change. This was the second such claim in the project.

**Evidence was in hand and not acted on.** Two bugs in this batch — the
reordering list and an unhelpful status line — were visible in screenshots
already provided. The response was to ask for more information instead of
reading what was there. The user's summary: *"I gave you all the information of
the issues. You didn't make any changes."*

**A warning was raised without reading the code it was about.** The user was
told the new marker rule might make existing projects vanish. It cannot: `ensure`
returns an existing record *before* the marker check runs, so discovery
filtering applies only to directories seen for the first time.

---

## Make Windows CI mean something, and get one diagnosis badly wrong

*(2026-08-17, Claude)*

### What changed

Windows CI ran the full suite for the first time and failed ten tests, then kept
finding more. All are resolved: five were real cross-platform bugs, one was a
test that cannot run on Windows, and the rest were one intermittent bug wearing
several disguises — an atomic write that Windows loses. It took three wrong
diagnoses to get there, recorded below.

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

A second theory replaced it and was also wrong: that `TempDir` deleting its
directory in `deinit` let ARC remove the tree mid-test. That change was kept —
a fixture that deletes itself while a test is using it is a genuine hazard — but
it did not explain the failures either, and `main` went red on Windows again
after it merged.

**The actual cause was the write mode.** Every "file doesn't exist" failure on
Windows in this project has been an *atomic* write — `ProjectStore.save`,
`TempDir.write`, `AuditWriter.append`. An atomic write is a temp file plus a
rename, and on Windows that rename loses to a transient sharing violation
whenever something holds the new file for a moment; a virus scanner on a CI
runner is the usual cause. It fails intermittently and surfaces far from the
write, which is exactly why it read as three unrelated bugs across three
debugging attempts. Every write now goes through `FileSupport.write(_:to:)`,
which tries atomic, retries briefly, then falls back to a direct write — giving
up crash-atomicity, which is the right trade, because every reader here
tolerates a truncated record and none tolerates a file that never appeared.

A third diagnosis was wrong the same way: the staleness gate probed whether a
*file* could be backdated, which Windows does, when what the test needs is a
*directory*, which it does not. The evidence had been in the CI output all along
— the delegate files were correctly backdated to July and only the directory
read as now.

The pattern in all three: asserting a cause from a plausible story instead of
reading what the log actually said. What finally broke it open was a *fourth*
failure landing on a different test, which made "what do these have in common"
a better question than "what is wrong with this one". Every real step forward
came from the logs, not from the theories.

**One failure resolved without explanation.** "An approval consumed by an attempt
that failed stays pending" failed on Windows and then passed with no targeted
fix. It is most likely the same intermittent write, but that cannot be claimed.
If it returns, `noWorkingDirectory` now names whether the project is missing,
pathless, or simply absent from the snapshot.

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
