# S8 Commands

At the LLDB prompt:

1. Start the app:
   `run`
2. Trigger one ordinary Ghostty split.
3. Observe the exec-side breakpoints first.
4. Optional tmux side:
   - In another shell:
     - `tmux -L ghosttydbg -f /dev/null kill-server >/dev/null 2>&1 || true`
     - `tmux -L ghosttydbg -f /dev/null new-session -d -s demo`
   - In Ghostty:
     - `tmux -CC -L ghosttydbg -f /dev/null attach -t demo`
5. At each stop, record whether the step belongs to:
   - ordinary exec/PTY surface creation
   - future tmux-driven structure discovery

Suggested stop usage:

- at `embedded.zig:1910`
  - `thread backtrace`
  - `source list -l 1910`
  - `continue`
- at `embedded.zig:1541`
  - `source list -l 1541`
  - `continue`
- at `Surface.zig:549`
  - `source list -l 549`
  - `continue`
- at `Surface.zig:635`
  - `source list -l 635`
  - `continue`
- at `Exec.zig:137`
  - `source list -l 137`
  - `thread backtrace`
  - `continue`
- at `viewer.zig:896`
  - `source list -l 896`
  - `frame variable --show-types windows`
  - `continue`
- at `stream_handler.zig:446`
  - `source list -l 446`
  - `frame variable --show-types action`
  - `thread backtrace`

Useful inspections:

- `thread backtrace`
- `frame variable self`
- `frame variable action`
- `thread list`
- `finish`

Replacement table to fill in:

- per-child subprocess launch -> definitely required, definitely removed, or
  still an open design choice?
- per-child PTY read thread -> definitely required, definitely removed, or
  still an open design choice?
- backend `queueWrite` -> what is proved today, and what is only a hypothesis?
- backend `resize` -> what is proved today, and what is only a hypothesis?
- generic `Surface.init` shared plumbing -> what did `Surface.zig:549` prove?

Notes:

- The aim is comparison, not exhaustive stepping. A few carefully chosen stops
  are enough if they let you fill the replacement table honestly.
- If the debugger session did not directly prove a replacement-table entry,
  record it as a design question, not as a fact.
