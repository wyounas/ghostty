# Ghostty Architecture For Debugging on `main`

This document is the canonical architecture note for the debugging sessions
under `debugging/`. It is written for the macOS app on the current `main`
branch, with tmux control mode treated as an extension point inside existing
Ghostty architecture rather than as a separate system.

## The first correction: where the app thread really is on macOS

On macOS, the user-visible app thread is the Swift main thread in
[macos/Sources/Ghostty/Ghostty.App.swift](/Users/waqas/code/ghostty_forked/macos/Sources/Ghostty/Ghostty.App.swift:58),
not `src/main_ghostty.zig`'s `main()`.

The important call chain is:

- Swift runtime config installs `wakeup_cb`
  ([Ghostty.App.swift](/Users/waqas/code/ghostty_forked/macos/Sources/Ghostty/Ghostty.App.swift:63))
- `App.wakeup` schedules work onto `DispatchQueue.main.async`
  ([Ghostty.App.swift](/Users/waqas/code/ghostty_forked/macos/Sources/Ghostty/Ghostty.App.swift:428))
- `appTick()` calls `ghostty_app_tick(app)`
  ([Ghostty.App.swift](/Users/waqas/code/ghostty_forked/macos/Sources/Ghostty/Ghostty.App.swift:116))
- `ghostty_app_tick` calls `core_app.tick`
  ([src/apprt/embedded.zig](/Users/waqas/code/ghostty_forked/src/apprt/embedded.zig:1425))
- `App.tick` drains the app mailbox
  ([src/App.zig](/Users/waqas/code/ghostty_forked/src/App.zig:129))

This matters because any future tmux GUI bridge that creates surfaces must
eventually arrive on this app thread.

## Verified from code

### 1. Per-surface thread topology

Each `Surface` builds three important moving parts during init:

- renderer state and renderer thread manager
  ([src/Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:549),
  [src/Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:565))
- termio thread manager
  ([src/Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:576))
- exec-backed termio
  ([src/Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:635),
  [src/Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:654))

Then it spawns:

- one renderer thread
  ([src/Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:700))
- one IO thread
  ([src/Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:708))

For the ordinary exec backend there is also a third per-surface thread:

- one PTY read thread named `io-reader`
  ([src/termio/Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:137),
  [src/termio/Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:1247))

The distinction is crucial:

- the IO thread owns the xev loop and drains mailbox messages such as write,
  resize, focus, and config change
  ([src/termio/Thread.zig](/Users/waqas/code/ghostty_forked/src/termio/Thread.zig:236),
  [src/termio/Thread.zig](/Users/waqas/code/ghostty_forked/src/termio/Thread.zig:289))
- the PTY read thread sits in `read/poll/read/poll` and feeds child output into
  `Termio.processOutput`
  ([src/termio/Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:1298),
  [src/termio/Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:1326))

This is the background for the tmux `.windows` problem: tmux control-mode
actions are reached from the output-processing side, not from the app thread.

### 2. Mailbox mechanics

There are three distinct mailbox-style paths that matter for these sessions.

The app mailbox:

- `App.Mailbox` wraps `BlockingQueue(App.Message, 64)`
  ([src/App.zig](/Users/waqas/code/ghostty_forked/src/App.zig:569))
- pushing to it also calls `rt_app.wakeup()`
  ([src/App.zig](/Users/waqas/code/ghostty_forked/src/App.zig:577))
- on macOS that wakeup lands on `DispatchQueue.main.async`
  ([Ghostty.App.swift](/Users/waqas/code/ghostty_forked/macos/Sources/Ghostty/Ghostty.App.swift:435))
- `App.tick` then drains messages in `drainMailbox`
  ([src/App.zig](/Users/waqas/code/ghostty_forked/src/App.zig:238))

The surface mailbox is really an app-mailbox wrapper:

- `apprt.surface.Mailbox.push` rewrites a surface-targeted message into
  `App.Message.surface_message`
  ([src/apprt/surface.zig](/Users/waqas/code/ghostty_forked/src/apprt/surface.zig:135))

The termio mailbox:

- lives in `src/termio/mailbox.zig`
  ([src/termio/mailbox.zig](/Users/waqas/code/ghostty_forked/src/termio/mailbox.zig:17))
- is an SPSC queue plus `xev.Async`
  ([src/termio/mailbox.zig](/Users/waqas/code/ghostty_forked/src/termio/mailbox.zig:30))
