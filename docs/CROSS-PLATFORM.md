# Cross-platform plan

[ROADMAP.md](../ROADMAP.md) says *what* and *why*. [PLAN.md](PLAN.md) says *how*
for the six feature phases. This says how the same product reaches **Windows and
the Linux command line** without becoming three products.

The product this serves is a control plane for a small set of projects run in
parallel by one person and their agents — so "reaching another platform" means
reaching another *person's* desk, not another deployment target. That is why the
popover is an acceptance criterion below rather than a feature: an ambient tool
that costs a context switch to open is one that doesn't get opened.

Item numbers are `W0`, `W1`… and are independent of the `P` phases; the two
tracks interleave rather than block each other.

**Scope, decided up front:** two GUIs — macOS and Windows — and a first-class
Linux CLI. **There is no Linux GUI**, and that is a decision rather than a gap;
see below.

---

## Where we already are

Worth stating plainly, because it changes what this plan has to be:

- **`MultiTaskCore` already builds and tests on Linux.** It imports Foundation
  only — no SwiftUI, no AppKit — and its 152 tests run there in under a second.
  That wasn't an accident of writing style; it was the constraint that made the
  engine verifiable at all, and it happens to be most of the cross-platform work
  already done.
- **`mtm` already runs on Linux.** `mtm status`, `ls --json`, `watch`, `waves`,
  `roster` and `doctor` all work today against real harness data.
- **`EngineClient` already separates the engine from its faces**, and the
  versioned, language-neutral protocol a face would speak across a process
  boundary is implemented and tested.

So "Linux CLI" is not a port. It is a supported-target and packaging problem,
plus the portability fixes in W0. The genuinely new work is **Windows**.

---

## The three decisions this plan rests on

### Decision 1 — no Linux GUI

**Linux is served by the CLI. No tray, no popover, no window.**

The costs it removes are large and specific: a third native UI to design and
keep at parity, the Qt-versus-GTK question, GNOME's decade-long tray situation
(no toolkit can conjure a tray where the desktop has removed it), the Wayland
global-shortcut portal, and GUI packaging for a platform with several answers
to every packaging question.

The thing that makes this more than cost-cutting is *where Linux actually gets
used here*: the primary Linux target is a headless box with no display at all.
A Linux GUI would have been built for a hypothetical user rather than the real
one. Meanwhile the CLI already works there today.

**On Linux, the fingertip requirement gets a different answer, not a worse
one.** A desktop notification when a session needs you, plus one short command
to see everything, is the terminal-native form of the same promise. That makes
`mtm watch` and its notifications essential rather than a nice-to-have, which is
reflected in W1.

**What this costs, and the mitigation.** The previous plan built the Linux GUI
*first* on purpose: the Linux engine already runs, so a Qt client would have
proven the "native client over the protocol" pattern without simultaneously
debugging a new engine port. Dropping it means the first non-Swift client is
also the first Windows engine — two unproven things at once. The mitigation is
cheap and folded into W2: a small **reference client in another language**
(Python, on Linux, checked in and run by CI) that drives the daemon from the
written contract alone. It proves the protocol is genuinely language-neutral
without building a GUI to find out.

### Decision 2 — native UI on the platforms that get one

