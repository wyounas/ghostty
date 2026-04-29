# S8: Contrast Session, Exec Surface versus Future tmux Surface

## Learning objectives

- Reuse the ordinary split path as the baseline.
- Contrast that baseline with what tmux control mode already knows.
- Produce a concrete replacement table for a future tmux-backed surface.

## Success criteria

After this session, you should be able to answer:

1. Which ordinary exec-surface steps would a tmux-backed surface skip?
2. Which existing Ghostty pieces could remain unchanged?
3. Why does `.windows` need an app-thread bridge before any tmux child surface
   exists?
4. Which thread would likely own live tmux output versus app-surface creation?

## Prerequisites

- Build the Debug macOS app first.
- `tmux` must be installed if you want to use the tmux side of the contrast live.

## Expected duration

30-40 minutes.

## Run

1. Run:
   `sh debugging/s8_exec_vs_tmux_surface_contrast/run.sh`
2. In LLDB, run:
   `run`
3. First, trigger one ordinary Ghostty split.
4. Then, if you want the tmux side live as well, attach with:
   `tmux -CC -L ghosttydbg -f /dev/null attach -t demo`
5. Use the two breakpoint groups to build your replacement table.
6. Use these LLDB commands as you move through the stops:
   - `continue` or `c`
   - `next` or `n`
   - `step` or `s`
   - `finish`
   - `thread backtrace`
   - `thread list`
   - `frame variable`
   - `frame variable --show-types <name>`
   - `source list -l <line>`

## How to think about LLDB output in this session

This is a contrast session, not a one-path walkthrough. Split your notes into
two columns:

1. ordinary exec-backed child-surface creation
2. tmux structural discovery before child-surface creation exists

The question is not "which side is better?" The question is:

- which ordinary steps stay unchanged?
- which exec-specific steps disappear?
- which new bridge is required before a tmux-backed child surface can exist?

## What to watch for

- Ordinary child creation goes through `ghostty_surface_new` and installs an
  exec backend plus a PTY read thread.
- tmux parsing already discovers windows and panes before any Ghostty surface is
  created.
- The safest architectural claim from this session is narrower:
  Ghostty's generic surface plumbing and tmux-specific transport/backend pieces
  are separable concerns.

## How to validate what to watch for

### 1. Validate the ordinary exec-backed baseline

At the stops in
[embedded.zig](/Users/waqas/code/ghostty_forked/src/apprt/embedded.zig:1910),
[embedded.zig](/Users/waqas/code/ghostty_forked/src/apprt/embedded.zig:1541),
[Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:549),
[Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:635), and
[Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:137):

- run `thread backtrace`
- run `source list -l 1910`
- continue
- run `source list -l 1541`
- continue
- run `source list -l 549`
- continue
- run `source list -l 635`
- continue
- run `source list -l 137`

What this proves:

- ordinary child creation uses runtime entrypoints plus `Surface.init`
- ordinary child creation includes generic surface plumbing before the
  exec-specific backend setup
- exec-backed surfaces install subprocess plus PTY-specific backend logic
- exec later adds its own PTY read thread

### 2. Validate the tmux-side structural-discovery path

At the stops in
[viewer.zig](/Users/waqas/code/ghostty_forked/src/terminal/tmux/viewer.zig:896)
and [stream_handler.zig](/Users/waqas/code/ghostty_forked/src/termio/stream_handler.zig:446):

- run `source list -l 896`
- run `frame variable --show-types windows`
- continue
- run `source list -l 446`
- run `frame variable --show-types action`
- run `thread backtrace`

What this proves:

- tmux can already supply child-window structure before Ghostty creates any
  child surfaces
- the missing piece is the bridge from worker-thread `.windows` discovery into
  app-thread surface creation

## A concrete replacement-table mindset

By the end of this session, you should be able to write things like:

- ordinary child-surface subprocess launch -> may not belong to each tmux child
  surface
- ordinary child-surface PTY read thread -> may not belong to each tmux child
  surface
- transport/backend-specific write path -> likely changes
- transport/backend-specific resize path -> likely changes
- generic `Surface.init` plumbing -> should be considered separately from the
  transport/backend choice

That table is not implementation. It is a disciplined contrast between:

- what this session directly proves from current code
- what a future tmux-backed child-surface design would still need to decide

Do not treat the replacement column as already-settled architecture.

## What this session does not cover

- implementation details of a `.tmux` backend
- synchronization policy for live output fanout
