# S5 Commands

At the LLDB prompt:

1. Start the app:
   `run`
2. Trigger one ordinary Ghostty split.
3. At `embedded.zig:1910`:
   - `thread backtrace`
   - `source list -l 1910`
   - `frame variable --show-types ptr`
   - `continue`
4. At `embedded.zig:1541`:
   - `source list -l 1541`
   - `frame variable --show-types app`
   - `frame variable --show-types opts`
   - `continue`
5. At `Surface.zig:549`:
   - `source list -l 549`
   - `frame variable --show-types app_mailbox`
   - `frame variable --show-types render_thread`
   - `frame variable --show-types io_thread`
   - `continue`
6. At `Surface.zig:654`:
   - `source list -l 654`
   - `frame variable --show-types io_exec`
   - `frame variable --show-types io_mailbox`
   - `frame variable --show-types self.renderer_state`
   - `frame variable --show-types self.size`
   - `continue`
7. At `Surface.zig:700` and `:708`:
   - `source list -l 700`
   - `thread list`
   - `thread backtrace`
   - `next`
   - `continue`

Useful checks:

- `frame variable self.rt_surface`
- `frame variable self.renderer_state`
- `frame variable self.size`
- `finish`

Notes:

- If you already learned the first-surface version in `s0`, read this session
  as "the same plumbing, but for an ordinary child surface."
