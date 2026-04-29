# Architecture Brief

The canonical architecture note is now
[debugging/architecture.md](/Users/waqas/code/ghostty_forked/debugging/architecture.md).
This shorter file is only the high-signal summary for the session set.

## Core corrections

- On macOS, the real app thread is the Swift main thread in
  [macos/Sources/Ghostty/Ghostty.App.swift](/Users/waqas/code/ghostty_forked/macos/Sources/Ghostty/Ghostty.App.swift:58),
  not `src/main_ghostty.zig`'s `main()`.
- A normal exec-backed `Surface` has:
  - app thread
  - one renderer thread
  - one IO thread
  - one extra PTY read thread
  ([src/Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:700),
  [src/Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:708),
  [src/termio/Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:137))

## Most important architecture facts

- App-thread work is mailbox-driven:
  `App.Mailbox.push -> rt_app.wakeup -> DispatchQueue.main.async -> ghostty_app_tick -> App.drainMailbox`
  ([src/App.zig](/Users/waqas/code/ghostty_forked/src/App.zig:238),
  [Ghostty.App.swift](/Users/waqas/code/ghostty_forked/macos/Sources/Ghostty/Ghostty.App.swift:428))
- Surface input becomes termio mailbox messages, then backend writes
  ([src/Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:2752),
  [src/termio/Thread.zig](/Users/waqas/code/ghostty_forked/src/termio/Thread.zig:336),
  [src/termio/Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:402))
- Child output is read on the PTY read thread, parsed under the renderer mutex,
  and then rendered on the renderer thread
  ([src/termio/Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:1298),
  [src/termio/Termio.zig](/Users/waqas/code/ghostty_forked/src/termio/Termio.zig:678),
  [src/renderer/generic.zig](/Users/waqas/code/ghostty_forked/src/renderer/generic.zig:1173))

## tmux-specific takeaway on `main`

- `ESC P 1000 p` is recognized in
  [src/terminal/dcs.zig](/Users/waqas/code/ghostty_forked/src/terminal/dcs.zig:53).
- `StreamHandler` creates a `Viewer` and feeds it tmux notifications
  ([src/termio/stream_handler.zig](/Users/waqas/code/ghostty_forked/src/termio/stream_handler.zig:385),
  [src/termio/stream_handler.zig](/Users/waqas/code/ghostty_forked/src/termio/stream_handler.zig:427)).
- `Viewer.receivedListWindows` already emits `.windows`
  ([src/terminal/tmux/viewer.zig](/Users/waqas/code/ghostty_forked/src/terminal/tmux/viewer.zig:896)).
- On `main`, `.windows` still dies at a `TODO`
  ([src/termio/stream_handler.zig](/Users/waqas/code/ghostty_forked/src/termio/stream_handler.zig:446)).

That means the sessions should teach:

1. ordinary Ghostty thread and mailbox architecture first
2. tmux parser and `Viewer` second
3. the missing app-thread handoff for surface creation third
