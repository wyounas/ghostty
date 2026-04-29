# S6 Commands

Preparation in a separate shell before LLDB:

- `tmux -L ghosttydbg -f /dev/null kill-server >/dev/null 2>&1 || true`
- `tmux -L ghosttydbg -f /dev/null new-session -d -s demo`

At the LLDB prompt:

1. Start the app:
   `run`
2. In Ghostty, run:
   `tmux -CC -L ghosttydbg -f /dev/null attach -t demo`
3. At `stream_handler.zig:358`:
   - `thread backtrace`
   - `source list -l 358`
   - `continue`
4. At `dcs.zig:60`:
   - `source list -l 60`
   - `frame variable --show-types dcs`
   - `continue`
5. At `stream_handler.zig:385`:
   - `source list -l 385`
   - `frame variable --show-types self.tmux_viewer`
   - `continue`
6. At `viewer.zig:372`:
   - `source list -l 372`
   - `frame variable --show-types n`
   - `continue`
7. At `viewer.zig:390`:
   - `source list -l 390`
   - `frame variable --show-types self.session_id`
   - `continue`
8. At `stream_handler.zig:437`:
   - `source list -l 437`
   - `frame variable --show-types command`
   - `continue`

Useful checks:

- `frame variable action`
- `thread list`
- `finish`

Notes:

- If tmux produces many later hits, prove the first `enter -> Viewer -> command`
  chain and then stop.
- This is still read-side/thread-side work, not app-thread window creation.
