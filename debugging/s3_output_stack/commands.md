# S3 Commands

At the LLDB prompt:

1. Start the app:
   `run`
2. Type `ls` and press Enter.
3. At `Exec.zig:1248`:
   - `thread backtrace`
   - `source list -l 1248`
   - `continue`
4. At `Exec.zig:1298`:
   - `source list -l 1298`
   - `frame variable --show-types n`
   - `continue`
5. At `Termio.zig:678`:
   - `thread backtrace`
   - `source list -l 678`
   - `frame variable --show-types buf`
   - `continue`
6. At `Termio.zig:687`:
   - `source list -l 687`
   - `frame variable --show-types buf`
   - `continue`
7. At `Termio.zig:728`:
   - `source list -l 728`
   - `frame variable --show-types buf`
   - `continue`
8. At `renderer/Thread.zig:596`:
   - `thread backtrace`
   - `source list -l 596`
   - `continue`
9. At `renderer/generic.zig:1173`:
   - `source list -l 1173`
   - `frame variable --show-types state`
   - `continue`

Useful checks:

- `thread list`
- `frame variable self.terminal`
- `frame variable self.renderer_state`
- `finish`

Notes:

- `ls` can trigger multiple reads and multiple render passes. Prove the chain
  once; you do not need to follow every repeated hit.
- `Termio.zig:687` shows the processing block where render wakeup is queued.
- `Termio.zig:728` is the actual `terminal_stream.nextSlice(buf)` call for the
  ordinary bulk parser path.
- If `buf` is large or unreadable, use the thread identity and source location
  to answer the architectural question.
