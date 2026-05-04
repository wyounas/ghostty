# S9B Commands

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
5. In the right pane, type:
   `ls`
   but do **not** press Enter yet.
6. In the **LLDB terminal window**, press `Ctrl-C`.
7. Wait for the `(lldb)` prompt.
8. Arm the read-path breakpoints and resume:
   `command source /Users/waqas/code/ghostty_forked/debugging/s9b_tmux_inside_exec_read_path/arm_positive_path.lldb`
9. In the right tmux pane, press Enter.
10. At `Exec.zig:1298`:
    - `thread backtrace`
    - `source list -l 1298`
    - `next`
    - `frame variable --show-types n`
    - `memory read --format c --size 1 --count 32 &buf`
    - `continue`
11. At `Exec.zig:1326`:
    - `thread backtrace`
    - `source list -l 1326`
    - `continue`
12. At `Termio.zig:728`:
    - `thread backtrace`
    - `source list -l 728`
    - `frame variable --show-types buf`
    - `continue`
13. At `renderer/generic.zig:1173`:
    - `thread backtrace`
    - `source list -l 1173`
    - `frame variable --show-types state`
    - `continue`

Useful checks:

- `thread list`
- `frame info`
- `finish`

Notes:

- This session begins at the PTY read seam.
- The renderer breakpoint is armed later than the read/parser breakpoints so it
  does not fire early on unrelated redraw activity.
- The session now disables the whole read-path breakpoint pack only after the
  renderer stop, so you get one complete read->parse->render cycle instead of
  losing the path too early.
- You do not need to capture every `ls` output chunk. One complete cycle is the
  pedagogical goal here.
- At `Termio.zig:728`, prefer `inspect + continue`, not `next`. Stepping over
  `nextSlice(buf)` often lands on nearby catch/log lines and makes the trace
  look noisier than it really is.
- The returned buffer may contain many VT escape sequences from tmux redraw, not
  just plain `ls` text. That is expected in this session.
