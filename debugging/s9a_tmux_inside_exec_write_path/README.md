# S9A: Ordinary tmux Inside Ghostty, Write Path to the PTY Master

## Why this session exists

This session isolates only one question:

> When I type `ls` in a tmux split pane inside Ghostty, how do those bytes leave
> Ghostty and reach the PTY master?

It intentionally stops at the PTY write boundary.

It does **not** try to explain:

- how bytes come back from the PTY
- how parsing works
- how rendering happens

Those belong in `s9b`.

## Learning objectives

- Prove that ordinary tmux inside Ghostty still uses one normal exec backend.
- Trace each typed byte from `Surface.keyCallback` to the PTY master write.
- See exactly where the app thread, IO thread, and exec backend each take over.
- Leave with a clean mental model of the write path only.

## Success criteria

After this session, you should be able to answer:

1. Where does typed terminal input leave the app-side surface code?
2. How does that input cross into the IO thread?
3. Where does the exec backend finally queue the PTY-master write?
4. Why does Ghostty still not know anything about native tmux panes here?

## Prerequisites

- Build the Debug macOS app first.
- `tmux` must be installed.
- Use the current branch, not `tmux_mvp`.

## Expected duration

20-30 minutes.

## Run

1. Run:
   `sh debugging/s9a_tmux_inside_exec_write_path/run.sh`
2. At the LLDB prompt:
   `run`
3. Wait until Ghostty is visibly usable and the shell prompt is ready.
4. Inside Ghostty, clean old tmux state:
   `tmux -L ghosttydbg -f /dev/null kill-server >/dev/null 2>&1 || true`
5. Start ordinary tmux:
   `tmux -L ghosttydbg -f /dev/null new-session -A -s demo`
6. Create a right split pane with:
   `Ctrl-b %`
7. Put a visible marker in the left pane:
   `printf 'LEFT_PANE\n'`
8. Move to the right pane and put a visible marker there:
   `printf 'RIGHT_PANE\n'`
9. Switch back to the **LLDB terminal window**.
10. Press `Ctrl-C` and wait for the `(lldb)` prompt.
11. Arm the write-path breakpoints and resume:
    `command source /Users/waqas/code/ghostty_forked/debugging/s9a_tmux_inside_exec_write_path/arm_positive_path.lldb`
12. Switch back to Ghostty.
13. In the right tmux pane, type `l`.
14. In the LLDB window, continue through the three stops in order.
15. Return to Ghostty and type `s`.
16. Continue through the same three stops again.
17. Return to Ghostty and press Enter.
18. Continue through the same three stops a third time.

## How to think about this session

This session is about a single outbound path:

```text
key event
-> app-side write request
-> IO mailbox drain
-> exec backend write
-> PTY master
```

That is all.

If you find yourself asking:

- what bytes came back?
- where did parsing happen?
- where did rendering happen?

stop and defer that question to `s9b`.

## What to watch for

- The current branch only has the `.exec` termio backend.
- Typing into a tmux pane still looks like ordinary terminal input to Ghostty.
- The write path crosses three ownership layers:
  - surface/app-side code
  - IO thread
  - exec backend transport
- You should expect the same three stops once for `l`, once for `s`, and once
  for Enter.
- The path ends at `exec.write_stream.queueWrite(...)`.

## What this session does not cover

- PTY read path
- `Termio.processOutput`
- VT parsing
- renderer state / drawing
- tmux control mode