- `Termio.queueMessage` sends then notifies
  ([src/termio/Termio.zig](/Users/waqas/code/ghostty_forked/src/termio/Termio.zig:400))
- the IO thread wakes in `wakeupCallback` and drains in `drainMailbox`
  ([src/termio/Thread.zig](/Users/waqas/code/ghostty_forked/src/termio/Thread.zig:440),
  [src/termio/Thread.zig](/Users/waqas/code/ghostty_forked/src/termio/Thread.zig:289))

There is also a renderer mailbox with the same broad shape:

- renderer thread creates its mailbox and wakeup handle
  ([src/renderer/Thread.zig](/Users/waqas/code/ghostty_forked/src/renderer/Thread.zig:161))
- wakeup drains that mailbox and then renders
  ([src/renderer/Thread.zig](/Users/waqas/code/ghostty_forked/src/renderer/Thread.zig:513),
  [src/renderer/Thread.zig](/Users/waqas/code/ghostty_forked/src/renderer/Thread.zig:596))

### 3. Renderer state mutex handoff

`renderer.State` is shared mutable state protected by a mutex
([src/renderer/State.zig](/Users/waqas/code/ghostty_forked/src/renderer/State.zig:10)).

The output path mutates terminal state under that mutex:

- `Termio.processOutput` locks it
  ([src/termio/Termio.zig](/Users/waqas/code/ghostty_forked/src/termio/Termio.zig:678))
- `processOutputLocked` parses bytes and updates terminal state
  ([src/termio/Termio.zig](/Users/waqas/code/ghostty_forked/src/termio/Termio.zig:687))

The render path reads terminal state under the same mutex:

- `Renderer.updateFrame` locks `state.mutex`
  ([src/renderer/generic.zig](/Users/waqas/code/ghostty_forked/src/renderer/generic.zig:1173))
- it copies the needed render data while inside the critical section, then
  unlocks before expensive drawing work continues
  ([src/renderer/generic.zig](/Users/waqas/code/ghostty_forked/src/renderer/generic.zig:1164))

This is why Ghostty can keep a single logical terminal state while still
rendering on a dedicated thread.

### 4. Renderer trigger model

Renderer work is triggered in two broad ways.

Immediate or event-driven wakeups:

- `StreamHandler.queueRender` notifies renderer wakeup directly
  ([src/termio/stream_handler.zig](/Users/waqas/code/ghostty_forked/src/termio/stream_handler.zig:104))
- `Termio.processOutputLocked` calls that before VT parsing
  ([src/termio/Termio.zig](/Users/waqas/code/ghostty_forked/src/termio/Termio.zig:688))
- the IO thread also wakes the renderer after draining any mailbox batch that
  changed state
  ([src/termio/Thread.zig](/Users/waqas/code/ghostty_forked/src/termio/Thread.zig:357))

Timer-driven wakeups:

- renderer thread starts cursor blink timer
  ([src/renderer/Thread.zig](/Users/waqas/code/ghostty_forked/src/renderer/Thread.zig:246))
- renderer thread starts draw timer
  ([src/renderer/Thread.zig](/Users/waqas/code/ghostty_forked/src/renderer/Thread.zig:256))
- `renderCallback` rebuilds frame state
  ([src/renderer/Thread.zig](/Users/waqas/code/ghostty_forked/src/renderer/Thread.zig:596))
- `drawCallback` and `drawFrame` handle actual presentation cadence
  ([src/renderer/Thread.zig](/Users/waqas/code/ghostty_forked/src/renderer/Thread.zig:572))

### 5. Input stack

On macOS, the platform runtime converts native events into Ghostty input events:

- `embedded.App.keyEvent` converts the C event into `input.KeyEvent`
  ([src/apprt/embedded.zig](/Users/waqas/code/ghostty_forked/src/apprt/embedded.zig:179))
- surface-targeted input calls `surface.core_surface.keyCallback`
  ([src/apprt/embedded.zig](/Users/waqas/code/ghostty_forked/src/apprt/embedded.zig:195))

Inside `Surface.keyCallback` the high-level order is:

- apply remaps and setup crash/inspector state
  ([src/Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:2604))
- try keybindings first through `maybeHandleBinding`
  ([src/Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:2649),
  [src/Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:2799))
- if not consumed, encode bytes through `encodeKey`
  ([src/Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:2752),
  [src/Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:3135))
