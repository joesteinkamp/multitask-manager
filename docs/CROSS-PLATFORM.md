# Cross-platform plan

[ROADMAP.md](../ROADMAP.md) says *what* and *why*. [PLAN.md](PLAN.md) says *how*
for the six feature phases. This says how the same product reaches **Windows,
Linux GUI, and Linux CLI** without becoming three codebases.

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
- **`EngineClient` already separates the engine from its faces**, and the wire
  protocol it would speak across a process boundary is implemented and tested.

So "Linux CLI" is not a port. It is a supported-target and packaging problem,
plus the portability fixes in W0. The genuinely new work is **Windows** and a
**GUI that isn't SwiftUI**.

---

## The two decisions this plan rests on

Everything below follows from these. Both are reversible, but not cheaply, so
they are stated up front rather than discovered in phase four.

### Decision 1 — one shared GUI, served by the daemon; native shells stay thin

**Recommendation: the cross-platform GUI is a local web UI served by `mtmd`,
with a thin native tray and notification shim per platform. macOS keeps its
existing SwiftUI popover.**

The alternatives and why they lose:

| Option | Why not |
|---|---|
| SwiftUI everywhere | Apple-only. Not a real option. |
| Native UI per platform (SwiftUI + WinUI + GTK) | Three UIs to design, build and keep in sync, and the non-Swift ones need a C ABI shim over the engine. Highest cost by a wide margin, for an app whose UI is a list. |
| A cross-platform Swift UI toolkit (SwiftCrossUI, Qt bindings) | Immature relative to what this needs, and a bet on someone else's roadmap for the most visible part of the product. |
| Electron/Tauri app embedding the UI | Reasonable, and compatible with this recommendation — a Tauri shell is one way to *host* the same web UI. Deferred as a packaging choice, not an architecture one. |

The web UI wins because the engine already speaks a versioned JSON protocol,
because one design serves all three platforms, and because the genuinely native
parts of this app are small and specific: a tray icon with a badge, a
notification, and "reveal this folder". Those are the shims. Everything else is
a list, a detail panel, and a board.

