# Sub-task 4 Deep Dive: How to Wire `.windows` to Create a Surface

A tutorial for engineers new to Ghostty, threading, and systems programming.

---

## The problem in one sentence

The Viewer says "here are the tmux windows" on a background thread, but creating
a Surface can only happen on the main thread. We need to bridge that gap.

Before diving into the solution, you need to understand three things: what
threads exist, what the main thread is, and what mailboxes are. Let's build
from first principles.

---

## Part 1: What is a thread and why does Ghostty use them?

A thread is an independent stream of execution. Your CPU can run multiple threads
at once (one per core). A single-threaded program does one thing at a time — if
it's reading from the network, it can't draw to the screen until the read
finishes. A multi-threaded program can do both simultaneously.

Ghostty uses threads because a terminal emulator has three jobs that must happen
at the same time:

1. **Read output from the shell** (could block for seconds waiting for data)
2. **Draw pixels to the screen** (must happen at 60-120fps, can't stall)
3. **Handle user input and app events** (must stay responsive)

If these were on one thread, a slow shell command would freeze the entire UI.
So Ghostty puts each job on its own thread.

---

## Part 2: Ghostty's thread model (for one Surface)

When you open a terminal in Ghostty, **four threads** are involved:

```
┌─────────────────────────────────────────────────────────────────────┐
│                         MAIN THREAD                                │
│                                                                    │
│  The macOS application thread (or GTK main loop on Linux).         │
│  Handles: window creation, user input events, app lifecycle.       │
│  Runs: the apprt event loop.                                       │
│                                                                    │
│  This thread exists before Ghostty starts and after it stops.      │
│  On macOS, it's the thread that runs NSApplication.run().          │
│  All Cocoa/UIKit work MUST happen here (Apple's rule, not ours).   │
│                                                                    │
│  Ghostty calls it via: ghostty_app_tick() → App.tick()             │
│  which drains the app mailbox and processes messages.              │
└─────────────────────────┬───────────────────────────────────────────┘
                          │ spawns during Surface.init()
              ┌───────────┴───────────┐
              ▼                       ▼
┌──────────────────────┐  ┌──────────────────────┐
│    RENDERER THREAD   │  │      IO THREAD        │
│    (name: "renderer")│  │    (name: "io")        │
│                      │  │                        │
│ Reads Terminal state │  │ Runs an xev event loop.│
│ under mutex, builds  │  │ Drains its mailbox:    │
│ GPU draw commands,   │  │ resize, focus, write   │
│ submits to Metal/GL. │  │ requests from Surface. │
│                      │  │                        │
│ Wakes up when:       │  │ Handles messages FROM  │
│ - renderer_wakeup    │  │ the main thread (e.g., │
│   is notified        │  │ "the user typed 'a'"). │
│ - cursor blink timer │  └──────────┬─────────────┘
│ - custom shader anim │             │ spawns during
└──────────────────────┘             │ Exec.threadEnter()
                                     ▼
                          ┌──────────────────────┐
                          │    READ THREAD        │
                          │  (name: "io-reader")  │
                          │                       │
                          │ Tight loop:           │
                          │   posix.read(pty_fd)  │
                          │   → processOutput()   │
                          │   → VT parser         │
                          │   → Terminal updates   │
                          │                       │
                          │ This is where shell   │
                          │ output becomes pixels. │
                          └───────────────────────┘
```

### Key facts

- **Main thread**: created by the OS, lives for the app's entire lifetime. On
  macOS it is the thread that runs `NSApplication`. Ghostty does not own it —
  macOS does. Ghostty hooks into it via callbacks.

- **Renderer thread**: created at `Surface.zig:722-726`, destroyed at
  `Surface.zig:806-811`. One per Surface. Draws frames to the GPU.

- **IO thread**: created at `Surface.zig:730-734`, destroyed at
  `Surface.zig:812-816`. One per Surface. Runs an xev event loop that handles
  messages from the main thread (write requests, resize, focus changes).

- **Read thread**: created inside the IO thread at `Exec.zig:139-143` during
  `threadEnter()`, name `"io-reader"`. One per exec Backend. Reads PTY output
  and calls `processOutput()` directly. **This is a DIFFERENT thread from the
  IO thread** — it's spawned BY the IO thread but runs independently.

### The IO thread vs. the read thread — a common confusion

These are **two separate OS threads** with different jobs:

| | IO thread ("io") | Read thread ("io-reader") |
|---|---|---|
| **Created at** | `Surface.zig:730` | `Exec.zig:139` (inside IO thread's `threadEnter`) |
| **Runs** | xev event loop, drains mailbox | Tight `posix.read()` loop on PTY fd |
| **Handles** | Messages FROM Surface (writes, resize) | Data FROM shell (VT sequences) |
| **Calls** | `io.queueWrite()`, `io.focusGained()` | `Termio.processOutput()` directly |
| **Dies** | When `stop` async is notified | When quit pipe is signaled |

The `.windows` action runs on the **read thread**, not the IO thread. Here is
exactly why (traced from code):

---

## Part 3: Proof — what thread does `.windows` run on?

Here is the exact call chain, with file:line references. Every call is
synchronous (same thread, same stack frame). No async dispatch. No mailbox.

```
READ THREAD ("io-reader") starts in Exec.zig
│
│ Step 1: Read bytes from PTY
│ ┌─────────────────────────────────────────────────────────┐
│ │ Exec.zig:1305                                           │
│ │   const n = posix.read(fd, &buf);                       │
│ └─────────────────────────────────────────────────────────┘
│
│ Step 2: Call processOutput (inlined, same thread)
│ ┌─────────────────────────────────────────────────────────┐
│ │ Exec.zig:1335                                           │
│ │   @call(.always_inline,                                 │
│ │         termio.Termio.processOutput, .{io, buf[0..n]}); │
│ └─────────────────────────────────────────────────────────┘
│
│ Step 3: Lock the renderer mutex
│ ┌─────────────────────────────────────────────────────────┐
│ │ Termio.zig:662                                          │
│ │   self.renderer_state.mutex.lock();                     │
│ │   // ALL subsequent steps hold this lock                │
│ └─────────────────────────────────────────────────────────┘
│
│ Step 4: Feed bytes through VT parser
│ ┌─────────────────────────────────────────────────────────┐
│ │ Termio.zig:708                                          │
│ │   self.terminal_stream.nextSlice(buf);                  │
│ │   // This calls Parser.next() for each byte             │
│ └─────────────────────────────────────────────────────────┘
│
│ Step 5: Parser detects DCS sequence (ESC P 1000 p)
│ ┌─────────────────────────────────────────────────────────┐
│ │ stream.zig:737-739 (action dispatch)                    │
│ │   .dcs_put => handler.vt(.dcs_put, code)                │
│ └─────────────────────────────────────────────────────────┘
│
│ Step 6: StreamHandler receives DCS data
│ ┌─────────────────────────────────────────────────────────┐
│ │ stream_handler.zig:374-377                              │
│ │   pub fn dcsPut(self, byte) → dcsCommand(&cmd)          │
│ └─────────────────────────────────────────────────────────┘
│
│ Step 7: DCS command is a tmux notification
│ ┌─────────────────────────────────────────────────────────┐
│ │ stream_handler.zig:389                                  │
│ │   .tmux => |tmux| {                                     │
│ │       // tmux control mode data                         │
│ └─────────────────────────────────────────────────────────┘
│
│ Step 8: Viewer processes the notification, emits .windows
│ ┌─────────────────────────────────────────────────────────┐
│ │ stream_handler.zig:443                                  │
│ │   for (viewer.next(.{ .tmux = tmux })) |action| {      │
│ │       switch (action) {                                 │
│ │           .windows => |windows| {                       │  ← LINE 468
│ │               // WE ARE HERE                            │
│ │               // Thread: io-reader                      │
│ │               // Lock held: renderer_state.mutex        │
│ │           },                                            │
│ │       }                                                 │
│ │   }                                                     │
│ └─────────────────────────────────────────────────────────┘
│
│ Step 9: processOutput returns, mutex released
│ ┌─────────────────────────────────────────────────────────┐
│ │ Termio.zig:663                                          │
│ │   defer self.renderer_state.mutex.unlock();             │
│ └─────────────────────────────────────────────────────────┘
```

**Conclusion:** The `.windows` handler at `stream_handler.zig:468` runs on the
read thread (`io-reader`), with the original Surface's `renderer_state.mutex`
held. This is not the main thread. This is not the IO thread. This is the
read thread — a background thread that exists solely to read PTY output.

---

## Part 4: Why can't we create a Surface here?

`Surface.init()` has a doc comment at `Surface.zig:464`:

> "Create a new surface. This must be called from the main thread."

Why? Three reasons:

1. **GPU context**: `Renderer.surfaceInit()` (called from `Surface.init` at
   line 500) initializes Metal/OpenGL state. GPU APIs require main-thread
   access on macOS — Apple enforces this.

2. **NSView creation**: On macOS, the Surface needs an `NSView` (the native
   widget). All Cocoa UI objects must be created on the main thread — calling
   `[[NSView alloc] init]` from a background thread is undefined behavior.

3. **App state**: `Surface.init()` calls `app.addSurface()` which modifies the
   app's surface list. The app is not thread-safe — it expects to be modified
   only from the main thread during `tick()`.

If you call `Surface.init()` from the read thread, you will get:
- Crashes in Metal initialization
- Cocoa assertions (`"Modifications to the layout engine must not be performed
  from a background thread"`)
- Corrupted app state (race conditions on the surface list)

---

## Part 5: What is the main thread, exactly?

### Where it comes from

On macOS, the main thread is created by the OS when your app launches. The
Ghostty macOS app is a Swift/Xcode project. When the app starts:

1. macOS creates the main thread
2. Swift's `@main` attribute starts `NSApplication.run()` on it
3. `NSApplication.run()` enters Cocoa's event loop (an infinite loop that
   handles UI events, timers, and notifications)
4. The Swift app delegate creates a `ghostty_app_t` (the Zig `App`) and stores it

### How Ghostty hooks into it

The main thread runs Cocoa's event loop, not Ghostty's code. Ghostty hooks in
via a **wakeup callback**:

```
┌────────────────────────────────────────────────────────────┐
│                   macOS MAIN THREAD                         │
│                                                            │
│  NSApplication.run()    ← Cocoa's infinite event loop      │
│    │                                                       │
│    ├─ handle keyboard event → ghostty_surface_key()        │
│    ├─ handle mouse event   → ghostty_surface_mouse_*()     │
│    ├─ handle resize        → ghostty_surface_set_size()    │
│    │                                                       │
│    └─ WAKEUP received     → ghostty_app_tick()             │
│         │                      │                           │
│         │                      ▼                           │
│         │                App.tick()                         │
│         │                  └─ drainMailbox()                │
│         │                      ├─ .new_window → create it  │
│         │                      ├─ .surface_message → route │
│         │                      └─ .quit → stop             │
│         │                                                  │
│         │  (the wakeup is sent by background threads       │
│         │   when they push messages to the app mailbox)    │
└────────────────────────────────────────────────────────────┘
```

The wakeup mechanism (`embedded.zig:232-234`):

```zig
pub fn wakeup(self: *const App) void {
    self.opts.wakeup(self.opts.userdata);
}
```

This calls a Swift callback that schedules `ghostty_app_tick()` on the main
thread. The `ghostty_app_tick()` function (`embedded.zig:1425-1428`) calls
`App.tick()` which calls `App.drainMailbox()`.

### Lifecycle

```
App launch ──────────────────────────────────────────────── App quit
     │                                                        │
     │  main thread exists for the entire app lifetime        │
     │                                                        │
     ├── Surface.init() runs here (creates threads)           │
     ├── App.tick() runs here (drains mailbox)                │
     ├── User input callbacks run here                        │
     ├── performAction callbacks run here                     │
     └── Surface.deinit() runs here (joins threads)           │
```

The main thread never stops. It exists before any Surface is created and after
all Surfaces are destroyed. It is the "parent" of all other threads.

---

## Part 6: What is the surface_mailbox and how does it work?

The surface_mailbox is the mechanism that background threads use to send messages
to the main thread. Think of it as a one-way pipe: background threads put
messages in, the main thread takes them out.

### The chain

```
  BACKGROUND THREAD                    MAIN THREAD
  (read thread or IO thread)           (macOS app thread)
         │                                   │
         │ surface_mailbox.push(msg)          │
         │         │                          │
         │         ▼                          │
         │  ┌─────────────────────┐           │
         │  │ apprt.surface.Mailbox│           │
         │  │ (stream_handler.zig:31)         │
         │  │                     │           │
         │  │ Wraps the message:  │           │
         │  │ .surface_message {  │           │
         │  │   .surface = self,  │           │
         │  │   .message = msg    │           │
         │  │ }                   │           │
         │  └────────┬────────────┘           │
         │           │                        │
         │           ▼                        │
         │  ┌─────────────────────┐           │
         │  │   App.Mailbox       │           │
         │  │ (App.zig:578-595)   │           │
         │  │                     │           │
         │  │ BlockingQueue(64)   │           │
         │  │ push() + wakeup()   │──────────►│ wakeup triggers
         │  └─────────────────────┘           │ ghostty_app_tick()
         │                                    │
         │                                    ▼
         │                           App.drainMailbox()
         │                           (App.zig:237-265)
         │                                    │
         │                                    ▼
         │                           match .surface_message
         │                           → App.surfaceMessage()
         │                           → surface handles it
```

### Where it's created

The `surface_mailbox` is created during `Surface.init()` and passed to Termio:

```zig
// Surface.zig:557
const app_mailbox: App.Mailbox = .{ .rt_app = rt_app, .mailbox = &app.mailbox };

// Surface.zig:684 (inside Termio.init options)
.surface_mailbox = .{ .surface = self, .app = app_mailbox },
```

Termio passes it to the StreamHandler at `Termio.zig:293`:
```zig
.surface_mailbox = opts.surface_mailbox,
```

The StreamHandler stores it as a field at `stream_handler.zig:31`:
```zig
surface_mailbox: apprt.surface.Mailbox,
```

### What messages it can carry today

The `apprt.surface.Message` union (`apprt/surface.zig:14-110`) has ~22 variants:

```
set_title, report_title, set_mouse_shape, clipboard_read, clipboard_write,
change_config, close, child_exited, desktop_notification, renderer_health,
present_surface, password_input, color_change, selection_scroll_tick,
pwd_change, ring_bell, progress_report, start_command, stop_command,
scrollbar, search_total, search_selected
```

**None of these create a Surface.** That's the gap.

### Lifecycle

The surface_mailbox lives as long as the Surface it belongs to. It's created
during `Surface.init()` and becomes invalid after `Surface.deinit()`. The
background threads stop before `deinit()` (threads are joined at
`Surface.zig:806-816`), so the mailbox is always valid while threads use it.

---

## Part 7: What is performAction and how does it work?

`performAction` is the mechanism that Ghostty's core (Zig) uses to ask the
platform (Swift on macOS, GTK on Linux) to do something — like creating a
window or setting a title.

### The flow

```
  GHOSTTY CORE (Zig)                          PLATFORM (Swift/GTK)
         │                                           │
         │  rt_app.performAction(                     │
         │      target,                               │
         │      .new_window,                          │
         │      {},                                   │
         │  )                                         │
         │         │                                  │
         │         ▼                                  │
         │  embedded.zig:281                          │
         │  self.opts.action(                         │
         │      self,                                 │
         │      target.cval(),      ──── C ABI ──────►│
         │      action.cval(),                        │
         │  )                                         │
         │                                            │
         │                                            ▼
         │                                   Swift receives action
         │                                   Creates NSWindow
         │                                   Creates NSView
         │                                   Calls ghostty_surface_new()
         │                                            │
         │                                            ▼
         │                                   Surface.init() runs
         │                                   (on main thread)
```

### How it's used today for new windows

When the user presses Cmd+N:

1. macOS sends a keyboard event to the main thread
2. `ghostty_surface_key()` → `Surface.keyCallback()` matches the keybinding
3. `performAction(.new_window)` is called
4. This calls `App.newWindow()` (`App.zig:292-304`)
5. Which calls `rt_app.performAction(target, .new_window, {})`
6. The embedded runtime calls `self.opts.action(...)` — a C function pointer
7. Swift receives this, creates an NSWindow, calls `ghostty_surface_new()`
8. `ghostty_surface_new()` calls `Surface.init()` → backend is always exec

**This all happens synchronously on the main thread.** That's why it works.

### What action types exist for creating surfaces?

From `apprt/action.zig`:

```zig
pub const Action = union(Key) {
    new_window,                    // creates a new window
    new_tab,                       // creates a new tab
    new_split: SplitDirection,     // creates a new split pane
    // ... 50+ other actions
};
```

All three always create exec-backed Surfaces. There is no way to say "create a
new window with a tmux backend."

---

## Part 8: The threading problem, visualized

Here's the full picture of why Sub-task 4 is hard:

```
┌──────────────────────────────────────────────────────────────────┐
│ READ THREAD ("io-reader")                                        │
│                                                                  │
│  posix.read(pty_fd)                                              │
│  → processOutput()                                               │
│  → VT parser → DCS → tmux control parser                        │
│  → Viewer.next() emits .windows action                           │
│  → stream_handler.zig:468                                        │
│                                                                  │
│  WE ARE HERE. We have window/pane data.                          │
│  We need a Surface created.                                      │
│  But we CANNOT call Surface.init() — wrong thread.               │
│                                                                  │
│  We also hold renderer_state.mutex — we can't block.             │
│                                                                  │
│  What can we do from here?                                       │
│  ✓ Push a message to surface_mailbox (fast, non-blocking)        │
│  ✗ Call Surface.init() (WRONG THREAD — crashes)                  │
│  ✗ Call performAction() directly (WRONG THREAD)                  │
│  ✗ Block and wait for main thread (DEADLOCK — we hold mutex)     │
└──────────────────────────────────────────────────────────────────┘
         │
         │ surface_mailbox.push(???)
         │ BUT: there's no message type for "create a surface"!
         │
         ▼
┌──────────────────────────────────────────────────────────────────┐
│ MAIN THREAD                                                      │
│                                                                  │
│  App.drainMailbox() runs on every tick.                           │
│  IF we had a message type for "create tmux surface":             │
│                                                                  │
│  .surface_message => |msg| {                                     │
│      switch (msg.message) {                                      │
│          .tmux_create_surface => |info| {                        │
│              // NOW we're on the main thread                     │
│              // We CAN call Surface.init()                       │
│              // We CAN call performAction(.new_window)           │
│              // We CAN create NSViews                            │
│          },                                                      │
│      }                                                           │
│  }                                                               │
└──────────────────────────────────────────────────────────────────┘
```

---

## Part 9: How Sub-task 4 would be implemented (from first principles)

### Step 1: Decide the signaling mechanism

We need the read thread to tell the main thread "please create a tmux Surface."
There are three options. Here's each one analyzed:

**Option A: New surface message variant**

Add a new variant to `apprt.surface.Message`:

```zig
// apprt/surface.zig — add to the Message union:
tmux_create_surface: struct {
    pane_id: usize,
    width: usize,
    height: usize,
},
```

Then in `stream_handler.zig:468`:
```zig
.windows => |windows| {
    for (windows) |w| {
        self.surfaceMessageWriter(.{
            .tmux_create_surface = .{
                .pane_id = w.layout.content.pane,
                .width = w.width,
                .height = w.height,
            },
        });
    }
},
```

The message flows through the existing path:
`surface_mailbox → App.Mailbox → App.drainMailbox() → App.surfaceMessage()`

Then `App.surfaceMessage()` handles it on the **main thread**.

**Pros:** Uses existing mailbox infrastructure. No new message path needed.
**Cons:** The surface_mailbox is tied to the original Surface (the one running
`tmux -CC`). Surface messages are routed to the Surface that sent them. We'd
need the app-level handler to know that this particular message means "create a
NEW surface", not "do something to THIS surface."

**Option B: New app mailbox message**

Add a new variant to `App.Message` directly:

```zig
// App.zig — add to Message union:
new_tmux_surface: struct {
    parent: *Surface,
    pane_id: usize,
    width: usize,
    height: usize,
},
```

Then in `stream_handler.zig`, push to the app mailbox instead of the surface
mailbox. The StreamHandler currently has `surface_mailbox` which wraps
`App.Mailbox`. You can access the app mailbox through `self.surface_mailbox.app`:

```zig
.windows => |windows| {
    for (windows) |w| {
        _ = self.surface_mailbox.app.push(.{
            .new_tmux_surface = .{
                .parent = self.surface_mailbox.surface,
                .pane_id = w.layout.content.pane,
                .width = w.width,
                .height = w.height,
            },
        }, .{ .instant = {} });
    }
},
```

Then in `App.drainMailbox()`:
```zig
.new_tmux_surface => |info| {
    // We're on the main thread now!
    // Call performAction(.new_window) or create Surface directly
},
```

**Pros:** Clean separation — it's an app-level concern, not a surface-level one.
**Cons:** Adds a new app message type. Must be handled in `drainMailbox`.

**Option C: Reuse performAction(.new_window) with metadata**

Instead of a new message type, call `performAction(.new_window)` from the main
thread after receiving a signal. But this requires modifying `new_window` to
carry a backend selection — a larger change that affects the existing window
creation flow.

**Pros:** Reuses existing infrastructure most aggressively.
**Cons:** Changes the semantics of `new_window` for all backends. Higher risk.

### Step 2: Handle on the main thread

Whichever option is chosen, the main thread handler must:

1. Create the tmux Backend struct: `termio.Tmux{ .pane_id = pane_id }`
2. Call `Surface.init()` with the tmux backend (this requires modifying
   `Surface.init` to accept a backend config — today it hardcodes exec)
3. Or call `performAction(.new_window)` and have the window creation path
   accept a backend parameter

### Step 3: Modify Surface.init to accept non-exec backends

Today, `Surface.init()` at lines 638-685 hardcodes exec:

```zig
// Line 656-668: Create exec backend
var io_exec = try termio.Exec.init(alloc, .{ ... });

// Line 679: Hardcode exec backend
.backend = .{ .exec = io_exec },
```

This needs a branch:

```zig
const backend: termio.Backend = if (opts.tmux_config) |tmux_config|
    .{ .tmux = try termio.Tmux.init(alloc, tmux_config) }
else blk: {
    var io_exec = try termio.Exec.init(alloc, .{ ... });
    break :blk .{ .exec = io_exec };
};

// Line 679:
.backend = backend,
```

### Step 4: Handle the Swift side (macOS only)

If using a new action type, the Swift app must handle it. If reusing
`new_window`, the Swift side already creates windows — no changes needed on
the Swift side, only on the Zig side (the backend selection happens in
`Surface.init`, not in Swift).

This is why **Option B (new app mailbox message)** may be simplest: the app
mailbox handler on the main thread can call `rt_app.performAction(.new_window)`
which already works on the Swift side. The only change is that `Surface.init`
(called by Swift after creating the NSWindow) needs to know to use a tmux
backend instead of exec. This could be done via a field on the app or a
thread-local variable — but the exact mechanism is a Q3 maintainer question.

---

## Part 10: Sequence diagram — the complete flow after implementation

```
┌─────────┐ ┌──────────┐ ┌──────────┐ ┌────────┐ ┌───────┐ ┌───────────┐
│  tmux   │ │ Read     │ │ Stream   │ │ App    │ │ Swift │ │ New tmux  │
│  server │ │ Thread   │ │ Handler  │ │ Main   │ │ macOS │ │ Surface   │
│         │ │(io-reader)│ │          │ │ Thread │ │       │ │           │
└────┬────┘ └────┬─────┘ └────┬─────┘ └───┬────┘ └───┬───┘ └─────┬─────┘
     │           │            │            │          │            │
     │ %begin    │            │            │          │            │
     │ $0 @0 ... │            │            │          │            │
     │──────────►│            │            │          │            │
     │           │            │            │          │            │
     │           │ processOutput()        │          │            │
     │           │ (locks mutex)           │          │            │
     │           │───────────►│            │          │            │
     │           │            │            │          │            │
     │           │            │ Viewer     │          │            │
     │           │            │ parses     │          │            │
     │           │            │ list-windows          │            │
     │           │            │ emits .windows        │            │
     │           │            │            │          │            │
     │           │            │ push to    │          │            │
     │           │            │ app mailbox│          │            │
     │           │            │───────────►│          │            │
     │           │            │ (non-blocking)        │            │
     │           │            │            │          │            │
     │           │ mutex unlocked          │          │            │
     │           │◄───────────│            │          │            │
     │           │            │            │          │            │
     │           │            │      wakeup callback  │            │
     │           │            │            │◄─────────│            │
     │           │            │            │          │            │
     │           │            │   App.tick() / drainMailbox()      │
     │           │            │            │          │            │
     │           │            │   match .new_tmux_surface          │
     │           │            │            │          │            │
     │           │            │            │ performAction         │
     │           │            │            │ (.new_window)         │
     │           │            │            │─────────►│            │
     │           │            │            │          │            │
     │           │            │            │          │ create     │
     │           │            │            │          │ NSWindow   │
     │           │            │            │          │            │
     │           │            │            │  ghostty_surface_new()│
     │           │            │            │◄─────────│            │
     │           │            │            │          │            │
     │           │            │   Surface.init()      │            │
     │           │            │   (with .tmux backend)│            │
     │           │            │            │─────────────────────►│
     │           │            │            │          │   created! │
     │           │            │            │          │   renderer │
     │           │            │            │          │   + IO thd │
     │           │            │            │          │   spawned  │
```

---

## Summary: what makes Sub-task 4 hard

| Problem | Why it's hard |
|---------|---------------|
| Threading | `.windows` runs on read thread; Surface.init needs main thread |
| No existing path | No mailbox message type exists for "create a Surface" |
| Cross-ABI | On macOS, Surface creation crosses Zig → C → Swift boundary |
| Surface.init hardcoded | Backend is always exec; needs a new code path |
| Mutex held | The read thread holds `renderer_state.mutex` when `.windows` fires; must not block |

This is the core of what Mitchell called "pretty fundamentally hard." The
Backend enum changes (Sub-tasks 1-3) are mechanical. This cross-thread
orchestration is the real engineering challenge.