**SwiftUI on macOS, WinUI 3 (C#) on Windows. No webview, no shared UI layer.**

The requirement driving this is access, not aesthetics. This is an ambient tool
for managing work already in flight, and it fails if reaching it costs a context
switch. That makes the menu-bar / taskbar popover the product, not a delivery
detail — and a popover is the one thing a webview is worst at, because it has to
appear instantly, correct, with no boot and no layout shift, dozens of times a
day. Keeping a webview warm and hidden mitigates that, but it mitigates a
problem native UI doesn't have.

| Option | Why not |
|---|---|
| One web UI in a Tauri/Electron popover | The cheapest path to more GUIs, and an earlier recommendation here. Loses on the interaction that matters most, and every fix for it is a workaround. |
| SwiftUI everywhere | Apple-only. |
| A cross-platform Swift UI toolkit | Immature relative to this, and a bet on someone else's roadmap for the most visible part of the product. |
| Browser tab served by the daemon | Fails the access requirement outright. |

**What makes two UIs affordable is that neither of them is allowed to think.**
Everything that decides what is true already lives in the core: which sessions
exist, what status each has, why it is waiting, what order to pick them up in,
and when to interrupt. A UI receives a snapshot and renders it; it sends actions
and re-renders. No filtering logic, no status heuristics, no sort order, no
notification rules in any UI, ever. That rule is what keeps a native UI to a
list, a detail panel, a settings pane and a board — and it is the rule that will
be under pressure the first time something is "just easier to do in the view".

**Nothing built so far is wasted by this.** The versioned JSON protocol shipped
in step one exists precisely so a face can be written in another language. A
WinUI client in C# attaches as a thin client, with no C ABI shim over the Swift
engine and no FFI at all. The architecture is unchanged.

### Decision 3 — on Windows, WSL is the primary case, not an edge case

**Windows support reads both native and WSL session roots from the first
release, rather than shipping native-only and adding WSL later.**

The reasoning is specific to *this* app rather than general Windows wisdom. The
richest signals it consumes — `~/.ai-logs/tool-calls.jsonl`, the hook status
files, `~/.ai/` — are produced by a POSIX shell harness whose installer is a
shell script. On a Windows machine that harness realistically lives in WSL. A
Windows build that reads only `%USERPROFILE%\.claude` would therefore find
sessions but no audit log, no hooks, and no roster — which is to say it would
degrade to the weakest tier of the status ladder and lose exactly the precision
that made Phase 1 worth building.

Shipping native-only first is the cheaper-looking path that produces the worse
product and then requires the multi-root refactor anyway.

---

## Fingertip access is an acceptance criterion, not a feature

For the platforms with a GUI. If any of these fail, that platform isn't done.

- **Opens in under 150 ms**, 95th percentile, on an unremarkable machine.
- **Correct the instant it appears.** No spinner, no layout shift, no "loading
  sessions". The shell holds the last snapshot and keeps it current over the
  subscription *while the popover is closed*, so opening is a reveal, not a
  fetch.
- **Dismisses on click-away and on Esc**, like every other popover on the system.
- **A global hotkey summons it from anywhere**, configurable, co-equal with the
  tray icon rather than a fallback. The tray is how the app tells *you*
  something — the badge is the ambient channel. The hotkey is how you reach *it*,
  and it beats any pointer trip to a screen corner.
- **Fully keyboard-operable once open**: arrows move through sessions, Enter
  activates, Esc closes, `/` focuses search. A popover you have to mouse around
  inside is not at your fingertips either.
- **The badge is correct within one refresh while the popover is closed** — that
  is the entire point of the ambient presence.
- **It is there after a reboot without being launched.** If the user has to
  remember to start it, the ambient promise is broken on day one.

The Linux equivalent, since it has no popover: a notification arrives without
the terminal being open, and `mtm status` answers in well under a second from
cold.

---

## What breaks today, verified

These were measured against the current code, not assumed. Each is small; the
point of listing them is that they are silent failures rather than crashes.

1. **`FileSupport.lastComponent(of:)` splits on `/` only.** Given
   `C:\Users\joe\projects\app` it returns the entire string. Every project name,
   every `hook:` id built from a path, and the wave-attribution longest-prefix
   match would be wrong on Windows.
2. **CRLF silently truncates every project briefing.**
   `components(separatedBy: .newlines)` treats `\r\n` as *two* separators, so a
   Windows-authored `README.md` yields a spurious empty line between every real
   one. `extractGoal` reads an empty line as the end of the paragraph, so a
   two-line goal becomes a one-line goal. Confirmed by reproducing the
   extraction loop against a CRLF document. The same flaw affects
   `extractNextSteps` boundaries and `STATE.md` progress lines.
3. **`\r` survives `trimmingCharacters(in: .whitespaces)`** — carriage return is
   in `.whitespacesAndNewlines`, not `.whitespaces` — so trailing CRs would ride
   into titles, goals and task text.
4. **`FileSupport.fileIdentity` uses inode numbers**, which have no meaning on
   Windows. The audit log's rotation detection would never fire, so a rotated
   log would be read from a stale offset forever.
5. **`GitRunner.resolveGit()` hardcodes Unix paths** (`/usr/bin/git`,
   `/opt/homebrew/bin/git`). Windows needs a `PATH` search.
6. **`OverridesStore` uses `.applicationSupportDirectory`.** On Linux this
   resolves to `~/.local/share`, which is *right*, so this one is better than
   feared — but it needs to honour `XDG_DATA_HOME` explicitly rather than by
   luck, and on Windows it must land in `%APPDATA%`.
7. **`setvbuf`/`_IOLBF` in `mtm watch`** needs a Windows import path.

One pleasant surprise, also verified: **CRLF-terminated JSONL parses fine.**
`JSONSerialization` tolerates the trailing `\r`, so the audit log reader and the
wire `FrameReader` need no change for line endings. Only the *prose* readers do.

---

## Architecture: what is shared and what is not

```
                    ┌───────────────────────────────┐
                    │  MultiTaskCore (Swift)        │
                    │  detectors · enrichment       │
                    │  merge · status precedence    │
                    │  triage · notification policy │
                    └───────────────┬───────────────┘
                                    │  EngineClient
                ┌───────────────────┼───────────────────┐
                │                   │                   │
        in-process (macOS)   mtmd + socket        in-process (Linux)
                │             (Windows)                 │
             SwiftUI            WinUI 3               mtm CLI
             popover          tray flyout        + desktop notifications
```

**Shared, and must stay shared:** everything that decides *what is true*. All of
it is in `MultiTaskCore` today and none of it is platform-specific once W0
lands.

**Where the engine runs differs by platform, and `EngineClient` is what makes
that invisible.** macOS hosts it in the menu-bar app, as it does today. The
Linux CLI hosts it in the command's own process. Windows *cannot* — a C# UI
can't host a Swift engine — so Windows runs `mtmd` and talks to it over the
socket. **The daemon is therefore built because one platform requires it, and
stays optional everywhere else.** That is exactly the split `EngineClient` was
designed for, and it means macOS gains no process it doesn't need.

**Per-platform integrations**, each small and well understood:

| Concern | macOS | Windows | Linux |
|---|---|---|---|
| Popover | `MenuBarExtra` (built) | tray + borderless flyout | — |
| Deliver a notification | `UNUserNotificationCenter` | WinRT toast | D-Bus `org.freedesktop.Notifications` |
| Global hotkey | `NSEvent` global monitor | `RegisterHotKey` | — |
| Reveal a folder | `NSWorkspace` | `explorer.exe` | `xdg-open` |
| Run at login | LaunchAgent | Task Scheduler | systemd user unit (daemon only, optional) |

The notification split already exists in the right place: the *policy* — edge
detection, debounce, cooldown, coalescing, quiet hours — is platform-neutral and
tested, and only *delivery* is native. Three presenters, no policy changes.

---

## Phases

### W0 — De-Unix-ify the core, and stand up the CI matrix

Fix the seven verified breakages above, and add the abstraction that stops them
recurring.

- **New `PlatformPaths`** replacing every hardcoded `~/…` in the core: home,
  config, data, cache, and the harness roots. One place that knows about
  `%APPDATA%`, `$XDG_DATA_HOME`, and `~/Library/Application Support`.
- **Path handling that accepts both separators**, with case-insensitive
  comparison on Windows only. A `Path` value type is worth it here rather than
  passing `String` and remembering.
- **A `lines(of:)` helper that splits `\r\n`, `\n` and `\r` correctly**, used by
  every prose reader in place of `components(separatedBy: .newlines)`. Wants a
  CRLF fixture checked in beside the existing ones.
- **Rotation detection that degrades**: `(device, inode)` where available,
  `(creationDate, size)` where not.
- **Git discovery via `PATH`.**
- **CI matrix lands here**, not at the end: `macos-latest`, `ubuntu-latest`,
  `windows-latest`. A Windows job that has been red for a month is worse than no
  Windows job, so it lands green with this phase or it doesn't land.

**Done when:** `swift test` is green on all three and `mtm doctor` runs on all
three. Nothing user-visible ships, which is exactly why the CI matrix is part of
it.

### W1 — Linux CLI as the whole Linux product

Mostly packaging and manners, since the code already runs — but the bar is
higher now that it is the only Linux face.

- XDG-correct locations for overrides, runs and the socket.
- **Desktop notifications from `mtm watch` via D-Bus.** This is the ambient
  channel on Linux and the reason the platform is served at all without a GUI;
  it is not optional polish.
- A systemd user unit so `mtm watch --notify` can run at login, for a desktop
  Linux user who wants the notifications without a terminal open.
- Packaging: a tarball first, then `.deb` if it earns one. Not Flatpak — this
  needs the user's real home directory and their repos, which is precisely what
  that sandbox is designed to prevent.
- `--version`, a man page, and shell completions (generated by
  `swift-argument-parser`).

**Done when:** a fresh Ubuntu box can install `mtm`, run `mtm doctor`, and get a
desktop notification when a session goes quiet — with no terminal open.

### W2 — `mtmd`, the client contract, and a non-Swift reference client

The daemon exists because Windows requires it. It stays optional on macOS and
Linux, where in-process remains the default.

- Transport adapter behind the existing wire protocol: unix domain socket on
  macOS and Linux; on Windows, `AF_UNIX` is supported on Windows 10 1803+ and is
  the smaller change, with a named pipe as the fallback.
- Single-instance via connect-then-unlink-stale-socket, not launchd/systemd.
- Peer credential check rejecting any uid but our own.
- **A written client contract** — methods, payload shapes, event stream, version
  gate — because it is about to be consumed by a codebase in another language,
  and "read the Swift source" stops being an answer.
- **A reference client in Python**, ~100 lines, checked in and exercised by CI
  on Linux. This is the mitigation for dropping the Linux GUI: it proves the
  protocol is genuinely language-neutral *before* the WinUI client depends on
  that being true, and it doubles as executable documentation of the contract.

**Done when:** the Python client can list sessions, subscribe to changes and
perform an action, written from the contract document alone.

### W3 — Windows engine, with WSL roots

Headless — no UI yet, verified entirely through `mtm` and `mtmd`. Per decision
3, native and WSL roots are one phase and not two.

- **Multi-root detection.** A `SessionRoot` describes a home to scan — native
  Windows, plus one per installed WSL distribution (`wsl.exe -l -q`, reachable
  at `\\wsl$\<distro>\home\<user>`). Sessions carry the root they came from.
- **Path translation per root.** The audit log written inside WSL records
  `cwd: /home/joe/projects/app`, while the Windows side sees
  `\\wsl$\Ubuntu\home\joe\projects\app`. The join must normalise into the root's
  own namespace before comparing, or every `cwd` fallback silently misses. The
  precise session-id join is unaffected, which is another reason it was worth
  establishing.
- **"Reveal folder" and any future launch action** must translate back out, and
  a launch into a WSL root goes through `wsl.exe -d <distro>`.
- **File sharing semantics.** Windows refuses to delete or rename a file another
  process holds open. The audit-log tail must open with delete-sharing so it
  cannot block the harness from rotating its own log. Highest technical risk in
  this phase.
- Long-path support and case-insensitive comparison.

**Done when:** `mtm doctor` on Windows reports the same sessions, statuses and
precise joins that Linux does, for a harness running inside WSL.

### W4 — Windows GUI (WinUI 3)

- Tray icon with a badge — note that Windows has no native numeric badge on a
  tray icon, so it is a rendered overlay, and the tray *overflow* area means the
  icon may not be visible at all unless the user promotes it. First-run should
  say so rather than let the ambient promise fail quietly.
- Borderless flyout anchored to the tray, respecting a taskbar on any edge.
- WinRT toasts, global hotkey via `RegisterHotKey`, run-at-login via Task
  Scheduler, and supervision of the `mtmd` sidecar.
- The fingertip criteria are the acceptance test; the no-logic-in-the-UI rule
  applies without exception.

### W5 — Parity, packaging, first-run

- A written per-screen spec so two UIs are compared against one definition
  rather than against each other.
- Signing and distribution: Developer ID + notarisation (macOS), Authenticode +
  winget (Windows), tarball/`.deb` (Linux).
- First-run per platform, explaining what the app can and cannot see — which on
  Windows means saying plainly whether it found a WSL harness.

---

## Risks

**Swift on Windows is the top risk, and the whole Windows product rests on it.**
Choosing C# for the UI means Swift there only has to run the *headless* engine
and daemon — Foundation, sockets, `Process`, file I/O — with no UI framework
binding involved, which is the part most likely to work. But if it doesn't work,
there is no Windows product. The contingency: reimplement the detectors in C#
against the same documented file formats, keeping Swift for macOS and Linux.
Expensive and a genuine fork of the engine, so it is worth naming as a decision
rather than discovering as a scramble. **Decide at the end of W0**, when the CI
matrix has evidence, not halfway through W3.

**Feature-parity drift between two UIs** is smaller than it was at three, but
real. Three controls, in increasing order of how much work they do:

- **No logic in any UI.** Status, triage, ordering and notification decisions
  stay engine-side, so a face is a renderer.
- **`DESIGN.json`** — the machine-readable token file `project-starter-pack`
  generates. This is a better parity control than the per-screen spec originally
  planned here, because it is *executable*: colour, type, spacing, radius and
  motion values are generated into SwiftUI constants and XAML resources from one
  source rather than transcribed twice. Visual drift stops being a discipline
  problem and becomes a build step. This project needs to write its own
  `DESIGN.md`/`DESIGN.json` before the second UI starts, or the second UI will
  be matched against the first one by eye.
- **A written per-screen spec** for the behaviour tokens can't carry — what a row
  shows, what an empty state says, what happens on Esc.

**The protocol is unproven across a language boundary** until the Python
reference client in W2 exists. That is precisely why it is in W2 and not
discovered during W4.

**Windows tray visibility.** An icon banished to the overflow area is an ambient
presence the user never sees. This is a product risk, not a technical one, and
the answer is first-run guidance plus the global hotkey.

**Scope.** W0 and W1 are small and complete the Linux story. Everything from W2
onward exists to serve Windows. Stopping after W1 leaves macOS with its GUI and
Linux with a supported CLI — a coherent product, and a legitimate place to stop
if Windows stops being worth it.

---

## Open questions

1. **Is Windows usage native, WSL, or both?** This plan assumes both with WSL
   primary. If the answer is "native only", W3 roughly halves. If it is "WSL
   only", the Windows *engine* could arguably be the Linux build running inside
   WSL with only the WinUI client on the Windows side — materially cheaper, and
   worth deciding before W3 starts.
2. **How much of Foundation actually works on Windows** for the specific calls
   this app makes? Answered by the W0 CI matrix, and it decides the W3
   contingency.
3. **Does the macOS popover need to change at all?** It already satisfies the
   fingertip criteria. The risk is that it becomes the reference implementation
   by accident rather than by decision, and Windows gets measured against an
   undocumented target.
4. **Would a terminal UI (`mtm ui`) be worth it on Linux?** Explicitly *not*
   planned. Recorded because it is the obvious thing to ask for once Linux has
   no GUI, and the answer should be a decision rather than drift: the CLI plus
   notifications is the committed Linux experience.
