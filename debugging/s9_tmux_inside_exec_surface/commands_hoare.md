# S9 Hoare-Style Commands

This file treats the session as a sequence of conservative, observable claims:

```text
{ precondition } line executes { postcondition }
```

The goal is to teach what current Ghostty really knows about ordinary tmux,
without accidentally importing a future control-mode mental model.

## Ground rules

1. In this session, tmux pane structure is real, but it is real **inside tmux**,
   not inside Ghostty's native surface model.

2. The strongest positive proof is the ordinary exec/PTy write and read path.

3. The strongest negative proof is that the tmux control-mode breakpoints never
   fire.

4. If LLDB prints noisy bytes, trust:
   - thread identity
   - stop order
   - source location
   more than giant struct dumps.

5. If Ghostty is running and you do not see an `(lldb)` prompt, LLDB is not
   ready for debugger commands yet. Interrupt first with `Ctrl-C`.

6. The renderer stop is armed later than the write/read/parser stops on purpose.
   Otherwise normal background redraw activity can fire it before the `ls`
   roundtrip you are trying to study.

## Setup

Run:

```bash
sh debugging/s9_tmux_inside_exec_surface/run.sh
```

At the LLDB prompt:

```lldb
breakpoint list
run
```

Once the Ghostty window is visible and the shell prompt is ready, do this
inside Ghostty:

1. Clean up any old session state from earlier runs:

```bash
tmux -L ghosttydbg -f /dev/null kill-server >/dev/null 2>&1 || true
```

2. Start ordinary tmux:

```bash
tmux -L ghosttydbg -f /dev/null new-session -A -s demo
```

3. Create a right split pane with the standard tmux binding:

```text
Ctrl-b %
```

4. Put a visible marker in the left pane:

```bash
printf 'LEFT_PANE\n'
```

5. Move to the right pane, then put a visible marker there:

```bash
printf 'RIGHT_PANE\n'
```

After that tmux setup is complete, go back to the **LLDB terminal window**,
press `Ctrl-C`, wait for the `(lldb)` prompt, and then run:

```lldb
command source /Users/waqas/code/ghostty_forked/debugging/s9_tmux_inside_exec_surface/arm_positive_path.lldb
```

Then return to the right tmux pane in Ghostty, type `ls`, and press Enter.

## Stop 1: `Surface.keyCallback` write handoff at `Surface.zig:2765`

Source:

```zig
self.queueIo(...)
```

### Preconditions

Before this line executes:

- Ghostty already has one normal exec-backed surface
- tmux is running inside that surface as an ordinary subprocess-world program
- you typed `ls` into the active tmux pane
- Ghostty still has no native notion of "right tmux pane"

### Validate the preconditions

Run:

```lldb
thread backtrace
source list -l 2765
frame variable --show-types write_req
```

### Postcondition

After this line executes:

- the typed bytes are handed toward the IO side as an ordinary terminal write
  request

### Validate the postcondition

Use:

```lldb
continue
```

Then confirm the next relevant stop is `Thread.zig:336`.

## Stop 2: IO drain at `Thread.zig:336`

Source:

```zig
.write_small => |v| try io.queueWrite(...)
```

### Preconditions

Before this line executes:

- the app-side write request already crossed into the IO mailbox
- the current surface still has one normal exec backend

### Validate the preconditions

Run:

```lldb
thread list
thread backtrace
source list -l 336
frame variable --show-types v
```

### Postcondition

After this line executes:

- the IO thread will forward the bytes to backend write logic

### Validate the postcondition

Use:

```lldb
continue
```

Then confirm the next relevant stop is `Exec.zig:457`.

## Stop 3: PTY-master write at `Exec.zig:457`

Source:

```zig
exec.write_stream.queueWrite(...)
```

### Preconditions

Before this line executes:

- the write request already survived the mailbox hop
- Ghostty is about to write to the PTY master of the ordinary exec backend

### Validate the preconditions

Run:

```lldb
thread backtrace
source list -l 457
frame variable --show-types slice
```

### Postcondition

After this line executes:

- Ghostty has queued the bytes toward the PTY master
- tmux will receive them through the subprocess side of that same PTY pair

### Validate the postcondition

Use:

```lldb
continue
```

Then confirm the next relevant stop is `Exec.zig:1326`.

## Stop 4: PTY read-thread handoff at `Exec.zig:1326`

Source:

```zig
@call(.always_inline, termio.Termio.processOutput, .{ io, buf[0..n] });
```

### Preconditions

Before this line executes:

- tmux and the shell inside the active pane already consumed the input
- output bytes have now arrived back on the same PTY stream
- Ghostty still does not know "which tmux pane" produced those bytes

### Validate the preconditions

Run:

```lldb
thread backtrace
source list -l 1326
frame variable --show-types n
memory read --format c --size 1 --count 32 &buf
```

### Postcondition

After this line executes:

- `Termio.processOutput` receives the returned output bytes directly on the
  dedicated PTY read thread

### Validate the postcondition

Use:

```lldb
continue
```

Then confirm the next relevant stop is `Termio.zig:728`.

## Stop 5: bulk parser entry at `Termio.zig:728`

Source:

```zig
self.terminal_stream.nextSlice(buf)
```

### Preconditions

Before this line executes:

- Ghostty is processing ordinary terminal output bytes
- the current path is parser/terminal-state work, not tmux control-mode viewer
  work

### Validate the preconditions

Run:

```lldb
thread backtrace
source list -l 728
frame variable --show-types buf
```

### Postcondition

After this line executes:

- terminal parsing and terminal-state mutation begin on the ordinary bulk path

### Validate the postcondition

Use:

```lldb
continue
```

Then confirm the next relevant stop is `renderer/generic.zig:1173`.

## Stop 6: renderer state lock at `renderer/generic.zig:1173`

Source:

```zig
state.mutex.lock();
```

### Preconditions

Before this line executes:

- terminal-visible state was already updated by the output-processing path
- the renderer is now preparing to read that shared state

### Validate the preconditions

Run:

```lldb
thread backtrace
source list -l 1173
frame variable --show-types state
```

### Postcondition

After this line executes:

- the renderer can safely copy terminal-visible state and build the next frame

## Negative proof: tmux control-mode path should stay unused

Breakpoints:

- `stream_handler.zig:427`
- `viewer.zig:845`

### Preconditions

These are enabled from launch.

### Expected result

They should never fire.

### Why that matters

If they stay at hit count `0`, then:

- Ghostty did not enter tmux control-mode parsing
- Ghostty did not create a `Viewer`
- Ghostty treated ordinary tmux output as plain terminal output

### Validate the negative result

At the end of the run:

```lldb
breakpoint list
```

Then confirm both negative probes still have hit count `0`.
