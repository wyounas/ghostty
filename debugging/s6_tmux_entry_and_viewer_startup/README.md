# S6: tmux Control-Mode Entry and Viewer Startup

## Learning objectives

- Watch Ghostty recognize `ESC P 1000 p`.
- See `StreamHandler` allocate a `Viewer`.
- Follow the initial `%session-changed` handshake into the command queue.

## Success criteria

After this session, you should be able to answer:

1. Where is tmux control mode first recognized?
2. Where is the `Viewer` created?
3. What moves the `Viewer` from startup into command-queue mode?
4. Which tmux commands does Ghostty queue first?

## Prerequisites

- Build the Debug macOS app first.
- `tmux` must be installed on your Mac.
- In a separate shell before launching LLDB, create a tiny demo session:
  - `tmux -L ghosttydbg -f /dev/null kill-server >/dev/null 2>&1 || true`
  - `tmux -L ghosttydbg -f /dev/null new-session -d -s demo`

## Expected duration

30-40 minutes.

## Run

1. Run:
   `sh debugging/s6_tmux_entry_and_viewer_startup/run.sh`
2. In LLDB, run:
   `run`
3. In the Ghostty window, type:
   `tmux -CC -L ghosttydbg -f /dev/null attach -t demo`
4. Press Enter and continue through the startup breakpoints.
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

This session is still mostly about parser and viewer state, not GUI creation.
The useful questions are:

1. where is `1000 p` recognized?
2. where does Ghostty allocate `Viewer`?
3. how does `Viewer` move from startup mode into command-queue mode?
4. what first tmux commands does Ghostty send back?

If tmux output is noisy, focus on the first clean DCS-recognition chain rather
than every later command/response exchange.

## What to watch for

- The DCS hook is still ordinary terminal parsing until it recognizes `1000 p`.
- `StreamHandler.dcsCommand` is where Ghostty becomes tmux-aware.
- `Viewer` starts in startup states and only later enters its command queue.
- The first queued work is tmux metadata discovery, not GUI creation.

## How to validate what to watch for

### 1. Validate the ordinary-parser to tmux-aware transition

At the stops in
[stream_handler.zig](/Users/waqas/code/ghostty_forked/src/termio/stream_handler.zig:358)
and [dcs.zig](/Users/waqas/code/ghostty_forked/src/terminal/dcs.zig:60):

- run `thread backtrace`
- run `source list -l 358`
- continue
- run `source list -l 60`
- run `frame variable --show-types dcs`

What this proves:

- tmux control mode begins as ordinary DCS parsing
- Ghostty only becomes tmux-aware once the DCS command is recognized as `1000 p`

### 2. Validate `Viewer` creation

At the stop in
[stream_handler.zig](/Users/waqas/code/ghostty_forked/src/termio/stream_handler.zig:385):

- run `source list -l 385`
- run `frame variable --show-types self.tmux_viewer`

What this proves:

- `StreamHandler` owns the transition into tmux-viewer mode
- Ghostty allocates a `Viewer` before it knows the full tmux window structure

### 3. Validate the startup-state transition

At the stops in
[viewer.zig](/Users/waqas/code/ghostty_forked/src/terminal/tmux/viewer.zig:372)
and [viewer.zig](/Users/waqas/code/ghostty_forked/src/terminal/tmux/viewer.zig:390):

- run `source list -l 372`
- run `frame variable --show-types n`
- continue
- run `source list -l 390`
- run `frame variable --show-types self.session_id`

What this proves:

- `Viewer` begins in startup/session-discovery states
- `%session-changed` moves it toward the startup command queue

### 4. Validate the first command queue output

At the stop in
[stream_handler.zig](/Users/waqas/code/ghostty_forked/src/termio/stream_handler.zig:437):

- run `source list -l 437`
- run `frame variable --show-types command`

What this proves:

- Ghostty answers tmux control-mode startup by queueing tmux commands back to
  the subprocess stream
- the first work is metadata discovery, not window creation

## A simple tmux startup mental model

When you run `tmux -CC ... attach -t demo`:

1. tmux starts writing a control-mode byte stream
2. Ghostty's ordinary DCS machinery sees it first
3. Ghostty recognizes `1000 p`
4. `StreamHandler` allocates a `Viewer`
5. `Viewer` learns the tmux session and queues startup commands
6. Ghostty sends those commands back to tmux
7. only later does Ghostty learn enough structure to talk about windows and
   panes

## What this session does not cover

- the `.windows` GUI handoff
- tmux-backed surfaces
