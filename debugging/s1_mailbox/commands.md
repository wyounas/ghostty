# S1 Commands

At the LLDB prompt:

1. Check the staged breakpoint setup:
   `breakpoint list`
2. Confirm:
   - breakpoint `1` at `Surface.zig:2765` is enabled
   - breakpoints `2` through `7` are disabled
3. Start the app:
   `run`
4. Wait until the Ghostty window is visibly usable, then type one letter.
5. At `Surface.zig:2765`:
   - `thread backtrace`
   - `source list -l 2765`
   - `frame variable --show-types write_req`
   - `continue`
6. At `Surface.zig:860`:
   - `source list -l 860`
   - `frame variable --show-types msg`
   - `source list -l 843`
   - `continue`
7. At `Termio.zig:400`:
   - `source list -l 400`
   - `frame variable --show-types msg`
   - `next`
   - `continue`
8. At `mailbox.zig:61`:
   - `source list -l 61`
   - `frame variable --show-types msg`
   - `continue`
9. At `mailbox.zig:99`:
   - `source list -l 99`
   - `thread backtrace`
   - `continue`
10. At `termio/Thread.zig:440`:
   - `source list -l 440`
   - `thread list`
   - `thread backtrace`
   - `continue`
11. At `termio/Thread.zig:308`:
   - `source list -l 308`
   - `frame variable --show-types message`
   - `continue`

Useful checks:

- `frame variable self.flags`
- `thread list`
- `finish`

Notes:

- If `msg` prints as an opaque union or a pointer-heavy value, that is normal.
- This session uses staged breakpoints:
  only `Surface.zig:2765` is enabled at launch, and the generic mailbox
  breakpoints are enabled only after that first typed-key stop.
- Do not type until the Ghostty window is visibly usable.
- If a generic mailbox breakpoint fires before you typed a letter, restart. The
  staged setup was not active.
- For this session, the proof comes mostly from stop order:
  typed key -> generic producer funnel -> mailbox send -> mailbox notify ->
  IO-thread wakeup -> drain.
