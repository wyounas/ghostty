# S4 Commands

At the LLDB prompt:

1. Start the app:
   `run`
2. Resize the Ghostty window once.
3. At `Surface.zig:2440`:
   - `thread backtrace`
   - `source list -l 2440`
   - `frame variable --show-types size`
   - `continue`
4. At `Surface.zig:2460`:
   - `source list -l 2460`
   - `frame variable --show-types self.size`
   - `continue`
5. At `termio/Thread.zig:321`:
   - `thread backtrace`
   - `source list -l 321`
   - `frame variable --show-types message`
   - `continue`
6. At `termio/Thread.zig:376`:
   - `source list -l 376`
   - `frame variable --show-types resize`
   - `continue`
7. At `termio/Thread.zig:430`:
   - `source list -l 430`
   - `frame variable --show-types v`
   - `continue`
8. At `Termio.zig:478`:
   - `source list -l 478`
   - `frame variable --show-types size`
   - `continue`
9. At `Exec.zig:260`:
   - `source list -l 260`
   - `frame variable --show-types grid_size`
   - `frame variable --show-types screen_size`
   - `continue`

Useful checks:

- `thread backtrace`
- `frame variable self.size`
- `finish`

Notes:

- A single drag can hit the same breakpoint several times. Record one clean
  chain instead of chasing every repeated intermediate size.
