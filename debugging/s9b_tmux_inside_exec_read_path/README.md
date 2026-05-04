# S9B: Ordinary tmux Inside Ghostty, Read Path from the PTY Master

## Why this session exists

This session isolates the other half of the story:

> After `ls` runs in a tmux split pane, how do the resulting bytes come back
> from the PTY and become rendered output?

It intentionally begins at the PTY read boundary.

It does **not** try to explain:

- app-side key encoding
- mailbox handoff for outbound writes
- the final PTY write step

Those belong in `s9a`.

## Learning objectives

- Prove that returned bytes first enter Ghostty on the dedicated exec read
  thread.
- Trace those bytes into `Termio.processOutput`.
- See where the bulk parser path begins.
- See where renderer-visible state is later read under the mutex.

## Success criteria

After this session, you should be able to answer:

1. Which thread first reads the bytes back from the PTY?
2. How does Ghostty hand those bytes into `Termio`?
3. Where does the bulk parser path begin?
4. Where does the renderer later read terminal-visible state?

## Prerequisites

- Build the Debug macOS app first.
- `tmux` must be installed.
- Use the current branch, not `tmux_mvp`.

## Expected duration

20-30 minutes.

## Run

1. Run:
   `sh debugging/s9b_tmux_inside_exec_read_path/run.sh`
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
9. In the right pane, type:
   `ls`
   but **do not press Enter yet**.
10. Switch back to the **LLDB terminal window**.
11. Press `Ctrl-C` and wait for the `(lldb)` prompt.
12. Arm the read-path breakpoints and resume:
    `command source /Users/waqas/code/ghostty_forked/debugging/s9b_tmux_inside_exec_read_path/arm_positive_path.lldb`
13. Switch back to Ghostty.
14. In the right pane, press Enter.
15. Continue through the stops in order.

## How to think about this session

This session starts at the natural seam:

```text
PTY read
-> Termio.processOutput
-> bulk parser
-> renderer-visible state
-> renderer draw
```

That is all.

If you find yourself asking:

- how did the bytes get written out in the first place?

stop and defer that question to `s9a`.

## What to watch for

- The read path begins on the dedicated `io-reader` thread, not the IO mailbox
  thread.
- `Exec.ReadThread.threadMainPosix` calls `Termio.processOutput` directly.
- `Termio.processOutputLocked` feeds the bytes to
  `terminal_stream.nextSlice(buf)`.
- The renderer later locks shared state to build the frame.
- This session is designed to capture one full read cycle:
  PTY read -> `processOutput` -> parser -> renderer.

## What this session does not cover

- app-side key encoding
- outbound mailbox handoff
- PTY write path
- tmux control mode
