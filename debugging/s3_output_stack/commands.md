# S3 Commands

At the LLDB prompt:

1. Check the staged breakpoint setup:
   `breakpoint list`
2. Confirm:
   - breakpoint `1` at `Surface.zig:2765` is enabled
   - breakpoints `2` through `8` are disabled
3. Start the app:
   `run`
4. Wait until the Ghostty window is visibly usable and the shell prompt is
   ready.
5. Type `ls` and press Enter.
6. At `Surface.zig:2765`:
   - `thread backtrace`
   - `source list -l 2765`
   - `frame variable --show-types write_req`
   - `continue`
7. At `Exec.zig:457`:
   - `thread backtrace`
   - `source list -l 457`
   - `frame variable --show-types slice`
   - `frame variable --show-types linefeed`
   - `continue`
8. At `Exec.zig:1248`:
   - `thread backtrace`
   - `source list -l 1248`
   - `continue`
9. At `Exec.zig:1298`:
   - `source list -l 1298`
   - `next`
   - `frame variable --show-types n`
   - `memory read --format c --size 1 --count 16 &buf`
   - `continue`
10. At `Termio.zig:678`:
   - `thread backtrace`
   - `source list -l 678`
   - `frame variable --show-types buf`
   - `continue`
11. At `Termio.zig:687`:
   - `source list -l 687`
   - `frame variable --show-types buf`
   - `continue`
12. At `Termio.zig:728`:
   - `source list -l 728`
   - `frame variable --show-types buf`
   - `continue`
13. At `renderer/Thread.zig:596`:
   - `thread backtrace`
   - `source list -l 596`
   - `continue`
14. At `renderer/generic.zig:1173`:
   - `source list -l 1173`
   - `frame variable --show-types state`
   - `continue`

Useful checks:

- `thread list`
- `frame variable self.terminal`
- `frame variable self.renderer_state`
- `finish`

Notes:

- This session uses staged breakpoints so the Ghostty window can become visible
  and usable before the walkthrough starts.
- `ls` can trigger multiple reads and multiple render passes. Prove the chain
  once; you do not need to follow every repeated hit.
- There is no Ghostty breakpoint "inside the slave PTY." The best Ghostty-side
  evidence is the read thread seeing the returned bytes in `buf`.
- `Exec.zig:457` is the bridge from "Ghostty is writing the command" to
  "Ghostty will later read back the shell/tty response."
- `Termio.zig:687` shows the processing block where render wakeup is queued.
- `Termio.zig:728` is the actual `terminal_stream.nextSlice(buf)` call for the
  ordinary bulk parser path.
- If `buf` is large or unreadable, use the thread identity and source location
  to answer the architectural question.
