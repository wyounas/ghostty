# S0: Startup, Threads, and the First Surface

## Learning objectives

- See the first practical user-code entrypoint for the macOS app.
- See where the macOS app thread enters Zig.
- Watch the first `Surface` build its renderer and termio state.
- Confirm which threads are spawned per surface.

## Success criteria

After this session, you should be able to answer:

1. On macOS, where is the real app thread?
2. What is the first practical startup line of Ghostty's own macOS app code?
3. Which parts of `Surface.init()` run before any child threads exist?
4. Which threads does a normal exec-backed surface create?
5. Where does the first renderer wakeup come from?

## Prerequisites

- Build the Debug macOS app first:
  - `zig build -Demit-macos-app=false`
  - `macos/build.nu --scheme Ghostty --configuration Debug --action build`
- Close any already-running Ghostty.app instance before starting LLDB.

## Expected duration

20-30 minutes.

## Run

1. From the repo root, run:
   `sh debugging/s0_startup_threads/run.sh`
2. At the LLDB prompt, run:
   `run`
3. Use the commands below as you move through the stops:
   - `continue` or `c`: run until the next breakpoint
   - `next` or `n`: step over the current source line
   - `step` or `s`: step into the called function on the current line
   - `finish`: run until the current function returns
   - `thread backtrace`: show how this frame was reached
   - `thread list`: show all current threads
   - `frame variable`: show locals in the current frame
   - `frame variable --show-types <name>`: show one local with its type
   - `source list -l <line>`: show source around an important line
4. At each stop, inspect the variables and use the validation notes below.

## How to think about LLDB output in Zig

If LLDB shows hex values such as `0x0000...`, that is usually not a bug. It
often means one of these:

- the value is a pointer, so LLDB is showing you the address
- the value is an opaque handle, not a human-readable struct
- LLDB knows the location of the value better than it knows how to pretty-print
  the Zig type

For this session, do **not** try to learn the architecture by decoding giant
struct dumps. Validate the walkthrough in three simpler ways:

1. **Use control flow.**
   If execution is at [Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:549),
   then thread spawn has not happened yet, because the spawn calls are later at
   [Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:700) and
   [Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:708).

2. **Inspect small, named locals instead of huge parent structs.**
   Good examples in this session are:
   - `app_mailbox`
   - `renderer_impl`
   - `render_thread`
   - `io_thread`
   - `io_exec`
   - `io_mailbox`

3. **Use backtraces and thread lists.**
   For thread questions, `thread backtrace` and `thread list` are often more
   useful than printing a large value.

## Important note about the first stop

For the very first surface during app startup, it is normal to stop first at
`ghostty_surface_new` in `embedded.zig`, not at `Ghostty.App.swift:116`.

Reason:

- `appTick()` is the wakeup-driven app-mailbox path
- but the first surface is often created directly from Swift app/runtime UI
  startup code
- so ordinary startup can reach `ghostty_surface_new` before any `appTick()`
  breakpoint is hit

So if `run` lands first in `embedded.zig:1541`, that is expected and correct.
Do not treat it as a debugger mistake.

## Where the app starts on macOS

There are two different answers:

1. **Absolute first execution**
   The real absolute beginning is OS loader and runtime startup code before your
   own source files run. That is usually too low-level for this study session.

2. **First practical Ghostty app code**
   The first useful line in Ghostty's own macOS app code is in
   [macos/Sources/App/macOS/main.swift](/Users/waqas/code/ghostty_forked/macos/Sources/App/macOS/main.swift:8):

   - `ghostty_init(...)` at line 8
   - then `ghostty_cli_try_action()` at line 31
   - then `NSApplicationMain(...)` at line 33

For learning Ghostty startup, `main.swift:8` is the best “starting point”
breakpoint.

After that, the next useful startup stops are:

- [AppDelegate.swift:164](/Users/waqas/code/ghostty_forked/macos/Sources/App/macOS/AppDelegate.swift:164)
  `AppDelegate.init`
- [AppDelegate.swift:203](/Users/waqas/code/ghostty_forked/macos/Sources/App/macOS/AppDelegate.swift:203)
  `applicationDidFinishLaunching`
