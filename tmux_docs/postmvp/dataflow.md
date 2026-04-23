# Ghostty tmux Control Mode After The First MVP

This document replaces the old projected diagrams in `tmux_docs/dataflow.md`
with diagrams of what the code does after the first MVP landed.

The key rule for reading this file is simple:

- the **source surface** is the original Ghostty window that launched `tmux -CC`
- the **child surface** is the extra Ghostty window created by the MVP
- the source surface still uses the normal `exec` backend
- the child surface uses the new `tmux` backend

## 1. The Big Picture After The MVP

```
                           tmux server
                                │
                                │ control-mode bytes
                                ▼
                  ┌───────────────────────────────┐
                  │ Source Ghostty Surface        │
                  │ backend = .exec               │
                  │                               │
                  │ PTY + subprocess + tmux -CC   │
                  │ DCS parser + control parser   │
                  │ Viewer state machine          │
                  └──────────────┬────────────────┘
                                 │
                                 │ .windows action
                                 ▼
                       App/main-thread handoff
                                 │
                                 ▼
                  ┌───────────────────────────────┐
                  │ Child Ghostty Surface         │
                  │ backend = .tmux               │
                  │                               │
                  │ no PTY                        │
                  │ no subprocess                 │
                  │ own Termio + own Terminal     │
                  │ seeded from pane snapshot     │
                  └───────────────────────────────┘
```

What this MVP proves:

- Ghostty can create a visible surface that is not PTY-backed.
- The tmux control-mode data can cross from the source surface to a child
  surface.
- The child surface can render a tmux pane snapshot with Ghostty's normal
  renderer.

What it does not yet prove:

- live forwarding of later `%output` into the child surface
- input from the child surface back to tmux
- native multi-pane layout recreation
- resize feedback into tmux

## 2. Why A New Backend Was Necessary

Before the MVP, every surface in Ghostty assumed this shape:

```
Surface
  └── Termio
        └── Backend = .exec
              ├── PTY
              ├── subprocess
              └── read thread
```

That model fits a normal shell. It does not fit a tmux snapshot window.

The MVP adds a second backend kind because the child surface still needs all the
usual Ghostty machinery:

- its own `Surface`
- its own `Termio`
- its own `Terminal`
- its own renderer thread
- its own IO thread

But it does **not** need:

- a PTY
- a child process
- an exec read thread

So the two backends now mean:

```
.exec backend                           .tmux backend
────────────                           ─────────────
Owns PTY                               Owns pane id only
Owns subprocess                        No subprocess
Spawns read thread                     No read thread
Reads bytes from PTY                   Accepts injected bytes
Writes bytes to PTY                    queueWrite is a no-op in MVP
Used by the source surface             Used by the child surface
```

This is why a new backend is the right shape for the MVP: it keeps the existing
surface/termio contract, but swaps out only the part that was tied to PTY I/O.

## 3. Threads After The MVP

The easiest way to get lost in this code is to mix up the threads. There are now
threads for both the source surface and the child surface.

```
MAIN / APP THREAD
  │
  │ drains App mailbox
  │ creates the child window
  │
  ├─────────────────────────────────────────────────────────────┐
  │                                                             │
  ▼                                                             ▼
SOURCE SURFACE                                            CHILD SURFACE
backend = .exec                                           backend = .tmux

renderer thread                                           renderer thread
  draws source surface                                      draws child surface

IO thread                                                 IO thread
  handles mailbox writes, resize, focus                     handles injected snapshot bytes
  spawns source read thread                                no read thread is spawned

read thread
  blocks in posix.read()
  calls Termio.processOutput()
  runs tmux DCS/control/viewer path
  receives `.windows`
```

The important distinction is this:

- The **source read thread** is where tmux control-mode bytes are parsed.
- The **source IO thread** is a different thread. It handles mailbox-driven work.
- The **main/app thread** is where a new surface/window is actually created.
- The **child IO thread** is where the child surface consumes its injected
  snapshot bytes.

If you prefer the "inner thread" and "outer thread" language:

- the **inner thread** is the source surface's exec read thread
- the **outer thread** is the source surface's IO thread, which spawned it

So when you ask "why not create the child surface directly when `.windows`
arrives?", the answer is: because `.windows` arrives on the **source read
thread**, and `Surface.init()` must run on the **main/app thread**.

## 4. What Changed, By Layer

