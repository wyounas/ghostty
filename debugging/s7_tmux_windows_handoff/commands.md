# S7 Commands

Preparation in a separate shell before LLDB:

- `tmux -L ghosttydbg -f /dev/null kill-server >/dev/null 2>&1 || true`
- `tmux -L ghosttydbg -f /dev/null new-session -d -s demo`

At the LLDB prompt:

1. Start the app:
   `run`
2. In Ghostty, run:
   `tmux -CC -L ghosttydbg -f /dev/null attach -t demo`
3. At `viewer.zig:845`:
   - `thread backtrace`
   - `source list -l 845`
   - `frame variable --show-types content`
   - `continue`
4. At `viewer.zig:1145`:
   - `source list -l 1145`
   - `frame variable --show-types layout`
   - `continue`
5. At `viewer.zig:896`:
   - `source list -l 896`
   - `frame variable --show-types windows`
   - `continue`
6. At `stream_handler.zig:427`:
   - `source list -l 427`
   - `frame variable --show-types action`
   - `continue`
7. At `stream_handler.zig:446`:
   - `source list -l 446`
   - `frame variable --show-types action`
   - `thread backtrace`

Useful checks:

- `frame variable self.windows`
- `frame variable self.panes`
- `thread list`
- `finish`

Notes:

- This session is successful if you prove that `.windows` exists before the
  `TODO`. You do not need LLDB to pretty-print every field of every pane.
