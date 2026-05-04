# S9B Hoare-Style Commands

This session proves the read path only:

```text
{ precondition } line executes { postcondition }
```

## Ground rules

1. This session begins at the PTY read boundary.
2. Type `ls` before arming the read breakpoints, then press Enter after arming
   them. That makes the read-side causal moment much clearer.
3. The renderer stop is armed later than the read/parser stops so unrelated
   redraw activity does not confuse the session.
4. The breakpoint pack stays active until one full read->parse->render cycle
   completes, and then disables itself at the renderer stop.
5. If Ghostty is running and you do not see `(lldb)`, interrupt first with
   `Ctrl-C`.

## Setup

Run:

```bash
sh debugging/s9b_tmux_inside_exec_read_path/run.sh
```

At the LLDB prompt:

```lldb
run
```

Inside Ghostty:

1. Clean old tmux state:

```bash
tmux -L ghosttydbg -f /dev/null kill-server >/dev/null 2>&1 || true
```

2. Start ordinary tmux:

```bash
tmux -L ghosttydbg -f /dev/null new-session -A -s demo
```

3. Create a right split pane:

```text
Ctrl-b %
```

4. Add a visible left-pane marker:

```bash
printf 'LEFT_PANE\n'
```

5. Add a visible right-pane marker:

```bash
printf 'RIGHT_PANE\n'
```

6. In the right pane, type:

```bash
ls
```

but do **not** press Enter yet.

7. Back in the **LLDB terminal window**, press `Ctrl-C`, wait for `(lldb)`,
   then run:

```lldb
command source /Users/waqas/code/ghostty_forked/debugging/s9b_tmux_inside_exec_read_path/arm_positive_path.lldb
```

8. Return to Ghostty and press Enter in the right pane.

## Stop 1: `Exec.zig:1298`

Source:

```zig
const n = posix.read(fd, &buf) catch |err| { ... };
```

### Preconditions

- The command has been sent already.
- The next interesting event should be bytes returning from the PTY.

### Validate

```lldb
thread backtrace
source list -l 1298
next
frame variable --show-types n
memory read --format c --size 1 --count 32 &buf
```

### Postcondition

- The exec read thread has now actually read bytes from the PTY into `buf`.
- The remaining read-path stops should still be armed for this same cycle.

## Stop 2: `Exec.zig:1326`

Source:

```zig
@call(.always_inline, termio.Termio.processOutput, .{ io, buf[0..n] });
```

### Preconditions

- The returned bytes already sit in the read-thread buffer.
- Ghostty is still on the dedicated `io-reader` thread.

### Validate

```lldb
thread backtrace
source list -l 1326
```

### Postcondition

- The read thread is handing the bytes directly into `Termio.processOutput`.
- The session should continue forward into parser work, not silently stop
  teaching after this line.

## Stop 3: `Termio.zig:728`

Source:

```zig
self.terminal_stream.nextSlice(buf)
```

### Preconditions

- `Termio.processOutput` already locked renderer state and entered the output
  processing block.
- Ghostty is now about to feed the bytes into the bulk parser path.

### Validate

```lldb
thread backtrace
source list -l 728
frame variable --show-types buf
```

### Postcondition

- Terminal parsing and terminal-state mutation begin on the common bulk path.
- The renderer stop is now armed for the same returned-byte cycle.
- Do not `next` here unless you intentionally want nearby catch/log noise.
- In ordinary tmux, `buf` may contain many VT escape sequences because tmux is
  redrawing pane state, not just emitting plain filenames.

## Stop 4: `renderer/generic.zig:1173`

Source:

```zig
state.mutex.lock();
```

### Preconditions

- Terminal-visible state was already updated by the output path.
- The renderer is now preparing to read that shared state.

### Validate

```lldb
thread backtrace
source list -l 1173
frame variable --show-types state
```

### Postcondition

- The renderer can safely read terminal-visible state and build the frame.
- After this stop, the session disables the read-path breakpoint pack so later
  redraw or output chunks do not create noise.

## Final takeaway

If you reached `renderer/generic.zig:1173`, you have proved the whole read path:

```text
PTY read
-> Exec.ReadThread.threadMainPosix
-> Termio.processOutput
-> terminal_stream.nextSlice
-> renderer-visible state
-> renderer draw
```