- queue a termio write message through `queueIo`
  ([src/Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:2765),
  [src/Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:843))
- `Termio.queueMessage` sends that to the IO thread
  ([src/termio/Termio.zig](/Users/waqas/code/ghostty_forked/src/termio/Termio.zig:400))
- IO thread drains `.write_*` and calls backend `queueWrite`
  ([src/termio/Thread.zig](/Users/waqas/code/ghostty_forked/src/termio/Thread.zig:336),
  [src/termio/Termio.zig](/Users/waqas/code/ghostty_forked/src/termio/Termio.zig:419))
- exec backend writes to the PTY
  ([src/termio/Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:402))

This is the ordinary input stack that a tmux-backed backend would eventually
replace with "send command to tmux" semantics rather than "write to PTY".

### 6. Resize path

At the `Surface` layer, resize is first converted into a termio mailbox message:

- `Surface.resize` updates cached size and queues `.resize`
  ([src/Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:2440),
  [src/Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:2460))

The IO thread handles resize asynchronously:

- `drainMailbox` routes `.resize` into `handleResize`
  ([src/termio/Thread.zig](/Users/waqas/code/ghostty_forked/src/termio/Thread.zig:321))
- `handleResize` coalesces rapid resizes with a timer
  ([src/termio/Thread.zig](/Users/waqas/code/ghostty_forked/src/termio/Thread.zig:376))
- `coalesceCallback` finally calls `io.resize`
  ([src/termio/Thread.zig](/Users/waqas/code/ghostty_forked/src/termio/Thread.zig:430))

Then `Termio.resize` does two jobs:

- tell the backend about the new terminal size
  ([src/termio/Termio.zig](/Users/waqas/code/ghostty_forked/src/termio/Termio.zig:487))
- resize the logical terminal under the renderer mutex
  ([src/termio/Termio.zig](/Users/waqas/code/ghostty_forked/src/termio/Termio.zig:491))

For exec today, backend resize means PTY resize
([src/termio/Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:260)).
For a tmux backend later, this would become a tmux control-mode command such as
`refresh-client -C`.

### 7. DCS and tmux entry

The VT stream dispatches DCS lifecycle events:

- `dcs_hook`, `dcs_put`, `dcs_unhook`
  ([src/terminal/stream.zig](/Users/waqas/code/ghostty_forked/src/terminal/stream.zig:733))

The tmux-specific DCS recognition happens in `terminal/dcs.zig`:

- tmux control mode is accepted only for `ESC P 1000 p`
  ([src/terminal/dcs.zig](/Users/waqas/code/ghostty_forked/src/terminal/dcs.zig:53),
  [src/terminal/dcs.zig](/Users/waqas/code/ghostty_forked/src/terminal/dcs.zig:60))
- hook creates tmux parser state and returns `.tmux = .enter`
  ([src/terminal/dcs.zig](/Users/waqas/code/ghostty_forked/src/terminal/dcs.zig:63),
  [src/terminal/dcs.zig](/Users/waqas/code/ghostty_forked/src/terminal/dcs.zig:73))
- subsequent bytes are forwarded into `ControlParser`
  ([src/terminal/dcs.zig](/Users/waqas/code/ghostty_forked/src/terminal/dcs.zig:124),
  [src/terminal/dcs.zig](/Users/waqas/code/ghostty_forked/src/terminal/dcs.zig:130))

`StreamHandler` is where Ghostty becomes tmux-aware:

- `dcsHook`, `dcsPut`, `dcsUnhook` delegate into `dcsCommand`
  ([src/termio/stream_handler.zig](/Users/waqas/code/ghostty_forked/src/termio/stream_handler.zig:358),
  [src/termio/stream_handler.zig](/Users/waqas/code/ghostty_forked/src/termio/stream_handler.zig:376))
- `.enter` allocates a `Viewer`
  ([src/termio/stream_handler.zig](/Users/waqas/code/ghostty_forked/src/termio/stream_handler.zig:385))
- later tmux notifications are fed into `viewer.next`
  ([src/termio/stream_handler.zig](/Users/waqas/code/ghostty_forked/src/termio/stream_handler.zig:427))

### 8. Viewer lifecycle on `main`

The `Viewer` is a tmux-specific state machine:

- init starts in `startup_block`
  ([src/terminal/tmux/viewer.zig](/Users/waqas/code/ghostty_forked/src/terminal/tmux/viewer.zig:268),
  [src/terminal/tmux/viewer.zig](/Users/waqas/code/ghostty_forked/src/terminal/tmux/viewer.zig:275))
