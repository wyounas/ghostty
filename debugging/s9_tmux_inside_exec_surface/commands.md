# S9 Commands

At the LLDB prompt:

1. Check the breakpoint setup:
   `breakpoint list`
2. Confirm:
   - breakpoints `1` through `6` are disabled
   - breakpoints `7` and `8` are enabled
3. Start the app:
   `run`
4. Wait until Ghostty is visibly usable.
5. In Ghostty, start tmux:
   `tmux -L ghosttydbg -f /dev/null new-session -A -s demo`
6. Create a right split pane:
   `Ctrl-b %`
7. In the left pane, type:
   `printf 'LEFT_PANE\n'`
8. In the right pane, type:
   `printf 'RIGHT_PANE\n'`
9. In the **LLDB terminal window**, press `Ctrl-C` to interrupt the running
   process.
10. Wait for the `(lldb)` prompt to return.
11. Back at the LLDB prompt, run:
    `command source /Users/waqas/code/ghostty_forked/debugging/s9_tmux_inside_exec_surface/arm_positive_path.lldb`
13. In the right tmux pane, type:
    `ls`
    then press Enter.
14. At `Surface.zig:2765`:
    - `thread backtrace`
    - `source list -l 2765`
    - `frame variable --show-types write_req`
    - `continue`
15. At `Thread.zig:336`:
    - `thread list`
    - `thread backtrace`
    - `source list -l 336`
    - `frame variable --show-types v`
    - `continue`
16. At `Exec.zig:457`:
    - `thread backtrace`
    - `source list -l 457`
    - `frame variable --show-types slice`
    - `continue`
17. At `Exec.zig:1326`:
    - `thread backtrace`
    - `source list -l 1326`
    - `frame variable --show-types n`
    - `memory read --format c --size 1 --count 32 &buf`
    - `continue`
18. At `Termio.zig:728`:
    - `thread backtrace`
    - `source list -l 728`
    - `frame variable --show-types buf`
    - `continue`
19. At `renderer/generic.zig:1173`:
    - `thread backtrace`
    - `source list -l 1173`
    - `frame variable --show-types state`
    - `continue`
20. After the `ls` roundtrip is complete, prove the negative result:
    - `breakpoint list`
21. Confirm the hit counts for:
    - `stream_handler.zig:427`
    - `viewer.zig:845`
    are still `0`.

Useful checks:

- `frame info`
- `frame variable self.backend`
- `frame variable self.terminal`
- `thread list`
- `finish`

Notes:

- The positive-path breakpoints start disabled on purpose so you can create the
  tmux split before tracing `ls`.
- If you type `breakpoint enable ...` while Ghostty is still running and there
  is no `(lldb)` prompt, LLDB will not treat it as a debugger command. Always
  interrupt first with `Ctrl-C`.
- This session's `run.sh` now uses macOS `script(1)` instead of `tee` so the
  LLDB terminal keeps cleaner interactive behavior while still saving
  `session.log`.
- The renderer breakpoint is intentionally armed only after the parser stop so
  you do not get an early stop from unrelated redraw activity.
- If the log shows Ghostty handling paste or normal key events but shows no new
  LLDB command output, you probably typed into Ghostty instead of the LLDB
  terminal.
- The negative tmux-control-mode breakpoints stay enabled from launch because
  they should not fire at all in this experiment.
- If one of the negative probes fires, you are no longer proving "ordinary tmux
  inside one exec surface." You likely started a control-mode path by mistake.
- The most important conclusion is not "Ghostty handled tmux specially."
  The most important conclusion is the opposite: Ghostty handled tmux output as
  one ordinary PTY byte stream.