**This reverses an earlier decision and should be recorded as such.** The
project previously cut the web app ("the long-run view becomes a window in the
Mac app"). That call was right for what it decided: a *separately hosted web
product* was scope the project didn't need. What returns here is narrower — a
local UI, served by the local daemon, over a loopback socket, as the window the
roadmap already wanted (P4.6). It is the same window, rendered in a way that
works on three platforms instead of one.

### Decision 2 — on Windows, WSL is the primary case, not an edge case

**Recommendation: Windows support reads both native and WSL session roots from
the first release, rather than shipping native-only and adding WSL later.**

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
                    │  mtmd (daemon)                │
                    │  transport adapter + HTTP     │
                    └───┬───────────┬───────────┬───┘
                        │           │           │
                   mtm CLI     web UI      native shell
                  (all three)  (all three)  (per platform)
```

**Shared, and must stay shared:** everything that decides *what is true* —
which sessions exist, what status each has, why it's waiting, what order they
should be picked up in, and when to interrupt the user. That is all in
`MultiTaskCore` today and none of it is platform-specific once W0 lands.

**Per-platform, and should stay small:** four things, and only four.

| Concern | macOS | Windows | Linux |
|---|---|---|---|
| Deliver a notification | `UNUserNotificationCenter` | WinRT toast | D-Bus `org.freedesktop.Notifications` |
| Tray / menu bar presence | `MenuBarExtra` (built) | tray icon + badge | StatusNotifierItem (see risks) |
| Reveal a folder / focus an app | `NSWorkspace` | `explorer.exe`, Win32 | `xdg-open` |
| Autostart the daemon | LaunchAgent | Task Scheduler / Run key | systemd user unit |

The notification split already exists in the right place: the *policy* — edge
detection, debounce, cooldown, coalescing, quiet hours — is platform-neutral and
tested, and only *delivery* is native. W5 adds a `NotificationPresenter`
protocol with three conformances and changes no policy code.

---

## Phases

### W0 — De-Unix-ify the core

Fix the seven verified breakages above, and add the abstraction that stops them
recurring.

- **New `PlatformPaths`** replacing every hardcoded `~/…` in the core: home,
  config, data, cache, and the harness roots. One place that knows about
  `%APPDATA%`, `$XDG_DATA_HOME`, and `~/Library/Application Support`.
- **Path handling that accepts both separators.** `lastComponent`, `expandingTilde`,
  and the wave-attribution token matcher become separator-agnostic. Comparisons
  become case-insensitive on Windows only — a `Path` value type is worth it here
  rather than passing `String` and remembering.
- **A `lines(of:)` helper that splits on `\r\n`, `\n` and `\r` correctly**, used
  by every prose reader in place of `components(separatedBy: .newlines)`. This
  is the fix for breakages 2 and 3, and it wants a fixture with CRLF line
  endings checked in beside the existing ones.
- **Rotation detection that degrades**: use `(device, inode)` where available,
  and fall back to `(creationDate, size)` where it isn't.
- **Git discovery via `PATH`** rather than a candidate list.

**Done when:** `swift test` is green on macOS, Ubuntu and Windows in CI, and
`mtm doctor` runs on all three. Nothing user-visible ships in this phase, which
is precisely why it needs the CI matrix landing alongside it.

### W1 — Linux CLI as a supported target

Mostly packaging and manners, since the code already runs.

- XDG-correct locations for overrides, runs and the socket.
- Desktop notifications from `mtm watch` via D-Bus, so the CLI is useful without
  any GUI at all — for a headless box this *is* the product.
- Packaging: a static-ish tarball first, then `.deb` and an AUR-style recipe if
  it earns them. Not Flatpak — this needs the user's real home directory and
  their repos, which is exactly what Flatpak's sandbox is designed to prevent.
- `mtm --version`, a man page, and shell completions (`swift-argument-parser`
  generates these).

**Done when:** a fresh Ubuntu box can install `mtm`, run `mtm doctor`, and get a
desktop notification when a session goes quiet.

### W2 — `mtmd` as the cross-platform host

**This reverses the earlier recommendation to defer the daemon**, and the reason
is new information rather than a change of mind. That call rested on the
observation that nothing needed a resident process: on macOS the menu-bar app is
always running and hosts the engine itself. On Windows and Linux there is no
such process — the tray shim is a thin client and the web UI has no process of
its own. The daemon *becomes* the thing that is always running, which is the
justification that was missing.

- Transport adapter behind the existing wire protocol: unix domain socket on
  macOS and Linux; on Windows, `AF_UNIX` is supported on Windows 10 1803+ and is
  the smaller change, with a named pipe as the fallback if it disappoints.
- Single-instance via connect-then-unlink-stale-socket, not launchd/systemd.
- Peer credential check rejecting any uid but our own.
- Autostart per the table above.

**Done when:** `mtm status` answers from a running daemon on all three platforms
and falls back to in-process when none is installed.

### W3 — The web UI, and with it the Linux GUI

The daemon serves a loopback HTTP endpoint and the UI as static assets.

- **Loopback only, with an origin check and a per-launch token** — the socket's
  filesystem permissions do not protect an HTTP port, and "it's only localhost"
  is not an access control. Any other machine on the network must get nothing.
- Live updates over server-sent events, driven by the same `subscribe` stream
  and the same change digest, so a quiet machine sends nothing.
- One design, three platforms. This is also P4.6's board window, reached from
  the macOS popover and from `mtm open`.

**Done when:** `mtm open` on Linux shows the session list, updating live, with
no menu bar involved.

### W4 — Windows engine, with WSL roots

Per decision 2, these are one phase and not two.

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
  a launch into a WSL root has to go through `wsl.exe -d <distro>`.
- **File sharing semantics.** Windows refuses to delete or rename a file another
  process holds open. The audit-log tail must open with delete-sharing so it
  cannot block the harness from rotating its own log. Flagged as the highest
  technical risk in this phase.
- Long-path support (`\\?\` prefixes or the manifest opt-in) and case-insensitive
  comparison.

**Done when:** a Windows machine running Claude Code inside WSL shows the same
sessions, statuses and precise joins that Linux does.

### W5 — Native shells and packaging

- Windows tray with badge + WinRT toasts; Linux notifications and, if the
  desktop supports it, a tray.
- Signing and distribution per platform: Developer ID + notarisation (macOS),
  Authenticode + winget (Windows), tarball/`.deb` (Linux).
- First-run setup per platform, explaining what the app can and cannot see —
  which on Windows means saying plainly whether it found a WSL harness.

### W6 — CI matrix, continuously

Starts at W0, not at the end. `macos-latest`, `ubuntu-latest`,
`windows-latest`; `swift build` and `swift test` on all three; the app build
stays macOS-only. A Windows job that is red for a month is worse than no Windows
job, so it lands green with W0 or it doesn't land.

---

## Risks

**Swift on Windows is the load-bearing bet.** It is real and officially
supported, but Foundation has more gaps there than on Linux, and `Process`,
socket and file-sharing behaviour are the specific areas this app leans on. The
contingency, if W4 proves unworkable: keep the engine as a service and write the
Windows client — tray and all — in C# against the documented JSON protocol.
That is *why* the protocol is versioned and language-neutral, and it costs the
Windows tray, not the engine. Decide this at the end of W0, when the CI matrix
has told us how much Foundation actually works, rather than halfway through W4.

**Linux tray icons are genuinely inconsistent.** GNOME has needed an extension
for years. Plan for the tray to be optional on Linux and for the CLI plus
desktop notifications to be the supported path — which W1 delivers anyway.

**Two GUIs on macOS.** Keeping the SwiftUI popover and adding the web window
means two front-ends there. That is deliberate: the popover is the ambient
glance and is already built and good; the window is where planning happens. If
the web UI turns out to be better at both, retiring the popover is a decision to
take *later* with evidence, not to pre-empt now.

**Scope.** This plan touches every layer. W0 and W1 together are small and
deliver a supported Linux CLI; W2 and W3 deliver a Linux GUI; W4 and W5 are
where the real cost is. Stopping after W3 leaves a coherent product on two
platforms, and that is a legitimate place to stop.

---

## Open questions

1. **Is Windows usage native, WSL, or both?** This plan assumes both with WSL
   primary. If the answer is "native only", W4 halves. If it is "WSL only", the
   Windows build could arguably be the *Linux* build running inside WSL with a
   Windows tray shim — a materially cheaper design worth revisiting.
2. **Does the web UI eventually replace the SwiftUI popover?** Deferred
   deliberately; answerable after using both.
3. **How much of Foundation actually works on Windows** for the specific calls
   this app makes? Answered by the W0 CI matrix, and it decides the W4
   contingency.
4. **Is a Tauri/Electron shell worth it** over a browser tab plus a tray shim?
   Only matters if the web UI needs to feel like an application window rather
   than a page.
