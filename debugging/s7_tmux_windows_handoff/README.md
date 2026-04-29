# S7: tmux `.windows` and the Missing App-Thread Handoff

## Learning objectives

- Watch `Viewer` parse `list-windows` output.
- See where pane `Terminal` objects are created inside `Viewer`.
- Stop exactly where `.windows` reaches `stream_handler.zig` and goes no further
  on `main`.

## Success criteria

After this session, you should be able to answer:

1. Where does `Viewer` build the `.windows` action?
2. What pane state already exists before Ghostty reaches the `TODO`?
3. Where would app-thread surface creation need to begin?
4. Why is this a thread-ownership problem rather than a parsing problem?

## Prerequisites

- Build the Debug macOS app first.
- `tmux` must be installed.
- In a separate shell before launching LLDB, create the demo session:
  - `tmux -L ghosttydbg -f /dev/null kill-server >/dev/null 2>&1 || true`
  - `tmux -L ghosttydbg -f /dev/null new-session -d -s demo`

## Expected duration

30-45 minutes.

## Run

1. Run:
   `sh debugging/s7_tmux_windows_handoff/run.sh`
2. In LLDB, run:
   `run`
3. In Ghostty, run:
   `tmux -CC -L ghosttydbg -f /dev/null attach -t demo`
4. Continue until the `.windows` breakpoints fire.
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

This is the most important tmux session on `main` because it proves that the
missing piece is not "tmux parsing." The useful questions are:

1. where does `Viewer` build `.windows`?
2. what pane/window state already exists by then?
3. where does `stream_handler.zig` receive that action?
4. why does it stop there on `main`?

If the internal pane/window data is not pretty-printed perfectly, that is fine.
What matters is proving that structure exists before the `TODO`.

## What to watch for

- `receivedListWindows` parses tmux's structural answer.
- `initLayout` creates or reuses per-pane `Terminal` state inside the `Viewer`.
- `.windows` is appended as an action before the GUI bridge exists.
- `stream_handler.zig` receives the action and immediately hits `TODO`.

## How to validate what to watch for

### 1. Validate `list-windows` parsing

At the stop in
[viewer.zig](/Users/waqas/code/ghostty_forked/src/terminal/tmux/viewer.zig:845):

- run `thread backtrace`
- run `source list -l 845`
- run `frame variable --show-types content`

What this proves:

- `Viewer` is actively parsing tmux's structural answer
- the problem is already beyond basic DCS recognition

### 2. Validate pane-state creation inside `Viewer`

At the stop in
[viewer.zig](/Users/waqas/code/ghostty_forked/src/terminal/tmux/viewer.zig:1145):

- run `source list -l 1145`
- run `frame variable --show-types layout`

What this proves:

- `Viewer` creates or reuses per-pane terminal state while walking the layout
- pane-terminal objects exist before any app-thread GUI bridge exists

### 3. Validate the `.windows` action creation

At the stop in
[viewer.zig](/Users/waqas/code/ghostty_forked/src/terminal/tmux/viewer.zig:896):

- run `source list -l 896`
- run `frame variable --show-types windows`

What this proves:

- the structured window/pane result has already been assembled
- `Viewer` can now publish a `.windows` action for its caller

### 4. Validate the dead end on `main`

At the stops in
[stream_handler.zig](/Users/waqas/code/ghostty_forked/src/termio/stream_handler.zig:427)
and [stream_handler.zig](/Users/waqas/code/ghostty_forked/src/termio/stream_handler.zig:446):

- run `source list -l 427`
- run `frame variable --show-types action`
- continue
- run `source list -l 446`
- run `frame variable --show-types action`
- run `thread backtrace`

What this proves:

- `stream_handler.zig` does receive the `.windows` action
- on `main`, the handoff stops there
- the missing work is a bridge from this worker-thread context to app-thread
  surface creation

## Why this is a thread-ownership problem

By the time `.windows` exists:

- tmux parsing already worked
- `Viewer` already knows the tmux window structure
- per-pane terminal state already exists inside `Viewer`

What does not exist yet is:

- app-thread creation of real Ghostty child surfaces
- a safe bridge from the worker-thread tmux path into runtime/UI code

So the missing piece is not "understand more tmux bytes." The missing piece is
"how should worker-thread tmux structure discovery ask the app thread to create
surfaces safely?"

## What this session does not cover

- implementing the handoff
- a tmux-backed backend