- [embedded.zig:1541](/Users/waqas/code/ghostty_forked/src/apprt/embedded.zig:1541)
  `ghostty_surface_new`

## What to watch for

- `main.swift:8` is the first practical Ghostty app-code startup point on macOS.
- `NSApplicationMain(...)` in `main.swift` hands control to AppKit.
- `AppDelegate.init` creates `Ghostty.App`.
- `ghostty_surface_new` is the ordinary entrypoint for creating a surface.
- `Surface.init()` wires app mailbox, renderer state, exec backend, and termio
  before it spawns the renderer and IO threads.
- The exec backend later adds its own PTY read thread from inside thread-enter
  logic.
- `appTick()` in Swift is still the main-thread bridge for app-mailbox work,
  but it is not guaranteed to be the first interesting startup stop for this
  session.

## How to validate “what to watch for”

### 1. Validate the first practical app startup point

At the stop in
[main.swift](/Users/waqas/code/ghostty_forked/macos/Sources/App/macOS/main.swift:8):

- run `thread backtrace`
- run `source list -l 8`
- run `next`

What you are proving:

- this is the first practical line in Ghostty's own macOS app startup code
- Ghostty does global initialization before it hands control to AppKit

Optional:

- step to line 31 and line 33 with `next`
- confirm that `NSApplicationMain` is the handoff into the Cocoa app lifecycle

### 2. Validate that `ghostty_surface_new` is the ordinary startup entrypoint

At the stop in
[embedded.zig](/Users/waqas/code/ghostty_forked/src/apprt/embedded.zig:1541):

- run `thread backtrace`
- run `source list -l 1541`
- confirm the deeper frames are Swift/UI startup frames, not renderer or IO
  frames

What you are proving:

- the first surface is often created directly from app/runtime startup code
- surface creation is happening on the macOS main thread
- this session should start from ordinary surface construction, not from mailbox
  wakeup logic

### 3. Validate that `appTick()` is the Swift main-thread bridge, but only as an optional follow-up

At the stop in
[Ghostty.App.swift](/Users/waqas/code/ghostty_forked/macos/Sources/Ghostty/Ghostty.App.swift:116),
if it happens later:

- run `thread backtrace`
- run `source list -l 116`
- run `next`

What you are proving:

- `appTick()` is still the main-thread bridge into Zig app work
- but it is a wakeup/mailbox path, not the only way startup reaches Zig code

### 4. Validate that `Surface.init()` wires state before thread spawn

This is the most important check in the session.

At the stop in
[Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:549):

- run `source list -l 549`
- run `frame variable --show-types app_mailbox`
- run `frame variable --show-types render_thread`
- run `frame variable --show-types io_thread`

Then use `next` to walk forward through the block, watching the source, not
just the values.

What to confirm from the source and current location:

- `app_mailbox` exists before `self.*` is assigned
- renderer machinery is being prepared before thread spawn
- IO thread manager is created before thread spawn
- the thread spawn lines are still later in the file at
  [Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:700) and
  [Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:708)

At the stop in
[Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:654):

- run `source list -l 654`
- run `frame variable --show-types io_exec`
- run `frame variable --show-types io_mailbox`
- run `frame variable --show-types self.renderer_state`

What you are proving here:

- the exec backend object has been created before any child thread starts
- the termio mailbox exists before any child thread starts
- `Termio.init` is called before the renderer and IO threads are spawned

### 5. Validate that renderer and IO threads are only spawned later

At the stops in
[Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:700) and
[Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:708):

- run `thread list`
- run `thread backtrace`
- use `next` once at each line
- run `thread list` again

What you are proving:

- these are the exact spawn points for the renderer thread and IO thread
- they were not already running earlier in `Surface.init()`

### 6. Validate that the PTY read thread is added later by the exec backend

At the stop in
[Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:137):

- run `source list -l 137`
- run `thread backtrace`
- run `next`

What you are proving:

- the extra PTY read thread is not spawned by `Surface.init()` directly
- it is spawned later by the exec backend during thread-enter/startup work
- this is why a normal exec-backed surface ends up with one more thread than
  just renderer plus IO

## What this session does not cover

- Keyboard input details
- PTY reads and terminal parsing
- tmux control mode
