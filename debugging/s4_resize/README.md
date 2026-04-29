# S4: Resize and SIGWINCH Propagation

## Learning objectives

- Trace a resize from `Surface` into the IO thread.
- See the resize coalescing timer in action.
- Confirm the split between backend resize and logical terminal resize.

## Success criteria

After this session, you should be able to answer:

1. Where does a surface turn a size change into a termio message?
2. Why does the IO thread not resize immediately on every tiny drag?
3. Which function resizes the backend?
4. Which function resizes the logical terminal grid?

## Prerequisites

- Build the Debug macOS app first.
- Start with a visible Ghostty window.

## Expected duration

20-30 minutes.

## Run

1. Run:
   `sh debugging/s4_resize/run.sh`
2. In LLDB, run:
   `run`
3. Drag one edge of the Ghostty window to trigger a resize.
4. If you trigger many breakpoint hits, stop after one clear resize chain.
5. Use these LLDB commands as you move through the stops:
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

Resize is bursty. One drag can trigger several size updates close together. The
goal is not to inspect every single intermediate number. The goal is to see the
policy:

1. the surface always mails the IO side
2. the IO side coalesces rapid bursts
3. `Termio.resize` performs both backend resize and logical terminal resize

If the same breakpoint fires several times, pick one clean chain and write down
what each stage means.

## What to watch for

- `Surface.resize` always mails the IO thread.
- `termio.Thread.handleResize` coalesces rapid resize bursts.
- `Termio.resize` first tells the backend, then updates the terminal under the
  renderer mutex.
- For exec, backend resize means PTY resize.

## How to validate what to watch for

### 1. Validate the surface-side resize message

At the stops in
[Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:2440) and
[Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:2460):

- run `thread backtrace`
- run `source list -l 2440`
- run `frame variable --show-types size`
- continue
- run `source list -l 2460`
- run `frame variable --show-types self.size`

What this proves:

- the surface translates window-size change into a termio-side message
- resize is not applied directly to the backend from the UI callback

### 2. Validate the IO-thread coalescing path

At the stops in
[termio/Thread.zig](/Users/waqas/code/ghostty_forked/src/termio/Thread.zig:321),
[termio/Thread.zig](/Users/waqas/code/ghostty_forked/src/termio/Thread.zig:376),
and [termio/Thread.zig](/Users/waqas/code/ghostty_forked/src/termio/Thread.zig:430):

- run `thread list`
- run `thread backtrace`
- run `source list -l 321`
- run `frame variable --show-types message`
- continue
- run `source list -l 376`
- run `frame variable --show-types resize`
- continue
- run `source list -l 430`

What this proves:

- the IO thread is the resize consumer
- Ghostty intentionally delays immediate backend resize during rapid bursts
- the coalesced resize is later handed to `Termio.resize`

### 3. Validate backend resize versus logical terminal resize

At the stops in
[Termio.zig](/Users/waqas/code/ghostty_forked/src/termio/Termio.zig:478) and
[Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:260):

- run `source list -l 478`
- run `frame variable --show-types size`
- continue
- run `source list -l 260`
- run `frame variable --show-types grid_size`
- run `frame variable --show-types screen_size`

What this proves:

- `Termio.resize` is where Ghostty performs the logical resize work
- the exec backend translates that resize into PTY-level subprocess resize

## A simple resize mental model

If you drag the window edge:

1. the surface notices a new size
2. it sends a resize message to the IO side
3. the IO thread coalesces rapid bursts
4. `Termio.resize` applies the resize logically
5. the exec backend resizes the PTY
6. later output and rendering settle to the new grid size

## What this session does not cover

- tmux-specific resize commands
- renderer frame details beyond the wakeup consequence