```
tmux control bytes
  │
  ▼
src/termio/stream_handler.zig
  now handles `.windows`
  now handles `.pane_snapshot`
  now asks the app thread to create a tmux child window
  now stores and flushes snapshot data through the source surface

src/App.zig
  adds `.new_tmux_window` app-mailbox message
  turns that into `.new_window_with_surface_config`

src/apprt/action.zig
  adds a runtime action that can carry a full surface config payload

src/apprt/surface.zig
  defines `SurfaceConfig`
  adds `backend = .exec | .tmux`
  adds tmux MVP metadata fields
  adds `tmux_mvp_target_ready` and `tmux_mvp_target_closed`

src/apprt/embedded.zig
  receives `SurfaceConfig`
  sets child width/height from tmux cols/rows
  calls `Surface.init(..., .tmux_mvp = ...)`
  notifies the source surface when the target is ready

src/Surface.zig
  accepts `InitBackend = .exec | .tmux_mvp`
  can create a `.tmux` backend instead of `.exec`
  marks tmux child surfaces read-only
  stores pending snapshot bytes
  flushes snapshot bytes into the child IO thread

src/termio/backend.zig
  adds `.tmux`

src/termio/Tmux.zig
  adds the tmux backend stub
  no PTY, no subprocess, no read thread

src/termio/message.zig
  adds `.process_output`

src/termio/Thread.zig
  handles `.process_output` by calling `io.processOutput()`

src/terminal/tmux/viewer.zig
  still emits `.windows`
  now also emits `.pane_snapshot`

src/terminal/tmux/layout.zig
  adds `firstPane()` so the MVP can pick the first pane of the first window
```

One subtle but important point:

- `viewer.zig` still builds full internal pane state for tmux.
- The MVP does **not** expose all of that to the child surface.
- The MVP only creates one child window for the **first pane of the first
  window**, and it seeds that child with one snapshot payload.
- "first pane" here means the first pane leaf returned by
  `windows[0].layout.firstPane()`. It does **not** mean "the active pane."

## 5. Startup And Child-Window Creation

This is the main post-MVP sequence.

```
tmux server
   │
   │ ESC P 1000 p ... %session-changed ... list-windows response
   ▼
source Exec read thread
   │
   │ Termio.processOutput()
   ▼
source StreamHandler + Viewer
   │
   │ Viewer emits:
   │   .windows = self.windows.items
   ▼
stream_handler.zig
   │
   │ picks windows[0]
   │ picks windows[0].layout.firstPane()
   │ stores:
   │   source.tmux_mvp.requested = true
   │   source.tmux_mvp.pane_id = first_pane.id
   │
   │ pushes:
   │   App.Message.new_tmux_window{
   │     source,
   │     pane_id,
   │     cols,
   │     rows,
   │   }
   ▼
App mailbox
   │
   │ drained on main/app thread
   ▼
App.newTmuxWindow()
   │
   │ builds SurfaceConfig from source surface
   │ overrides:
   │   backend = .tmux
   │   tmux_mvp_source_surface = source
   │   tmux_mvp_pane_id = pane_id
   │   tmux_mvp_cols = cols
   │   tmux_mvp_rows = rows
   │
   │ performAction(.new_window_with_surface_config)
   ▼
embedded runtime / macOS runtime
   │
   │ creates native Ghostty window
   │ sets config.window-width  = tmux_mvp_cols
   │ sets config.window-height = tmux_mvp_rows
   │
   │ calls Surface.init(..., .tmux_mvp = ...)
   ▼
child Surface.init()
   │
   │ creates Termio with backend = .{ .tmux = termio.Tmux.init(...) }
   │ spawns renderer thread
   │ spawns child IO thread
   │ sets self.readonly = true
   ▼
runtime notifies source surface
   │
   │ Surface.Message.tmux_mvp_target_ready{
   │   pane_id,
   │   target,
   │ }
   ▼
source surface remembers the child target
```

Two design choices matter here:

1. The source surface remains alive and visible.
   The MVP does not replace it. It adds a second window.

2. The target-ready notification is asynchronous.
   The source surface may learn about the child target before or after snapshot
   bytes arrive.

## 6. How The Snapshot Reaches The Child Surface

The child window is not populated during `.windows`. It is populated later, when
the Viewer processes the **primary visible capture** for the chosen pane.

```
tmux server
   │
   │ response to:
   │   capture-pane -p -e -q -t %<pane>
   ▼
source Exec read thread
   │
   ▼
source Viewer.receivedPaneVisible()
   │
   │ for primary screen only:
   │ emit Action.pane_snapshot{
   │   pane_id = cap.id,
   │   data    = visible_capture_bytes,
   │ }
   ▼
source stream_handler.zig
   │
   │ if snapshot.pane_id matches source.tmux_mvp.pane_id:
   │   source.tmuxMvpStoreSnapshotLocked(snapshot.data)
   │   source.tmuxMvpFlushPendingSnapshotLocked()
   ▼
source Surface tmux_mvp state
   │
   ├── if target not ready yet:
   │     keep pending_snapshot in memory
   │
   └── if target is ready:
         send Message.process_output to child IO thread
   ▼
child IO thread
   │
   │ handles:
   │   .process_output = snapshot bytes
   │
   │ calls:
   │   io.processOutput(snapshot_bytes)
   ▼
child Termio / child Terminal
   │
   │ normal VT parsing path runs
   │ screen buffer changes
   ▼
child renderer thread
   │
   ▼
child window shows snapshot text
```

