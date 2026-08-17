# Claude Code Instructions

@AGENTS.md

> This file is a thin pointer. It imports `AGENTS.md` — the project's entry point, which routes to the briefs (`PRODUCT.md`, `DESIGN.md`, `CODE.md`, `WRITING.md`) — and adds Claude-Code-specific notes below. Shared rules belong in `AGENTS.md` so Codex, Cursor, Antigravity, and every other agent see the same source of truth. This file is derived: edit the briefs, not this file.

## Starter-pack flows in this project

`project-starter-pack` exposes every flow as a skill, so natural language triggers them. Installed as a Claude Code plugin, three commands are the whole surface — generate, seed, check:

- `/starter:setup [product|design|code|all]` — guided flow through the briefs, then wires up `AGENTS.md` and this file. With no scope word it asks which briefs to run.
- `/starter:extract` — reverse-engineer draft briefs from an existing codebase (brownfield).
- `/starter:validate` — check the briefs for contradictions and review the repo against them.

Every flow, including the three briefs (which have no command of their own), also auto-triggers as a skill when the user describes the matching work:

- `setup` — fires on "set up this project", "run the starter pack".
- `product-brief` — (re)generates `PRODUCT.md`; fires on "set up product context", "write PRODUCT.md", etc.
- `design-brief` — (re)generates `DESIGN.md` (UX + UI) and the `WRITING.md` companion; fires on "design system", "UX foundation", "DESIGN.md", "writing rules".
- `code-brief` — (re)generates `CODE.md`; fires on "tech stack", "CODE.md", "architecture decisions".
- `validate` — fires on "check the briefs", "review against DESIGN.md", "find anti-patterns in the repo".
- `extract` — fires on "extract the briefs", "brownfield", "reverse engineer the design system".

## Project-specific Claude notes

**`DESIGN.json` is generated-from, not edited-alongside.** It is the single source for every
constant both interfaces share, and
`Packages/MultiTaskCore/Sources/MultiTaskCore/Design/DesignTokens.swift` is generated from it by
`Scripts/generate-tokens.py`. Edit the JSON, run the script, commit both — `DesignTokensTests`
and a CI step both fail if they disagree. This is the mechanism that keeps the macOS and Windows
UIs from drifting, since two hand-maintained constant files drift by two points of padding at a
time, which nobody notices until the apps sit side by side.

The Swift package lives at `Packages/MultiTaskCore` and is built and tested with a Linux
toolchain (`swift test` from that directory).

**The app is migrated onto the package but has never been compiled.** Every app file imports
`MultiTaskCore` and no model or detector is duplicated any more — what remains in the app target
is views, the view model, and four genuinely platform-specific pieces (`NSWorkspace`,
`ServiceManagement`, `UserNotifications`, `UserDefaults`). Every file parses with `swiftc -parse`
on Linux, which catches syntax and nothing else; type-checking SwiftUI needs a Mac, so expect the
first Xcode build to surface real errors.
