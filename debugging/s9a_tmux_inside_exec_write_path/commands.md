# S9A Commands

At the LLDB prompt:

1. Start the app:
   `run`
2. In Ghostty, clean and start ordinary tmux:
   - `tmux -L ghosttydbg -f /dev/null kill-server >/dev/null 2>&1 || true`
   - `tmux -L ghosttydbg -f /dev/null new-session -A -s demo`
3. Create a right split pane:
   `Ctrl-b %`
4. Add pane markers:
   - left pane: `printf 'LEFT_PANE\n'`
   - right pane: `printf 'RIGHT_PANE\n'`
5. In the **LLDB terminal window**, press `Ctrl-C`.
6. Wait for the `(lldb)` prompt.
7. Arm the write-path breakpoints and resume:
   `command source /Users/waqas/code/ghostty_forked/debugging/s9a_tmux_inside_exec_write_path/arm_positive_path.lldb`
8. In the right tmux pane, type `l`.
9. At `Surface.zig:2765` for `l`:
   - `thread backtrace`
   - `source list -l 2765`
   - `frame variable --show-types write_req`
   - `continue`
10. At `Thread.zig:336` for `l`:
    - `thread list`
    - `thread backtrace`
    - `source list -l 336`
    - `frame variable --show-types v`
    - `continue`
11. At `Exec.zig:457` for `l`:
    - `thread backtrace`
    - `source list -l 457`
    - `frame variable --show-types slice`
    - `frame variable --show-types linefeed`
    - `continue`
12. Return to Ghostty and type `s`.
13. Repeat stops 9-11 for `s`.
14. Return to Ghostty and press Enter.
15. Repeat stops 9-11 for Enter.

Useful checks:

- `frame info`
- `frame variable self.backend`
- `finish`

Notes:

- This session intentionally stops at the PTY write boundary.
- This session is designed to show three separate outbound writes:
  `l`, `s`, and Enter.
- Because the process is stopped at each breakpoint, type only one key at a
  time, then resume through its three stops before typing the next key.
- If you accidentally type the LLDB command into Ghostty, the session will go
  off track.