This is why the MVP adds `.process_output` to `src/termio/message.zig` instead of
writing directly into the child `Terminal`.

The rule is:

- the source surface never mutates the child `Terminal` directly
- it sends bytes to the child IO thread
- the child surface mutates its own `Terminal` through its own normal path

That avoids cross-thread terminal mutation and keeps the rendering contract intact.

## 7. Why The Child Window Stays Static

This is the most important post-MVP behavior to understand.

The child window is seeded once. It is **not** a live mirror.

```
Later shell output in tmux pane
   │
   │ tmux sends %output %0 ...
   ▼
source Exec read thread
   ▼
source Viewer.receivedOutput()
   │
   │ updates the Viewer-owned pane Terminal
   │ inside the source surface's tmux Viewer
   ▼
source internal tmux state is current

child surface
   │
   │ receives nothing
   ▼
child window remains unchanged
```

Why?

- `viewer.zig` has live `%output` routing for its own internal pane terminals.
- `stream_handler.zig` does not yet forward those later bytes into the child
  surface.
- The only post-MVP path into the child surface is the one-shot
  `.pane_snapshot -> process_output` path.

That is exactly why the manual validation expects:

- `FULLMVP_SNAP_A` is visible in the child
- `FULLMVP_LIVE_B` appears later in the real tmux pane
- `FULLMVP_LIVE_B` does **not** appear in the child

## 8. The Manual Validation Flow, As Data Flow

The manual validation markers are useful because each one proves a different part
of the architecture.

### 8.1 Marker A: `FULLMVP_SNAP_A`

This marker is created **before Ghostty attaches**.
That matters because the MVP snapshot comes from the primary visible
`capture-pane`, not from a later live-output forwarding path.

```
pre-created tmux session
   │
   │ pane already contains FULLMVP_SNAP_A
   ▼
Ghostty attaches with tmux -CC
   │
   │ Viewer issues capture-pane visible command
   ▼
Viewer emits pane_snapshot
   │
   ▼
source surface flushes snapshot to child
   │
   ▼
child surface renders FULLMVP_SNAP_A
```

What it proves:

- the child window exists
- snapshot bytes crossed from source to child
- the child renderer drew them
- the marker was still on the pane's visible screen when Ghostty captured it

### 8.2 Marker B: `FULLMVP_LIVE_B`

This marker is created **after the child window already exists**.

```
external tmux send-keys
   │
   │ printf 'FULLMVP_LIVE_B\n'
   ▼
real tmux pane changes
   │
   │ tmux sends %output
   ▼
source Viewer internal pane Terminal updates
   │
   ├── source/real tmux pane now contains FULLMVP_LIVE_B
   └── child surface receives no new bytes
       so child window stays at the old snapshot
```

What it proves:

- the source pane is still live
- the child surface is still only a snapshot

### 8.3 Marker C: `FULLMVP_CHILD_INPUT`

This marker is typed into the child window itself.

```
user types in child window
   │
   ▼
child Surface
   │
   │ marked readonly = true
   │ backend = .tmux
   ▼
child IO thread
   │
   │ if a write reaches backend.queueWrite(),
   │ Tmux.queueWrite() is still a no-op in the MVP
   ▼
nothing is sent to tmux
   │
   ▼
real tmux pane does not change
```

What it proves:

- the child is not yet interactive
- the MVP has not accidentally leaked input back into tmux

## 9. The Exact Boundary Between "Done" And "Not Done"

After the MVP, the system looks like this:

```
DONE
────
tmux -CC entry detection
control-mode parsing
Viewer startup and pane discovery
first-pane selection
app-thread child-window creation
tmux child surface creation
snapshot delivery into child surface
read-only child rendering

NOT DONE
────────
live output forwarding into child surface
typing in child surface -> send-keys
resize -> refresh-client -C
multiple child panes/splits
window close / pane close sync
reattach reconstruction from multiple windows
```

That is the cleanest way to discuss the MVP with maintainers: it is not "tmux
control mode is finished." It is "Ghostty can now create and render one tmux-backed
surface without a PTY."
