# S9: Ordinary tmux Inside One Exec-Backed Ghostty Surface

## Why this session exists

Your original request was:

- start tmux inside Ghostty
- make a split pane
- run `ls`
- understand the read path, write path, queues, PTYs, and major components

That is a good goal, but it needs one important refinement for correctness:

- on current Ghostty, ordinary tmux is **not** a native Ghostty integration
- Ghostty does **not** know about tmux panes in this mode
- Ghostty just owns one exec-backed surface, one subprocess, and one PTY pair
- tmux creates and manages its own panes **inside** that subprocess world

So this session is designed to teach two things at once:

1. what Ghostty **does** do when you type `ls` in a tmux split pane
2. what Ghostty **does not** know in the current architecture

That makes this a very important contrast session before any tmux control-mode
work.

## Learning objectives

- Prove that ordinary tmux inside Ghostty still uses the normal exec backend.
- Trace one `ls` command byte from the app thread to the PTY-master write path.
- Trace `ls` output from the PTY read thread into terminal parsing and render.
- See that Ghostty handles tmux pane output as one ordinary byte stream.
- Prove that Ghostty's tmux control-mode `Viewer` path does **not** run in this
  experiment.

## Success criteria

After this session, you should be able to answer:

1. How many Ghostty PTY pairs are involved in this experiment?
2. Which Ghostty thread writes the `ls` bytes toward tmux?
3. Which Ghostty thread reads the resulting output bytes back?
4. Which Ghostty functions process and render those bytes?
5. Why does Ghostty not know that the bytes came from "the right tmux pane"?
6. Which tmux-related Ghostty code paths stay unused here?

## Prerequisites

- Build the Debug macOS app first.
- `tmux` must be installed.
- Start from this branch's current code, not `tmux_mvp`.

## Expected duration

30-40 minutes.

## Run

1. Run:
   `sh debugging/s9_tmux_inside_exec_surface/run.sh`
2. In LLDB, run:
   `breakpoint list`
3. Confirm the setup:
   - breakpoints `1` through `6` should be disabled
   - breakpoints `7` and `8` should be enabled
4. In LLDB, run:
   `run`
5. Wait until the Ghostty window is visibly usable and the shell prompt is
   ready.
6. In Ghostty, start ordinary tmux:
   `tmux -L ghosttydbg -f /dev/null new-session -A -s demo`
7. Create a right split pane with:
   `Ctrl-b %`
8. In the left pane, type:
   `printf 'LEFT_PANE\n'`
9. Move to the right pane and type:
   `printf 'RIGHT_PANE\n'`
10. Back in the **LLDB terminal window** (not the Ghostty window), interrupt
    the running process with `Ctrl-C`.
    Wait for the `(lldb)` prompt to return.
11. At the `(lldb)` prompt, arm the positive path with:
    `command source /Users/waqas/code/ghostty_forked/debugging/s9_tmux_inside_exec_surface/arm_positive_path.lldb`
13. In the right tmux pane, type:
    `ls`
    then press Enter.
14. Continue through the breakpoints in order.
15. At the end, run:
    `breakpoint list`
16. Confirm that the tmux control-mode breakpoints still have hit count `0`.

## How to think about LLDB output in this session

This session is about a subtle but crucial architectural truth:

- tmux has multiple panes
- Ghostty does not

From Ghostty's point of view in this experiment:

- there is one `Surface`
- one exec backend
- one PTY master
- one PTY read thread
- one stream of output bytes

tmux is multiplexing panes **inside** the subprocess world. Ghostty is just
rendering whatever byte stream tmux emits.

So if you are asking:

- "which pane did Ghostty think this came from?"

the correct answer on current Ghostty is:

- "it did not know about panes at all"

One LLDB mechanics point matters here:

- while Ghostty is running, you usually do **not** have an LLDB prompt
- if you want to change breakpoints mid-session, first interrupt with `Ctrl-C`
- only type debugger commands after the `(lldb)` prompt returns
- if you accidentally type debugger commands into Ghostty, they become terminal
  input and the session will go off track
- the renderer breakpoint is now armed later, after the parser stop, so it does
  not fire early on background redraw activity before your `ls` path

One macOS-specific launcher detail also matters:

- this session now uses `script(1)` to record the LLDB transcript
- that preserves LLDB's interactive TTY behavior much better than piping LLDB
  through `tee`
- so `Ctrl-C` should interrupt the inferior and return the `(lldb)` prompt more
  reliably

## What to watch for

- On the current branch, `src/termio/backend.zig` only has one backend kind:
  `.exec`.
- The write path is the same ordinary path as any other shell command.
- The read path is the same ordinary exec/PTy read path as any other shell
  output.
- `Termio.processOutput` and `terminal_stream.nextSlice` do not know they are
  processing tmux-pane output.
- The renderer just draws updated terminal state.
- The tmux control-mode `stream_handler` and `Viewer` breakpoints should never
  fire.

## How to validate what to watch for

### 1. Validate the ordinary write path

At `src/Surface.zig:2765`, `src/termio/Thread.zig:336`, and
`src/termio/Exec.zig:457`:

- prove that the typed `ls` bytes become a write request
- prove that the IO thread drains that request
- prove that the exec backend queues the PTY-master write

What this teaches:

- typing inside a tmux pane still looks like ordinary terminal input to
  Ghostty
- Ghostty is writing to the single PTY master attached to the tmux client

### 2. Validate the ordinary read path

At `src/termio/Exec.zig:1326` and `src/termio/Termio.zig:728`:

- prove that output arrives on the dedicated PTY read thread
- prove that `Termio.processOutput` feeds the bytes into the bulk terminal
  parser path

What this teaches:

- the bytes coming back from tmux are not special at this layer
- Ghostty is just processing a terminal byte stream

### 3. Validate the render handoff

At `src/renderer/generic.zig:1173`:

- prove that rendering happens after terminal state was updated
- prove that the renderer reads shared state under the mutex

What this teaches:

- Ghostty renders the final terminal state, not "tmux panes" as first-class
  GUI objects

### 4. Validate the negative result

At the end of the run, use `breakpoint list` and inspect hit counts for:

- `src/termio/stream_handler.zig:427`
- `src/terminal/tmux/viewer.zig:845`

What this teaches:

- current Ghostty has no separate tmux backend in this experiment
- ordinary tmux inside a terminal does **not** invoke Ghostty's tmux
  control-mode parsing path
- `Viewer` is only relevant when Ghostty is actually receiving tmux
  control-mode output

## The mental model you should leave with

In this experiment:

1. Ghostty owns one PTY pair for the shell/tmux process world.
2. tmux runs inside that world and creates pane structure internally.
3. You type `ls` in one tmux pane.
4. Ghostty writes bytes to the PTY master exactly as it would for any command.
5. tmux routes the input to the active pane internally.
6. tmux emits resulting screen/output bytes back through the same PTY stream.
7. Ghostty reads, parses, and renders that one stream.
8. Ghostty never learns "this came from pane 1" in any native sense.

## What this session does not cover

- tmux control mode
- tmux `Viewer`
- native Ghostty child surfaces for tmux panes
- app-thread tmux window creation