- `nextStartupBlock` waits for the initial block to finish
  ([src/terminal/tmux/viewer.zig](/Users/waqas/code/ghostty_forked/src/terminal/tmux/viewer.zig:339))
- `nextStartupSession` waits for `%session-changed`
  ([src/terminal/tmux/viewer.zig](/Users/waqas/code/ghostty_forked/src/terminal/tmux/viewer.zig:372))
- `%session-changed` causes `enterCommandQueue` with `tmux_version` and
  `list_windows`
  ([src/terminal/tmux/viewer.zig](/Users/waqas/code/ghostty_forked/src/terminal/tmux/viewer.zig:383),
  [src/terminal/tmux/viewer.zig](/Users/waqas/code/ghostty_forked/src/terminal/tmux/viewer.zig:390))

When `list-windows` output arrives:

- `receivedListWindows` parses it
  ([src/terminal/tmux/viewer.zig](/Users/waqas/code/ghostty_forked/src/terminal/tmux/viewer.zig:845))
- appends a `.windows` action
  ([src/terminal/tmux/viewer.zig](/Users/waqas/code/ghostty_forked/src/terminal/tmux/viewer.zig:896))
- then calls `syncLayouts` to create or prune per-pane `Terminal` objects
  ([src/terminal/tmux/viewer.zig](/Users/waqas/code/ghostty_forked/src/terminal/tmux/viewer.zig:900))

When live pane output arrives:

- `receivedOutput` finds the pane and feeds bytes into that pane's own terminal
  VT stream
  ([src/terminal/tmux/viewer.zig](/Users/waqas/code/ghostty_forked/src/terminal/tmux/viewer.zig:1106))

This is a critical insight for the debugger sessions: by the time `.windows` is
emitted, the `Viewer` already knows a lot about tmux windows and panes. The
missing piece is not "parse tmux". The missing piece is "bridge that knowledge
into ordinary Ghostty surfaces on the app thread."

### 9. What works today on `main`, and what does not

What works:

- DCS `1000 p` recognition
- tmux control parser state
- Viewer lifecycle
- tmux command queue
- `.command` action being turned back into writes to tmux
  ([src/termio/stream_handler.zig](/Users/waqas/code/ghostty_forked/src/termio/stream_handler.zig:437))

What does not yet work:

- `.windows` is received but not bridged into app/runtime behavior
  ([src/termio/stream_handler.zig](/Users/waqas/code/ghostty_forked/src/termio/stream_handler.zig:446))

So on `main`, the real gap is:

1. `Viewer` discovers windows and panes.
2. `stream_handler.zig` sees `.windows`.
3. Nothing crosses from that output-processing context into app-thread surface
   creation yet.

This matches the `tmux_mvp` design docs and gives the right teaching emphasis:
the hard part is thread and ownership crossing, not basic tmux parsing.

## Inferred from structure

### Surface versus Backend is the right mental split

The `tmux_mvp` docs are helpful here, and the current `main` code supports the
same conclusion: `Surface` should be thought of as "terminal view + input +
renderer plumbing", while `Backend` should be thought of as "where bytes and
control come from".

Today the only backend kind is exec, but the separation already exists:

- surface init sets up renderer, shared state, termio, and threads
- backend methods abstract process-specific operations such as write and resize

That is why the contrast session should compare "exec-backed surface" against
"future tmux-backed surface" rather than treating tmux work as a total rewrite.

### The crucial thread boundary for tmux is output-side to app-thread

The tmux action loop is reached from the DCS/output path inside termio stream
handling. Surface creation, by contrast, is app/runtime work and must happen on
the app thread. That is the design seam a maintainer should care about most.

## Still worth verifying experimentally in LLDB

- The cleanest stop for "first useful app tick" should be validated between
  `Ghostty.App.swift:appTick`, `ghostty_app_tick`, and `App.tick`.
- The least noisy stop for "renderer has copied state" should be validated at
  `renderer/generic.zig:updateFrame`; depending on symbolization, a call-site
  stop in `renderCallback` may be easier to teach first.
- The best live demo of tmux `.windows` on `main` is to stop at the `TODO` site
  in `stream_handler.zig` and confirm that the `Viewer` has already populated
  window and pane state before Ghostty does anything GUI-related.
