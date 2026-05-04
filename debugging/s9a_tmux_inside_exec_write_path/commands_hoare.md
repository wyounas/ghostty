# S9A Hoare-Style Commands

This session proves the write path only:

```text
{ precondition } line executes { postcondition }
```

## Ground rules

1. This session ends at the PTY write.
2. You will trace three outbound writes separately: `l`, `s`, and Enter.
3. Ordinary tmux pane structure is real inside tmux, but Ghostty still treats
   this as one ordinary terminal stream.
4. If Ghostty is running and you do not see `(lldb)`, interrupt first with
   `Ctrl-C`.

## Setup

Run:

```bash
sh debugging/s9a_tmux_inside_exec_write_path/run.sh
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

6. Back in the **LLDB terminal window**, press `Ctrl-C`, wait for `(lldb)`,
   then run:

```lldb
command source /Users/waqas/code/ghostty_forked/debugging/s9a_tmux_inside_exec_write_path/arm_positive_path.lldb
```

7. Return to Ghostty and type `l` in the right pane.
8. Resume through Stops 1-3 for `l`.
9. Return to Ghostty and type `s`.
10. Resume through Stops 1-3 for `s`.
11. Return to Ghostty and press Enter.
12. Resume through Stops 1-3 for Enter.

## Stop 1: `Surface.zig:2765`

Source:

```zig
self.queueIo(...)
```

### Preconditions

- You typed one key in a tmux pane inside an ordinary Ghostty surface.
- Ghostty has already encoded a write request.
- Ghostty still has no native notion of "right tmux pane".

### Validate

```lldb
thread backtrace
source list -l 2765
frame variable --show-types write_req
```

### Postcondition

- The write request is handed from app-side surface code toward the IO thread.
- If this was `l`, `s`, or Enter, the same ownership handoff shape should hold.

## Stop 2: `Thread.zig:336`

Source:

```zig
.write_small => |v| try io.queueWrite(...)
```

### Preconditions

- The write request already crossed the mailbox boundary.
- The current surface still uses the normal `.exec` backend.

### Validate

```lldb
thread list
thread backtrace
source list -l 336
frame variable --show-types v
```

### Postcondition

- The IO thread is forwarding the bytes into backend write logic.
- The stop should recur once for each outbound key you traced.

## Stop 3: `Exec.zig:457`

Source:

```zig
exec.write_stream.queueWrite(...)
```

### Preconditions

- The write request survived app-side encoding and IO-thread dispatch.
- Ghostty is about to hand the bytes to the PTY master.

### Validate

```lldb
thread backtrace
source list -l 457
frame variable --show-types slice
frame variable --show-types linefeed
```

### Postcondition

- Ghostty has queued the outbound write on the PTY-master stream.
- That is the end of this session's path.
- You should observe this once for `l`, once for `s`, and once for Enter.

## Final takeaway

If you reached `Exec.zig:457` for `l`, `s`, and Enter, you have proved the
entire write path:

```text
Surface.keyCallback
-> queueIo
-> IO drainMailbox
-> io.queueWrite
-> Exec.queueWrite
-> exec.write_stream.queueWrite
```
