# S3: Output Stack for `ls` and the Shell Response

## Learning objectives

- Bridge one typed command byte from the app-thread input path into the
  PTY-master write path.
- Trace child output from the exec read thread into terminal parsing.
- See the closest Ghostty-side evidence that the slave/program side emitted
  bytes back across the PTY boundary.
- Watch the lock handoff into renderer-visible state.
- See how renderer wakeup turns updated terminal state into a frame.

## Success criteria

After this session, you should be able to answer:

1. Where does Ghostty hand the typed command byte toward the PTY on the app
   side?
2. Where is the closest useful Ghostty-side proof of the PTY-master write?
3. Which thread reads bytes from the PTY?
4. What is the closest Ghostty-side proof that the slave/program side emitted
   bytes?
5. Which function first processes those bytes inside Ghostty?
6. When is the renderer mutex held?
7. Which path causes the renderer to update and draw?

## Prerequisites

- Build the Debug macOS app first.
- Start from a shell prompt.

## Expected duration

25-35 minutes.

## Run

1. Run:
   `sh debugging/s3_output_stack/run.sh`
2. In LLDB, run:
   `breakpoint list`
3. Confirm the staged setup before launching:
   - breakpoint `1` at `Surface.zig:2765` should be enabled
   - the later breakpoints should exist but be disabled
4. In LLDB, run:
   `run`
5. Wait until the Ghostty window is visibly usable and the shell prompt is
   ready.
6. In the Ghostty window, type `ls` and press Enter.
7. Continue through the breakpoints in order.
8. Use these LLDB commands as you move through the stops:
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

1. app thread forwards the typed byte toward IO
2. `Exec` queues the PTY-master write
3. PTY read thread gets bytes back
4. those bytes are the closest Ghostty-side evidence of what the tty/program
   emitted back across the PTY boundary
5. `Termio.processOutput` receives them
6. the renderer mutex is held while terminal state is updated
7. the renderer thread wakes and rebuilds a frame

If `buf` is large or noisy, that is normal. The important thing is which thread
you are on and which stage of the handoff you are seeing.

## What to watch for

- The PTY read thread is separate from the IO thread.
- Ghostty has no breakpointable code "inside the slave PTY."
  The nearest observable evidence is the read thread receiving bytes back from
  the PTY.
- `Termio.processOutput` takes the renderer mutex before parsing.
- `terminal_stream.nextSlice` is the VT parser entry for bulk data.
- The renderer wakeup path ends in `renderCallback -> updateFrame`.

## How to validate what to watch for

### 0. Validate the staged app-side handoff

At the stop in
[Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:2765):

- run `thread backtrace`
- run `source list -l 2765`
- run `frame variable --show-types write_req`
- continue

What this proves:

- the app thread encoded some terminal input and forwarded it toward the IO side
- this is the staged bridge that lets the rest of the session begin after the
  Ghostty window is ready

### 1. Validate the PTY-master write handoff

At the stop in
[Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:457):

- run `thread backtrace`
- run `source list -l 457`
- run `frame variable --show-types slice`
- run `frame variable --show-types linefeed`

What this proves:

- Ghostty reached the concrete exec backend write path
- `exec.write_stream.queueWrite(...)` is the closest useful Ghostty-side proof
  of the PTY-master write handoff

### 2. Validate the dedicated PTY read thread

At the stops in
[Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:1248) and
[Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:1298):

- run `thread backtrace`
- run `source list -l 1248`
- continue
- run `source list -l 1298`
- run `next`
- run `frame variable --show-types n`
- run `memory read --format c --size 1 --count 16 &buf`

What this proves:

- a normal exec-backed surface has a dedicated PTY read thread
- output bytes enter Ghostty from that thread, not from the app thread
- Ghostty cannot breakpoint "inside the slave PTY"; the bytes now sitting in
  `buf` are the closest Ghostty-side evidence that the tty/program emitted them

### 3. Validate the termio processing entrypoint

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

### 4. Validate the renderer handoff

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

1. the app side forwards the typed bytes toward the PTY
2. `Exec` queues the PTY-master write
3. the shell runs `ls`
4. the tty/program side emits bytes back across the PTY boundary
5. the PTY read thread reads those bytes
6. `Termio.processOutput` feeds them into Ghostty's terminal machinery
7. terminal state changes under the renderer mutex
8. the renderer thread wakes and draws the new frame

## What this session does not cover

- tmux control mode
