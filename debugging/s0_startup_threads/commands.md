# S0 Commands

At the LLDB prompt:

1. Start the app:
   `run`
2. First practical startup stop: `main.swift:8`
   - `thread backtrace`
   - `source list -l 8`
   - `next`
   - `continue`
3. Early Cocoa/app startup stop: `AppDelegate.swift:164`
   - `thread backtrace`
   - `source list -l 164`
   - `next`
   - `continue`
4. App-finish-launching stop: `AppDelegate.swift:203`
   - `thread backtrace`
   - `source list -l 203`
   - `next`
   - `continue`
5. First expected surface-creation stop during startup: `embedded.zig:1541`
   - `thread backtrace`
   - `source list -l 1541`
   - `frame variable --show-types app`
   - `frame variable --show-types opts`
   - `continue`
6. At `Surface.zig:549`:
   - `source list -l 549`
   - `frame variable --show-types app_mailbox`
   - `frame variable --show-types renderer_impl`
   - `frame variable --show-types render_thread`
   - `frame variable --show-types io_thread`
   - `next`
   - `continue`
7. At `Surface.zig:654`:
   - `source list -l 654`
   - `frame variable --show-types io_exec`
   - `frame variable --show-types io_mailbox`
   - `frame variable --show-types self.renderer_state`
   - `next`
   - `continue`
8. At `Surface.zig:700` and `:708`:
   - `source list -l 700`
   - `thread list`
   - `thread backtrace`
   - `next`
   - `continue`
9. At `renderer/Thread.zig:243`:
   - `source list -l 243`
   - `thread backtrace`
   - `continue`
10. At `Exec.zig:137`:
   - `source list -l 137`
   - `thread backtrace`
   - `next`
   - `thread list`
   - `continue`

Optional later stop, if it occurs:

11. At `Ghostty.App.swift:116`:
   - `thread backtrace`
   - `source list -l 116`
   - `next`
   - `continue`

Useful checks:

- `breakpoint list`
- `thread list`
- `image lookup -vn ghostty_app_tick`
- `frame variable --show-types <name>`
- `finish`

Notes:

- `main.swift:8` is the best practical startup breakpoint if you want the
  earliest Ghostty-owned app code on macOS.
- `main.swift:33` calls `NSApplicationMain`, which is the handoff into the
  AppKit lifecycle.
- If `run` lands first at `embedded.zig:1541`, that is expected for ordinary
  startup. The first surface can be created directly from Swift runtime code
  before any `appTick()` wakeup path is needed.
- If `frame variable self` only shows an address such as `0x0000...`, that is
  expected for a pointer. Prefer inspecting the smaller locals listed above.
- In this session, source position plus backtrace is usually more informative
  than dumping whole Zig structs.
