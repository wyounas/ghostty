# Ghostty + tmux Control Mode Integration: Progress So Far

This document captures everything done to date so work can resume from a fresh
context window. Read this first, then read the specific documents referenced.

---

## Project Goal

Integrate tmux control mode (`tmux -CC`) into Ghostty so that tmux windows appear
as native Ghostty tabs and tmux panes appear as native Ghostty splits, with native
scrollback, search, and selection — the same experience iTerm2 provides today.

## Repository State

- **Branch:** `smallestmvp` (branched from `main` at commit `0790937d0`)
- **6 source files modified** with diagnostic log additions (92 insertions, 8 deletions)
- **No new features implemented yet** — all changes are observability logs

### Modified source files (Tier 2 log additions)

All log lines use `[full/path/to/file.zig]` prefixes for identification.

| File | Lines changed | What was added |
|------|--------------|----------------|
| `src/termio/Exec.zig` | +3 | `[GHY:PTY:READ]` — byte count on each PTY read (log.debug, compiled out in release) |
| `src/terminal/Parser.zig` | +7 | `[GHY:VT:DCS]` — DCS passthrough entry with params and final byte |
| `src/terminal/dcs.zig` | +17/-3 | `[GHY:DCS:HOOK]` tmux detection, `[GHY:DCS:PUT]` notification emissions, `[GHY:DCS:HOOK]` unhook |
| `src/terminal/tmux/control.zig` | +9 | `[GHY:TMUX:PARSE]` %begin→block and block→idle transitions with output_len |
| `src/terminal/tmux/viewer.zig` | +36 | `[GHY:TMUX:VIEWER]` state transitions, session_changed, terminal_created, output_routed, command response type, defunct |
| `src/termio/stream_handler.zig` | +28/-5 | `[termio/stream_handler.zig]` prefix on existing logs + `[GHY:TMUX:CMD]` command text, `[GHY:TMUX:WIN]` windows data + DROPPED annotation, viewer_created/destroyed |

### Build process (macOS)

Zig is at `/Users/neurotone/.local/bin/zig` (symlinked from `/Users/waqas/.local/bin/zig`), version 0.15.2.

```bash
# Step 1: Build the Zig library
zig build -Demit-macos-app=false -Dxcframework-target=native

# Step 2: Build the macOS app via Xcode
cd macos && xcodebuild -project Ghostty.xcodeproj -scheme Ghostty -configuration Debug build && cd ..

# The built app is at:
# /Users/neurotone/Library/Developer/Xcode/DerivedData/Ghostty-evflucexkfdaebbprpcrpwgptgnt/Build/Products/Debug/Ghostty.app
```

### Running the experiment

```bash
# Config
mkdir -p ~/.config/ghostty
echo 'command = tmux -CC new-session -s mvp' > ~/.config/ghostty/config

# Clean
tmux kill-server 2>/dev/null

# Launch (GHOSTTY_LOG=stderr is REQUIRED on macOS — lib mode disables stderr by default)
GHOSTTY_LOG=stderr /path/to/Ghostty.app/Contents/MacOS/ghostty 2>ghostty.log &

# Wait for handshake, interact, kill, clean up config
```

---

## What Was Learned: The Findings

### The tmux control mode pipeline works end-to-end

Empirically verified in 3 experiment runs (April 3, 5, 6, 8). The complete data
flow from tmux → Ghostty is:

```
tmux stdout → PTY fd → Exec.zig read loop → Parser.zig VT parser →
dcs.zig DCS handler → control.zig tmux protocol parser →
stream_handler.zig → viewer.zig Viewer state machine → returns Actions
```

The write path (Ghostty → tmux) is:
```
viewer.zig returns .command Action → stream_handler.zig calls messageWriter() →
mailbox → IO thread → Exec.zig queueWrite() → PTY → tmux stdin
```

### The exact gap

At `src/termio/stream_handler.zig:456` (on main branch):

```zig
.windows => {
    // TODO
},
```

The Viewer emits `.windows` actions with correct window/pane data. The stream
handler drops them. No Surface is created. The Viewer continues unaware.

### The architectural constraint

`src/termio/backend.zig:14` defines `Kind = enum { exec }` — only one Backend
kind. `src/Surface.zig:679` hardcodes `.backend = .{ .exec = io_exec }`. The
renderer reads from `renderer_state.terminal = &self.io.terminal`
(`Surface.zig:608`) — a pointer fixed at Surface init. A tmux Surface needs its
own Termio with its own Terminal. Content must be copied from the Viewer's Terminal,
not shared by reference.

### Key surprises from experiments

