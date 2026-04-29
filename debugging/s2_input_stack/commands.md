# S2 Commands

At the LLDB prompt:

1. Start the app:
   `run`
2. Type `l` in the terminal.
3. At `embedded.zig:1762`:
   - `thread backtrace`
   - `source list -l 1762`
   - `frame variable --show-types surface`
   - `frame variable --show-types event`
   - `continue`
4. At `embedded.zig:179`:
   - `thread backtrace`
   - `source list -l 179`
   - `frame variable --show-types target`
   - `frame variable --show-types event`
   - `continue`
5. At `Surface.zig:2604`:
   - `source list -l 2604`
   - `frame variable --show-types event_orig`
   - `continue`
6. At `Surface.zig:2649`:
   - `source list -l 2649`
   - `frame variable --show-types event`
   - `continue`
7. At `Surface.zig:2752`:
   - `source list -l 2752`
   - `frame variable --show-types event`
   - `continue`
8. At `Surface.zig:3135`:
   - `source list -l 3135`
   - `frame variable --show-types event`
   - `continue`
9. At `Surface.zig:2765`:
   - `source list -l 2765`
   - `frame variable --show-types write_req`
   - `continue`
10. At `termio/Thread.zig:336`:
   - `thread backtrace`
   - `source list -l 336`
   - `frame variable --show-types message`
   - `continue`
11. At `Exec.zig:402`:
   - `source list -l 402`
   - `frame variable --show-types data`
   - `continue`

Useful checks:

- `thread backtrace`
- `frame variable self.keyboard`
- `frame variable self.io.terminal`
- `finish`

Notes:

- One character is enough. If `l` already proves the stack, do not chase extra
  noise from `s`.
- `embedded.zig:1762` is the first useful Zig boundary for surface key input.
- `embedded.zig:179` is the next shared dispatch layer, not the original
  boundary from Swift into Zig.
- There is no local echo here. The visible `l` on screen later comes back from
  shell output, not from `keyCallback`.
