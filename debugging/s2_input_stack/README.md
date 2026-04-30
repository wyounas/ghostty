# S2: Input Stack for Typing `ls`

## Learning objectives

- Trace a keystroke from macOS apprt into `Surface.keyCallback`.
- Distinguish the keybinding path from the PTY-write path.
- See exactly when bytes enter the exec backend and when they are handed to the
  PTY write stream.

## Success criteria

After this session, you should be able to answer:

1. Where does a surface key event first enter Zig?
2. What runs before Ghostty decides to write anything to the PTY?
3. Why does the shell not visibly respond until output comes back later?
4. Where does Ghostty first enter the concrete exec backend write path?
5. Where does Ghostty stop doing backend selection and queue a real PTY-stream
   write?

## Prerequisites

- Build the Debug macOS app first.
- Start with a normal shell prompt in the first Ghostty surface.

## Expected duration

25-35 minutes.

## Run

1. Run:
   `sh debugging/s2_input_stack/run.sh`
2. In LLDB, run:
   `breakpoint list`
3. Confirm the staged setup before launching:
   - breakpoint `1` at `embedded.zig:1765` should be enabled
   - the later breakpoints should exist but be disabled
4. In LLDB, run:
   `run`
5. Wait until Ghostty is visibly usable, then type `l` and then `s`, but do not
   press Enter yet.
6. One character is enough to learn the stack. If it gets noisy, study just `l`.
7. Use these LLDB commands as you move through the stops:
   - `continue` or `c`
   - `next` or `n`
   - `step` or `s`
   - `finish`
   - `thread backtrace`
   - `thread list`
   - `frame variable`
   - `frame variable --show-types <name>`
   - `source list -l <line>`
8. If you want a Hoare-style walkthrough with explicit preconditions and
   postconditions at each stop, use:
   `debugging/s2_input_stack/commands_hoare.md`

## How to think about LLDB output in this session

Input debugging is easier if you split it into four questions:

1. Where did the key event first enter Zig?
2. Where did Ghostty decide whether the key was a binding or terminal input?
3. Where did Ghostty enter the concrete exec backend write path?
4. Where did Ghostty hand a concrete byte slice to the PTY-side stream?

If `event`, `data`, or `write_req` prints in a low-level way, do not panic.
For this session, the important thing is the sequence of control-flow
checkpoints, not a perfect pretty-print of every struct field.

## Important note about session stability

The first useful stop for this session should happen only after you have a
usable Ghostty window and you type into it.

To make that reliable, this session uses a **staged breakpoint setup**:

- at launch, only the first surface-key export breakpoint is enabled
- when that breakpoint is hit, the later input-path breakpoints are enabled
- this reduces the chance of unrelated early stops from other traffic

If a later generic breakpoint fires before you typed into the Ghostty window,
restart the session. That means the staged setup was not the active one.

## What to watch for

- `ghostty_surface_key` is the first Zig export boundary for the surface-key
  path.
- `embedded.App.keyEvent` is the shared dispatch point after that boundary.
- `Surface.keyCallback` decides between binding handling and encoding.
- `encodeKey` turns logical key input into bytes.
- `queueIo -> Termio -> IO thread -> Exec.queueWrite` is the backend-entry
  write path.
- `exec.write_stream.queueWrite(...)` is the next handoff: Ghostty now queues a
  concrete async write on the PTY-side stream.
- There is no "local echo" shortcut in `keyCallback`; visible text comes later
  from child output.

## How to validate what to watch for

### 1. Validate the first Zig boundary for surface key input

At the stop in [embedded.zig](/Users/waqas/code/ghostty_forked/src/apprt/embedded.zig:1765):

- run `thread backtrace`
- run `source list -l 1765`
- run `frame variable --show-types surface`
- run `frame variable --show-types event`
- continue

What this proves:

- Swift/AppKit enters the surface-key path through the exported embedded API
- this is the first useful Zig boundary for a surface key event

### 2. Validate the shared dispatch point

At the stop in [embedded.zig](/Users/waqas/code/ghostty_forked/src/apprt/embedded.zig:183):

- run `thread backtrace`
- run `source list -l 183`
- run `frame variable --show-types target`
- if `event` prints as unavailable here, do not chase it; this is still a
  function-entry stop, so backtrace and source location are the reliable proof

What this proves:

- after the export boundary, Ghostty routes the surface event through the
  shared app/surface key-dispatch helper
- Ghostty is still handling a platform-originated event, not terminal bytes yet

### 3. Validate the surface keyboard decision path

At the stops in
[Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:2607),
[Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:2649), and
[Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:2752):

- run `source list -l 2607`
- run `frame variable --show-types event_orig`
- continue
- run `source list -l 2649`
- run `frame variable --show-types event`
- continue
- run `source list -l 2752`
- run `frame variable --show-types event`

What this proves:

- Ghostty handles bindings and terminal input in the surface layer
- it does not write to the PTY the moment the OS key event arrives
- it first decides whether the key has some other meaning

### 4. Validate key encoding and write forwarding

At the stops in
[Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:3139) and
[Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:2765):

- run `source list -l 3139`
- run `frame variable --show-types event`
- continue
- run `source list -l 2765`
- run `frame variable --show-types write_req`

What this proves:

- logical key input becomes concrete terminal bytes only after encoding
- the surface then forwards a write request to the IO side

### 5. Validate the backend write handoff

At the stops in
[termio/Thread.zig](/Users/waqas/code/ghostty_forked/src/termio/Thread.zig:336),
[Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:408), and
[Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:457):

- run `thread backtrace`
- run `source list -l 336`
- run `frame variable --show-types message`
- continue
- run `source list -l 408`
- if `data` looks wrong at first, step once or twice and then inspect it again
- run `frame variable --show-types data`
- run `frame variable --show-types linefeed`
- continue
- run `source list -l 457`
- run `frame variable --show-types slice`
- run `frame variable --show-types linefeed`

What this proves:

- the write is dispatched by the IO thread, not by the original key handler
- `Exec.queueWrite` is the first concrete exec-backend entrypoint
- `exec.write_stream.queueWrite(...)` is the PTY-stream handoff, so after this
  there is no more Ghostty backend selection layer in the path

## A simple `ls` mental model

If you type `l`, `s`, and then Enter:

1. macOS sends key events to Ghostty
2. Swift enters Zig through `ghostty_surface_key`
3. the embedded apprt layer converts/routes them into Ghostty input handling
4. `Surface.keyCallback` decides they are ordinary terminal input
5. Ghostty encodes the keys into bytes
6. the IO side enters `Exec.queueWrite`
7. `Exec` hands a concrete byte slice to `exec.write_stream.queueWrite(...)`
8. only later does the PTY, shell, read side, and renderer make the result
   visible

So the shell does not visibly react during this session because this session is
only about the write side, not the later read-and-render side.

## What this session does not cover

- PTY read-side parsing
- Rendering
- tmux control mode

If you want to see the typed bytes come back from the shell/tty side and become
visible on screen, use `s3_output_stack`. `s2` stops at the PTY-master write
handoff.
