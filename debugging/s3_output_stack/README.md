# S3: Output Stack for `ls` and the Shell Response

## Learning objectives

- Trace child output from the exec read thread into terminal parsing.
- Watch the lock handoff into renderer-visible state.
- See how renderer wakeup turns updated terminal state into a frame.

## Success criteria

After this session, you should be able to answer:

1. Which thread reads bytes from the PTY?
2. Which function first processes those bytes inside Ghostty?
3. When is the renderer mutex held?
4. Which path causes the renderer to update and draw?

## Prerequisites

- Build the Debug macOS app first.
- Start from a shell prompt.

## Expected duration

25-35 minutes.

## Run

1. Run:
   `sh debugging/s3_output_stack/run.sh`
2. In LLDB, run:
   `run`
3. In the Ghostty window, type `ls` and press Enter.
4. Continue through the breakpoints in order.
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

`ls` may produce several reads and several render wakeups. Do not try to make
every hit tell the whole story. Focus on one clean chain:

1. PTY read thread gets bytes
2. `Termio.processOutput` receives them
3. the renderer mutex is held while terminal state is updated
4. the renderer thread wakes and rebuilds a frame

If `buf` is large or noisy, that is normal. The important thing is which thread
you are on and which stage of the handoff you are seeing.

## What to watch for

- The PTY read thread is separate from the IO thread.
- `Termio.processOutput` takes the renderer mutex before parsing.
- `terminal_stream.nextSlice` is the VT parser entry for bulk data.
- The renderer wakeup path ends in `renderCallback -> updateFrame`.

## How to validate what to watch for

### 1. Validate the dedicated PTY read thread

At the stops in
[Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:1248) and
[Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:1298):

- run `thread backtrace`
- run `source list -l 1248`
- continue
- run `source list -l 1298`
- run `frame variable --show-types n`

What this proves:

- a normal exec-backed surface has a dedicated PTY read thread
- output bytes enter Ghostty from that thread, not from the app thread

### 2. Validate the termio processing entrypoint

At the stops in
[Termio.zig](/Users/waqas/code/ghostty_forked/src/termio/Termio.zig:678) and
[Termio.zig](/Users/waqas/code/ghostty_forked/src/termio/Termio.zig:687), and
[Termio.zig](/Users/waqas/code/ghostty_forked/src/termio/Termio.zig:728):

- run `thread backtrace`
- run `source list -l 678`
- run `frame variable --show-types buf`
- continue
- run `source list -l 687`
- continue
- run `source list -l 728`

What this proves:

- `Termio.processOutput` is the main Ghostty entrypoint for child output bytes
- the output path moves from raw PTY bytes into terminal parsing and renderer
  wakeup logic here
- `terminal_stream.nextSlice` is the actual bulk parser call for the common
  non-inspector path

### 3. Validate the renderer handoff

At the stops in
[renderer/Thread.zig](/Users/waqas/code/ghostty_forked/src/renderer/Thread.zig:596)
and [renderer/generic.zig](/Users/waqas/code/ghostty_forked/src/renderer/generic.zig:1173):

- run `thread list`
- run `thread backtrace`
- run `source list -l 596`
- continue
- run `source list -l 1173`
- run `frame variable --show-types state`

What this proves:

- output processing and rendering happen on different threads
- the renderer reads shared terminal-visible state only after the output side
  has updated it

## A simple `ls` mental model

After you press Enter on `ls`:

1. the shell runs `ls`
2. `ls` writes text to stdout
3. the PTY read thread reads those bytes
4. `Termio.processOutput` feeds them into Ghostty's terminal machinery
5. terminal state changes under the renderer mutex
6. the renderer thread wakes and draws the new frame

## What this session does not cover

- Input encoding details
- tmux control mode
