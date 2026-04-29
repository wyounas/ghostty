# S2 Commands

At the LLDB prompt:

1. Check the staged breakpoint setup:
   `breakpoint list`
2. Confirm:
   - breakpoint `1` at `embedded.zig:1762` is enabled
   - breakpoints `2` through `9` are disabled
3. Start the app:
   `run`
4. Wait until the Ghostty window is visibly usable, then type `l`.
5. At `embedded.zig:1762`:
   - `thread backtrace`
   - `source list -l 1762`
   - `frame variable --show-types surface`
   - `frame variable --show-types event`
   - `continue`
6. At `embedded.zig:179`:
   - `thread backtrace`
   - `source list -l 179`
   - `frame variable --show-types target`
   - `frame variable --show-types event`
   - `continue`
7. At `Surface.zig:2604`:
   - `source list -l 2604`
   - `frame variable --show-types event_orig`
   - `continue`
8. At `Surface.zig:2649`:
   - `source list -l 2649`
   - `frame variable --show-types event`
   - `continue`
9. At `Surface.zig:2752`:
   - `source list -l 2752`
   - `frame variable --show-types event`
   - `continue`
10. At `Surface.zig:3135`:
   - `source list -l 3135`
   - `frame variable --show-types event`
   - `continue`
11. At `Surface.zig:2765`:
   - `source list -l 2765`
   - `frame variable --show-types write_req`
   - `continue`
12. At `termio/Thread.zig:336`:
   - `thread backtrace`
   - `source list -l 336`
   - `frame variable --show-types message`
   - `continue`
13. At `Exec.zig:402`:
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
- This session uses staged breakpoints:
  only `embedded.zig:1762` is enabled at launch, and the later input-path
  breakpoints are enabled only after that first surface-key stop.
- Do not type until the Ghostty window is visibly usable.
- If a later breakpoint fires before you typed `l`, restart. The staged setup
  was not active.
- `embedded.zig:1762` is the first useful Zig boundary for surface key input.
- `embedded.zig:179` is the next shared dispatch layer, not the original
  boundary from Swift into Zig.
- There is no local echo here. The visible `l` on screen later comes back from
  shell output, not from `keyCallback`.