1. `GHOSTTY_LOG=stderr` is REQUIRED on macOS (lib mode disables stderr logging by default)
2. The startup sequence includes `%window-add` and `%sessions-changed` BEFORE `%session-changed` — the Viewer silently drops these
3. `%output` interleaves freely between command-response pairs (H3 confirmed)
4. Zig's `{any}` formatter renders Window struct fields as garbled numbers — but the actual data is correct
5. `control.zig` is completely silent on the happy path for `%output` (single-line notifications don't go through %begin/%end blocks)
6. The subprocess is `/usr/bin/login`, not tmux directly — Ghostty wraps the command

---

## Documents Created

### Research and Planning (in `docs/`)

| Document | Purpose | Key content |
|----------|---------|-------------|
| `docs/overview_1_5.md` | Foundations of tmux and control mode | Protocol spec, escaping rules, flow control, ID system |
| `docs/overview_6_14.md` | Deep code analysis (sections 6-14) | File-by-file inventory, protocol coverage matrix, gap identification, maintainer summary |
| `docs/dataflow.md` | Data flow diagrams | iTerm2 reference flows + projected Ghostty flows |
| `docs/diagrams.md` | Technical diagrams | Parser state machine, Viewer state machine, DCS-to-pixels pipeline, command-response sequence |
| `docs/plan.md` | Learning plan for junior engineers | 3 learning approaches with milestones + terminal/Zig primer |
| `docs/prose.md` | File-by-file walkthrough in plain prose | Every file in the integration, explained for non-terminal-engineers |
| `docs/firstmvp.md` | **First engineering task specification** | Problem statement, assumptions with stress-tests, 5 sub-task PR breakdown, maintainer questions, what comes next |
| `docs/surfaces_and_backends.md` | Surface and Backend explainer | What they are, why separate, how they work, 12 Q&A for junior engineers |
| `docs/progress.md` | This file | Resume point for fresh context |

### Experiment Results (in `smallestmvp/`)

| Directory | What happened | Key files |
|-----------|-------------|-----------|
| `smallestmvp.md` | Master experiment plan | Hypotheses H1-H7, setup instructions, Tier 1/2 specs, log placement spec |
| `smallestmvp/verify.sh` | Automated hypothesis verification script | Tests all 7 hypotheses + 5 Tier 2 checks against a log file |
| `smallestmvp/tier1_april5/` | Tier 1 run (April 5, Debug build, `[stream_handler.zig]` prefix added) | `ghostty.log` (157 lines), `postmvp.md`, `sequence_diagram.md` |
| `smallestmvp/tier2/` | Tier 2 run (April 6, all 6 files instrumented) | `ghostty.log` (284 lines, 97 GHY lines), `postmvp.md`, `sequence_diagram.md` |
| `smallestmvp/tier2_04_08/` | Enhanced Tier 2 (April 8, control.zig + viewer command responses added) | `ghostty.log` (365 lines, 165 GHY lines, all 7 files visible), `postmvp.md`, `sequence_diagram.md` |
| `smallestmvp/postmvp.md` | First post-experiment analysis (April 3) | Start-to-finish story, Q&A (VT/PTY tutorials, Viewer role, etc.) |
| `smallestmvp/actual_sequence.md` | Sequence diagram from April 3 run | Full 42-line log traced as ASCII sequence |

---

## The First MVP Plan (docs/firstmvp.md)

### Problem

Ghostty cannot create a Surface backed by anything other than a subprocess PTY.
The Backend union only has `.exec`. The Viewer's `.windows` action is dropped.

### Solution

Add a `.tmux` Backend kind that enables Surfaces whose content comes from the
Viewer's Terminal instances rather than from a subprocess.

### 5 Sub-tasks

1. **Add `.tmux` to Backend Kind enum** — `backend.zig` (~25 lines)
2. **Fix all switch sites** — add `.tmux` arms to every exhaustive switch (~15 lines)
3. **Create `Tmux.zig` stub** — new file with no-op Backend methods (~30 lines)
4. **Wire `.windows` to create a Surface** — `stream_handler.zig` + `Surface.zig` (~30 lines)
5. **Populate with captured content** — copy Viewer's Terminal content to Surface (~15 lines)

### Success criteria

Running `tmux -CC new-session` causes a second Surface to appear showing pane %0's
content. Read-only, static snapshot, rendered by Ghostty's native GPU pipeline.

### Blocker questions for maintainer

1. Is a new Backend Kind the right approach? (vs. different mechanism entirely)
2. Should Terminals be copied, shared, or transferred?
3. Where should Surface creation be triggered? (stream_handler vs. apprt)

### What comes after

- **Next 1:** Live output routing — forward `%output` to Surface's Terminal (~30-50 lines)
- **Next 2:** Input routing — translate keystrokes to `send-keys` commands (~40-60 lines)
- **Then:** Resize, multi-pane, window close, flow control, session reattach

---

## Verified Code Citations (April 8, 2026)

These line numbers were verified against actual source on the `smallestmvp` branch.
Note: some lines shifted from `main` due to our log additions.

| What | File | Line (main) | What's there |
|------|------|-------------|-------------|
| Backend Kind enum | `src/termio/backend.zig` | 14 | `pub const Kind = enum { exec };` |
| Backend union | `src/termio/backend.zig` | 24 | `pub const Backend = union(Kind) { exec: termio.Exec, ... }` |
| Renderer → Terminal pointer | `src/Surface.zig` | 608 | `.terminal = &self.io.terminal` |
| Backend hardcoded to exec | `src/Surface.zig` | 679 | `.backend = .{ .exec = io_exec }` |
| Termio owns Terminal | `src/termio/Termio.zig` | 41 | `terminal: terminalpkg.Terminal` |
| Backend.initTerminal called | `src/termio/Termio.zig` | 282 | `backend.initTerminal(&term)` |
| THE GAP (on main) | `src/termio/stream_handler.zig` | 456-458 | `.windows => { // TODO }` |
| Viewer state machine entry | `src/terminal/tmux/viewer.zig` | 314 | `pub fn next(self: *Viewer, input: Input) []const Action` |
| Viewer Terminal creation | `src/terminal/tmux/viewer.zig` | 1152 | `var t: Terminal = try .init(gpa_alloc, ...)` |
| Viewer output routing | `src/terminal/tmux/viewer.zig` | 1109 | `fn receivedOutput(self: *Viewer, id: usize, data: []const u8)` |
| DCS tmux detection | `src/terminal/dcs.zig` | 54-61 | `'p' => tmux: { if (dcs.params[0] != 1000) ... }` |
| Read thread | `src/termio/Exec.zig` | 1257 | `fn threadMainPosix(fd, io, quit)` |
| C API surface creation | `src/apprt/embedded.zig` | 1541 | `export fn ghostty_surface_new(app, opts) ?*Surface` |

---

---

## April 9, 2026 — Document Review and Improvements

### What was done

**1. `docs/surfaces_and_backends.md` — Major expansion (4 new sections)**

- **"Journey: What happens when you type the letter 'a'?"** — 6-phase walkthrough
  tracing a keystroke from Cocoa event → apprt → Surface.keyCallback → encode →
  mailbox → IO thread → exec Backend → PTY → shell → PTY read → VT parser →
  Terminal → renderer → Metal GPU → pixels. Each phase names the specific Surface
  component and cites file:line numbers.

- **"Why is a Renderer needed? How Metal works on macOS"** — Explains renderer
  purpose, the wakeup-based threading model, and Metal specifics (IOSurfaceLayer,
  triple buffering, render pipeline steps, font atlas, presentation).

- **Surface creation steps expanded** — The old 7-step list was broken into 10
  sub-steps (2a–2j) with exact line numbers, covering: conditional state, DPI
  calculation, font grid caching, size/padding, Termio.init internals, initial
  actions, and thread spawning order.

- **tmux control mode section rewritten** — Startup sequence verified from
  experiment logs. Added: file-per-change table, `%output` flow diagram through
  7 components, two-mutex problem explanation, and a full ASCII sequence diagram
  showing startup → surface creation → steady-state → future input across 5 actors.

**2. `docs/firstmvp.md` — Senior engineer review + corrections**

Factual corrections applied:
- Backend/VT parser ownership clarified (Backend doesn't run VT parser; StreamHandler does)
- Line numbers fixed: `stream_handler.zig:456` → `468`, `Exec.zig:141` → `139-143`
- Switch site locations corrected: all 9 switches are in `backend.zig`, not in
  `Termio.zig` or `Thread.zig` (those delegate to Backend methods)
- Renderer thread sharing claim corrected: each Surface has its OWN renderer thread
- Two-mutex concurrency issue identified and documented in Section 6

Architectural improvements:
- **A3 reframed**: "copy Terminal state" → "feed VT bytes via processOutput()"
  (simpler, consistent with exec path, extends to live `%output`)
- **Sub-task 4 expanded from ~30 lines to ~95-115 lines**: identified the
  cross-thread gap (no mailbox message exists for Surface creation), the C ABI/Swift
  bridge implications, three candidate mechanisms with pros/cons
- **Sub-task 5 rewritten** to use VT byte forwarding instead of Terminal state copy
- **Q2 and Q3 upgraded**: Q2 now asks byte-feeding vs copying; Q3 frames the
  cross-thread mechanism as the hardest problem with 3 concrete options

Key invariants added to each sub-task:
1. **Union tag symmetry** — comptime assert that Kind/Backend/Config/ThreadData
   variant counts match
2. **No unreachable in switches** — every `.tmux` arm has a real implementation
3. **No PTY/process/fd in Tmux.zig** — comptime `@hasField` assertions +
   runtime `assert(td.backend == .tmux)` mirroring Exec pattern
4. **Surface.init on main thread only** — `NSThread.isMainThread` assertion at
   creation site; comment invariant in stream_handler
5. **Terminal mutated only through owning Termio's processOutput** — mailbox-based
   forwarding, never direct cross-thread Terminal writes

**3. `docs/subtask4.md` — New tutorial (Sub-task 4 deep dive)**

A 10-part from-first-principles tutorial covering:
- What threads are and why Ghostty uses them
- Ghostty's 4-thread model (main, renderer, IO, read) with ASCII diagram
- **Proof** of what thread `.windows` runs on: 9-step synchronous call chain
  from `posix.read()` → `processOutput()` → VT parser → DCS → tmux control →
  Viewer → `.windows` handler, all on the read thread ("io-reader"), with the
  renderer_state.mutex held throughout
- Why Surface.init() can't run on the read thread (GPU context, NSView, app state)
- What the main thread is (macOS creates it, Ghostty hooks in via wakeup callback
  → `ghostty_app_tick()` → `App.tick()` → `drainMailbox()`)
- What surface_mailbox is (creation site, message flow chain, all 22 message types,
  lifecycle)
- What performAction is (Zig → C ABI → Swift bridge for `new_window`)
- The threading problem visualized (ASCII diagram of read thread constraints)
- Three implementation options analyzed with code sketches (new surface message,
  new app message, reuse performAction)
- Complete sequence diagram of the flow after implementation

### Key finding from the review

**Sub-task 4 is the hardest task in the MVP** — not because of code volume, but
because no cross-thread mechanism exists to request Surface creation from the IO/read
thread. The surface_mailbox has ~22 message types, none of which create Surfaces.
`performAction(.new_window)` dispatches synchronously on the main thread. A new
message path must be created, potentially touching the Swift side via the C ABI.
This is likely what Mitchell meant by "pretty fundamentally hard."

### Updated line number citations (April 9, verified on smallestmvp branch)

| What | File | Line | Notes |
|------|------|------|-------|
| THE GAP (on branch) | `src/termio/stream_handler.zig` | 468-476 | `.windows` handler with MVP logs (shifted from 456 on main) |
| Viewer receivedOutput | `src/terminal/tmux/viewer.zig` | 1116 | `fn receivedOutput(` (was ~1109 in some docs) |
| Read thread spawn | `src/termio/Exec.zig` | 139-143 | `std.Thread.spawn(ReadThread.threadMainPosix)` |
| Viewer `.user` command | `src/terminal/tmux/viewer.zig` | 813 | `.user => {},` (exists but is a no-op) |
| Surface.init main thread doc | `src/Surface.zig` | 464 | "must be called from the main thread" |
| IO thread spawn | `src/Surface.zig` | 730-734 | `std.Thread.spawn(termio.Thread.threadMain)` |
| Renderer thread spawn | `src/Surface.zig` | 722-726 | `std.Thread.spawn(rendererpkg.Thread.threadMain)` |
| App.tick/drainMailbox | `src/App.zig` | 129-131, 237-265 | Main thread message processing |
| ghostty_app_tick | `src/apprt/embedded.zig` | 1425-1428 | C API entry for main thread tick |
| surface_mailbox type | `src/apprt/surface.zig` | 134-155 | `Mailbox` struct with push() → app mailbox |
| surface Message variants | `src/apprt/surface.zig` | 14-110 | ~22 message types, none create Surfaces |
| performAction (embedded) | `src/apprt/embedded.zig` | 264-286 | Crosses C ABI to Swift via opts.action() |

### Documents updated or created

| Document | Action | What changed |
|----------|--------|-------------|
| `docs/surfaces_and_backends.md` | Updated | +4 new sections (journey, renderer, expanded creation, tmux rewrite) |
| `docs/firstmvp.md` | Updated | Corrections, Sub-task 4 expansion, invariants, Q2/Q3 improvements |
| `docs/subtask4.md` | **Created** | Sub-task 4 deep dive tutorial (threads, mailboxes, performAction) |
| `docs/progress.md` | Updated | This entry |

---

## How to Resume

1. Read this document (`docs/progress.md`)
2. Read `docs/firstmvp.md` for the implementation plan
3. Read `docs/surfaces_and_backends.md` for architectural context
4. Read `docs/subtask4.md` for the Sub-task 4 threading deep dive
5. Optionally read `smallestmvp/tier2_04_08/postmvp.md` for the latest experiment analysis
6. Check `git diff --stat` to see current source modifications
7. The 3 blocker questions for the maintainer (in firstmvp.md §7) should be
   answered before starting Sub-task 3. Sub-tasks 1-2 are safe regardless.
8. Sub-task 4 is the hardest — read `docs/subtask4.md` before attempting it.
