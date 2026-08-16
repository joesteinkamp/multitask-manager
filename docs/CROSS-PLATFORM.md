# Cross-platform plan

[ROADMAP.md](../ROADMAP.md) says *what* and *why*. [PLAN.md](PLAN.md) says *how*
for the six feature phases. This says how the same product reaches **Windows,
Linux GUI, and Linux CLI** without becoming three products.

Item numbers are `W1`, `W2`… and are independent of the `P` phases; the two
tracks interleave rather than block each other.

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
plus the portability fixes in W0. The genuinely new work is **Windows**, and a
**native GUI on two more platforms**.

---

## The two decisions this plan rests on

Everything below follows from these. Both are reversible, but not cheaply, so
they are stated up front rather than discovered in phase four.

### Decision 1 — a native UI per platform, over one shared engine

**The UI is native on each platform: SwiftUI on macOS, WinUI 3 on Windows, Qt 6
on Linux. There is no shared UI layer and no webview.**

The requirement driving this is access, not aesthetics. This is an ambient tool
for managing work already in flight, and it fails if reaching it costs a context
switch. That makes the menu-bar / taskbar popover the product, not a delivery
detail — and a popover is the one thing a webview is worst at, because it has to
appear instantly, correct, with no boot and no layout shift, dozens of times a
day.

The alternatives and why they lose:

| Option | Why not |
|---|---|
| One web UI in a Tauri/Electron popover | The cheapest path to three GUIs, and it was the previous recommendation here. It loses on the one thing that matters most: a webview that has to warm up, or that repaints on show, turns the fastest interaction in the app into the slowest. Mitigations exist (keep it hidden and warm, never destroy it) but they are mitigations for a problem native UI doesn't have. |
| SwiftUI everywhere | Apple-only. Not a real option. |
| A cross-platform Swift UI toolkit (SwiftCrossUI, Qt/Swift bindings) | Immature relative to what this needs, and a bet on someone else's roadmap for the most visible part of the product. |
| Browser tab served by the daemon | Fails the access requirement outright. |

**What makes three UIs affordable is that none of them are allowed to think.**
Everything that decides what is true already lives in the core: which sessions
exist, what status each has, why it is waiting, what order to pick them up in,
and when to interrupt. A UI receives a snapshot and renders it; it sends actions
and re-renders. No filtering logic, no status heuristics, no sort order, no
notification rules in any UI, ever. That rule is what keeps a native UI to a
list, a detail panel, a settings pane and a board — and it is the rule that will
be under pressure the first time something is "just easier to do in the view".

**Nothing built so far is wasted by this — the opposite.** The versioned JSON
protocol shipped in step one exists precisely so a face can be written in
another language. A WinUI client in C# and a Qt client in C++ attach to it as
thin clients, with no C ABI shim over the Swift engine and no FFI at all. The
architecture is unchanged; only the number of faces went up.

**The honest cost** is feature-parity drift across three UIs, and design work
expressed three times (SwiftUI modifiers, XAML, Qt styles). This is the real
price of the decision, and the mitigations are the dumb-UI rule above, a shared
written spec for each screen, and accepting that platforms may lag each other
by a release rather than pretending they won't.

#### Toolkit notes

- **macOS — SwiftUI.** Already built and already right. `MenuBarExtra` gives the
  popover for free. No migration, no risk.
