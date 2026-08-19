# Design Brief

> Read this before your first edit to a component, a view, or a token file. `DESIGN.json`
> holds the exact values; this file explains what they are for and which patterns are already
> decided. Drift here is invisible — the output looks fine and is only wrong against a standard
> nobody re-reads.

**Status:** written against the interface as built, not ahead of it. Where a decision has not
been made yet it says so under [Open decisions](#open-decisions) instead of guessing.

---

## The one thing this interface is for

Someone is running five projects in parallel with AI agents and cannot hold the state of all
five in their head. They open this to answer one of three questions, in this order:

1. **Is anything waiting on me?** — an agent asking permission, a session stuck on a question.
2. **What should I do next?** — ranked, with the reason for the ranking.
3. **What is the state of everything?** — the projects, and what each needs.

Every layout decision below follows from that ordering. The interface is read in a **glance,
while thinking about something else** — usually about the work in another window. That is the
constraint that rules out most of what would otherwise be reasonable: anything that needs
studying, anything that moves, anything that requires a second click to become informative.

### The attention hierarchy

The order is fixed, and it is not negotiable per-feature:

| Rank | Section | Why it outranks the next one |
|---|---|---|
| 1 | **Asks** — agents requesting permission | An agent is *stopped* until you answer. Every minute costs idle work, not just your attention. |
| 2 | **Next up** — ranked work, with reasons | The decision, before the context. |
| 3 | **Projects** — status and what each needs | The context for the decision. |
| 4 | **Runs** — what's executing, how it ended | Reference. Nothing here is asking for anything. |
| 5 | **Degraded** — what the app can't see | "Nothing is running" and "I can't see anything" must read differently. |

Asks are the **only** section with a coloured, bordered treatment. That is not emphasis for
its own sake, and it does not generalise: it is the only section where the cost of not looking
is measured in someone else's idle compute rather than in your own attention.

---

## Tokens

`DESIGN.json` is the source. `Packages/MultiTaskCore/Sources/MultiTaskCore/Design/DesignTokens.swift`
is **generated** from it by `Scripts/generate-tokens.py`, and `DesignTokensTests` fails if the
two disagree.

```
DESIGN.json  ──generate-tokens.py──▶  DesignTokens.swift  ──▶  AppTheme (SwiftUI)
                                       (Foundation only)   └─▶  Windows client
```

**Why generated rather than hand-written twice.** This product ships a macOS client and a
Windows client from one engine. Two hand-maintained constant files do not drift dramatically —
they drift by two points of padding and one shade of orange, which nobody notices until the two
apps sit side by side, and by then both have shipped. The generator makes that a red test.

To change a value: edit `DESIGN.json`, run `python3 Scripts/generate-tokens.py`, commit both.

### Spacing

A 4pt base, with 2 and 6 as half steps: `hair 2 · tight 4 · row 6 · group 8 · section 12 · loose 16`.

The half steps are real. A menu bar list is genuinely dense, and before this scale existed the
views had invented 1, 3, 5, and 10 between them — which is what happens when the available
steps don't fit the work. **Stay on the scale.** A one-off value is a value some later
component has to reconcile against.

### Type

**Semantic system fonts for everything a person reads** — `headline`, `callout`, `caption`,
`caption2`, mapped through `AppTheme`. Not a point-size ramp.

This is a deliberate choice, not a shortcut. On macOS the semantic fonts follow the user's
text-size and accessibility settings; a menu bar utility that pins text to 11pt is unusable for
exactly the people who change those settings. Explicit sizes exist for two things only, and
neither is prose:

- **Monospaced detail** (11pt / 10pt) — a command, a path, a flag. Monospaced because
  misreading a flag is the failure this text exists to prevent, and it is shown selectable so
  it can be copied rather than retyped.
- **Glyph** (9pt) — the `ellipsis` menu affordance. A glyph, not text.

### Colour

`DESIGN.json` defines **roles**, and each platform maps a role to its own system colour:

| Role | Means | macOS |
|---|---|---|
| `attention` | Something is waiting on the person. The only role permitted to interrupt. | `systemOrange` |
| `working` | Progressing on its own. No action wanted. Shares the accent with `ready` on purpose: neither asks anything of you, and the glyph separates them. | `controlAccentColor` |
| `complete` | Finished. Worth seeing, not waiting on you. Green belongs here — it reads as *done* everywhere else in software, which is why using it for work in progress was a mistake. | `systemGreen` |
| `ready` | Available to pick up. | `controlAccentColor` |
| `idle` | Stopped with nothing queued. Noticed, never interrupting — orange stays the only role permitted to interrupt, so this reads as waste rather than as a question. Distinct from `dormant`, which is the same absence after a week and is genuinely not urgent. | `systemYellow` |
| `blocked` | Waiting on something impersonal — a dependency, another task. | `systemPurple` |
| `dormant` | Quiet with nothing ready. Reported, never highlighted. | `secondaryLabelColor` |
| `unknown` | The app cannot tell. Distinct from 'nothing is happening'. | `tertiaryLabelColor` |

**System colours, not a custom palette.** System colours already satisfy contrast in light and
dark, already respond to Increase Contrast, and already look native beside every other menu bar
item. A hand-picked orange would have to re-earn all of that, and would fail quietly for the
users who need it most. The hex values in `DESIGN.json` are for platforms with no system
equivalent and for documentation — never the preferred source on macOS.

**Colour is never the only signal.** Every status carries a glyph as well as a colour
(`ProjectStatus.symbolName`), because a status list that is only distinguishable by hue is
unreadable for a large minority of users and illegible in a screenshot.

### Motion

Almost none, and that is the design. `refresh` is **0**: nothing animates when data changes. A
row that slides because a number changed makes a list that updates every few seconds feel
unreliable, and this list is read in a glance. Only direct manipulation animates — a disclosure
opening (0.15s), a sheet presenting (0.2s) — and both must be skipped under reduced motion.

---

## Patterns already decided

**Decide in place.** A request is answerable from the row it appears on: Approve and Decline
are buttons on the row, not a sheet you open first. The entire value of a menu bar app is that
the decision happens where you already are; a row that makes you open a window has spent the
advantage it exists to provide.

**A confirmation shows the engine's own words.** The run sheet displays exactly the summary and
detail lines the engine returned, and sends back the token that came with them. The app never
composes its own description of what will happen — the text a person agrees to and the command
that runs must come from one source, and the only way to guarantee that is not to have a second
one. The command is shown **in full and selectable**, not elided: it is long, but this is the
last moment to notice that the brief says something you didn't mean.

**Spending is never the default action.** Neither Approve nor Run takes the Return key. A
popover appears under whatever you were already typing into, and a button that fires on a stray
Return is not a confirmation. Cancel is the escape action; there is no keyboard shortcut that
spends.

**Say why, always.** A ranking shows its reason, a status shows what produced it, a decline
carries a note the agent reads. A ranking you cannot interrogate is one you stop trusting, and
an unexplained status is one people work around.

**A failure stays on screen.** When an action fails, the row keeps its place and shows the
reason. A row that disappeared would read as success.

**Output is a file, not an in-app terminal.** "Open output" hands a log to whatever the user
reads logs with. Building a terminal emulator is a great deal of work to end up worse than the
one already on the machine.

**Optional beats mandatory for anything that improves quality.** The acceptance line on a task,
the reason on a decline: both are prompted for and neither is required. A capture box you have
to fill in properly is one people route around, and half-captured work still beats forgotten
work.

---

## Accessibility

The WCAG commitment lives in `PRODUCT.md`; these are the rules that bind this interface.

- **Contrast** comes from using system colours; do not override them with custom hexes, which is
  how a compliant interface silently stops being one.
- **Never colour alone.** Pair every status colour with a glyph or a word.
- **Reduced motion** must be honoured for the two animations that exist. There is no animation
  worth an exception here.
- **Keyboard.** Every action reachable by mouse is reachable by keyboard, with a visible focus
  ring. The one deliberate exception is that no shortcut *spends* — see above.
- **Hit targets.** Buttons use `controlSize(.small)`, not custom hit areas smaller than the
  system minimum. A dense list is not a licence for 12pt tap targets.
- **Text scales.** Because type is semantic, the interface follows the system text size. Do not
  add a fixed-height container that clips when it grows.

---

## Anti-patterns — banned in this interface

Non-negotiable. If asked for one anyway, push back once with a concrete alternative; if the
answer is still yes, comply and flag the trade-off.

- **A hero metric.** "12 sessions running" as a large number is the least useful thing on the
  screen. The question is never how many, it is which one needs you.
- **A grid of identical cards.** Projects differ in what they need. A uniform card grid flattens
  exactly the difference the interface exists to show.
- **Purple-for-AI.** The category reflex. `blocked` uses purple for an unrelated, stated reason;
  nothing uses purple to signify "AI".
- **A modal for anything routine.** Modals are for confirming spending, and nothing else.
- **Animation on refresh.** See Motion.
- **Colour as the only signal.** See Accessibility.
- **A progress bar for something with no known duration.** An agent's run has no measurable
  progress; a bar that advances on nothing is a lie. Show elapsed time and what it last did.
- **A badge count nobody can act on.** The menu bar badge counts things that need a decision.
  It must never count "things that exist".
- **Ornament.** Gradients, shadows, decorative dividers, emoji as section markers. This is a
  utility read in a glance; every element earns its place by carrying information.
- **A second bordered, tinted block.** Asks are the only one. A design where two things shout
  has nothing that shouts.
- **Inventing a token.** A spacing value, radius, or colour that is not in `DESIGN.json`. Add it
  to the source and regenerate, or use the scale.

---

## Open decisions

Not yet decided, and not guessed at here. Each needs a call before the work it blocks:

- **The menu bar icon.** Currently `bell.badge.fill` / `square.stack.3d.up.fill` — SF Symbols
  placeholders. A product that lives permanently in the menu bar needs its own mark, and it is
  the one piece of visual identity a utility genuinely has.
- **App icon and any wordmark.** Same reasoning, blocking nothing until release.
- **Density preference.** Whether the row height should be user-adjustable, or whether one
  well-chosen density is better than a setting nobody finds.
- **The long-run window.** `ROADMAP.md` has this as a window rather than a web view. Its layout
  is undecided; it is not a wider popover.
- **Windows type ramp.** Which WinUI styles the four type roles map to. The roles exist; the
  mapping does not.