- **Windows — WinUI 3 (C#).** Tray icon plus a borderless flyout window. C# is
  chosen over Swift-on-Windows-UI deliberately: it means the Swift requirement
  on Windows is only the *headless* engine and daemon, not a UI binding, which
  materially shrinks the riskiest part of the plan (see Risks).
- **Linux — Qt 6, recommended over GTK 4.** This is the one genuinely contested
  call. GTK 4 with libadwaita is the more modern-Linux-native look, but it
  *removed* status-icon support entirely, so a tray requires a third-party
  indicator library. `QSystemTrayIcon` works across GNOME, KDE and XFCE today.
  When the requirement is a tray popover, the toolkit that still has a tray API
  wins over the one with the better design language. Revisit only if the app
  stops being tray-centric on Linux.

### Fingertip access is an acceptance criterion, not a feature

If any of these fail, the platform isn't done. They are testable, and each GUI
phase is scoped to hit them rather than to reach feature parity first.

- **Opens in under 150 ms**, 95th percentile, on an unremarkable machine.
- **Correct the instant it appears.** No spinner, no layout shift, no "loading
  sessions". The shell holds the last snapshot and keeps it current over the
  subscription *while the popover is closed*, so opening is a reveal, not a
  fetch. This is a client-side rule that applies to all three UIs.
- **Dismisses on click-away and on Esc**, like every other popover on the system.
- **A global hotkey summons it from anywhere**, configurable, co-equal with the
  tray icon rather than a fallback. The tray is how the app tells *you*
  something — the badge is the ambient channel. The hotkey is how you reach *it*,
  and it beats any pointer trip to a screen corner. On Linux it is also the
  insurance against the desktop having no usable tray at all.
- **Fully keyboard-operable once open**: arrows move through sessions, Enter
  activates, Esc closes, `/` focuses search. A popover you have to mouse around
  inside is not at your fingertips either.
- **The badge is correct within one refresh while the popover is closed** — that
  is the entire point of the ambient presence.
- **It is there after a reboot without being launched.** If the user has to
  remember to start it, the ambient promise is broken on day one.

### Decision 2 — on Windows, WSL is the primary case, not an edge case

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
                    ┌───────────────┴───────────────┐
                    │  mtmd — the resident engine   │
                    │  versioned JSON over a socket │
                    └──┬────────┬────────┬───────┬──┘
                       │        │        │       │
                   SwiftUI    WinUI 3   Qt 6    mtm CLI
                   (macOS)   (Windows)  (Linux) (all three)
```

**Shared, and must stay shared:** everything that decides *what is true*. All of
it is in `MultiTaskCore` today and none of it is platform-specific once W0
lands. Each UI is a renderer over the same snapshot and the same action set.

**Per-platform**, and each of these is a small, well-understood integration:

| Concern | macOS | Windows | Linux |
|---|---|---|---|
| Popover | `MenuBarExtra` (built) | tray + borderless flyout | `QSystemTrayIcon` + frameless window |
| Deliver a notification | `UNUserNotificationCenter` | WinRT toast | D-Bus `org.freedesktop.Notifications` |
| Global hotkey | `NSEvent` global monitor | `RegisterHotKey` | X11/Wayland portal (`GlobalShortcuts`) |
| Reveal a folder / focus an app | `NSWorkspace` | `explorer.exe`, Win32 | `xdg-open` |
| Autostart the daemon | LaunchAgent | Task Scheduler | systemd user unit |

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

### W1 — Linux CLI as a supported target

Mostly packaging and manners, since the code already runs.

- XDG-correct locations for overrides, runs and the socket.
- Desktop notifications from `mtm watch` via D-Bus, so the CLI is useful with no
  GUI at all — on a headless box this *is* the product.
- Packaging: a tarball first, then `.deb` if it earns one. Not Flatpak — this
  needs the user's real home directory and their repos, which is precisely what
  that sandbox is designed to prevent.
- `--version`, a man page, and shell completions (generated by
  `swift-argument-parser`).

**Done when:** a fresh Ubuntu box can install `mtm`, run `mtm doctor`, and get a
desktop notification when a session goes quiet.

### W2 — `mtmd` as the resident engine, and a documented client contract

**This reverses the earlier recommendation to defer the daemon**, and the reason
is new information rather than a change of mind. That call rested on the
observation that nothing needed a resident process: on macOS the menu-bar app is
always running and hosts the engine itself. With native clients on two more
platforms — one of which is not written in Swift — the daemon becomes the only
place the engine can live. On Windows and Linux it *is* the thing that is always
running.

- Transport adapter behind the existing wire protocol: unix domain socket on
  macOS and Linux; on Windows, `AF_UNIX` is supported on Windows 10 1803+ and is
  the smaller change, with a named pipe as the fallback.
- Single-instance via connect-then-unlink-stale-socket, not launchd/systemd.
- Peer credential check rejecting any uid but our own.
- **A written client contract** — the methods, the payload shapes, the event
  stream, the version gate — because from here on it is consumed by codebases in
  other languages, and "read the Swift source" stops being an answer.

**Done when:** `mtm status` answers from a running daemon on all three
platforms, falls back to in-process when none is installed, and a non-Swift
client can drive it from the written contract alone.

### W3 — Linux GUI (Qt 6)

First native client over the protocol, and deliberately first because the Linux
engine already works — so this phase proves the *pattern* without also debugging
a new engine port.

- `QSystemTrayIcon` with a badge, a frameless popover window, click-away and Esc
  dismissal, and the global hotkey.
- The full fingertip criteria above are the acceptance test for this phase.
- Session list, detail, triage order, settings. The board window comes with P4.6.

**Done when:** a Linux desktop shows the badge, the popover opens under the
hotkey in under 150 ms with correct contents, and no session logic exists
anywhere in the Qt code.

### W4 — Windows engine, with WSL roots

Per decision 2, these are one phase and not two. Headless — no UI yet.

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

### W5 — Windows GUI (WinUI 3)

- Tray icon with a badge — note that Windows has no native numeric badge on a
  tray icon, so it is a rendered overlay, and the tray *overflow* area means the
  icon may not be visible at all unless the user promotes it. First-run should
  say so rather than let the ambient promise fail quietly.
- Borderless flyout anchored to the tray, respecting a taskbar on any edge.
- WinRT toasts, global hotkey via `RegisterHotKey`, autostart via Task Scheduler.
- Same fingertip criteria; same no-logic-in-the-UI rule.

### W6 — Parity, packaging, first-run

- A written per-screen spec so three UIs can be compared against one definition
  rather than against each other.
- Signing and distribution: Developer ID + notarisation (macOS), Authenticode +
  winget (Windows), tarball/`.deb` (Linux).
- First-run per platform, explaining what the app can and cannot see — which on
  Windows means saying plainly whether it found a WSL harness.

---

## Risks

**Feature-parity drift across three UIs is now the top risk**, ahead of any
technical one. It is a slow failure: each platform grows a slightly different
idea of what a session row shows until the design is three designs. The controls
are the dumb-UI rule, the written per-screen spec in W6, and a willingness to
say a platform is a release behind rather than to fork behaviour.

**Swift on Windows is the load-bearing technical bet, but a smaller one than it
was.** Choosing C# for the Windows UI means Swift on Windows only has to run the
*headless* engine and daemon — Foundation, sockets, `Process`, file I/O — with
no UI framework binding involved. That is the part of Swift-on-Windows most
likely to work. The contingency if even that disappoints: reimplement the
detectors in C# against the same documented file formats and keep Swift for
macOS and Linux. Expensive, and worth naming so it is a decision rather than a
scramble. Decide at the end of W0, when the CI matrix has evidence.

**Linux tray icons are genuinely inconsistent.** GNOME has needed an extension
for years. `QSystemTrayIcon` is the most portable option available but it cannot
conjure a tray where the desktop has none. The global hotkey is the mitigation,
and W3 should treat a missing tray as a supported configuration rather than a
broken one.

**Global hotkeys on Wayland require a portal** and cannot be grabbed directly
the way X11 allows. Plan for `org.freedesktop.portal.GlobalShortcuts`, and for
the possibility that a given compositor doesn't implement it.

**Scope.** W0 and W1 are small and deliver a supported Linux CLI. W2 and W3
deliver a native Linux GUI. W4 and W5 are where the real cost is. Stopping after
W3 leaves a coherent product on two platforms, and that is a legitimate place to
stop.

---

## Open questions

1. **Is Windows usage native, WSL, or both?** This plan assumes both with WSL
   primary. If the answer is "native only", W4 roughly halves. If it is "WSL
   only", the Windows *engine* could arguably be the Linux build running inside
   WSL, with only the WinUI client on the Windows side — materially cheaper, and
   worth deciding before W4 starts.
2. **Qt 6 or GTK 4 on Linux?** Recommended Qt 6 on tray-support grounds. Revisit
   if the tray stops being the primary access path, or if libadwaita's look
   matters more than the tray API.
3. **How much of Foundation actually works on Windows** for the specific calls
   this app makes? Answered by the W0 CI matrix, and it decides the W4
   contingency.
4. **Does the macOS popover need to change at all?** It already satisfies the
   fingertip criteria. The risk is that it becomes the reference implementation
   by accident rather than by decision, and the other two get measured against
   an undocumented target.
