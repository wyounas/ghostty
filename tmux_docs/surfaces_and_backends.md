# Understanding Surfaces and Backends in Ghostty

A guide for engineers new to Ghostty, terminals, and Zig.

---

## What is a Surface?

A Surface is a single terminal view. It is the rectangle on your screen where you
see a shell prompt, where text appears when programs run, and where your keystrokes
go when you type.

Ghostty's own source code says it best (`src/Surface.zig:1-11`):

> Surface represents a single terminal "surface". A terminal surface is a minimal
> "widget" where the terminal is drawn and responds to events such as keyboard and
> mouse. Each surface also creates and owns its pty session.
>
> The word "surface" is used because it is left to the higher level application
> runtime to determine if the surface is a window, a tab, a split, a preview pane
> in a larger window, etc. This struct doesn't care: it just draws and responds to
> events.

The key insight: a Surface does NOT know whether it is a window, a tab, or a split
pane. It just draws terminal content and handles input. The application runtime
(apprt) layer above it decides how to present it — as a macOS window, a tab in a
tab bar, a split view, etc. This separation is what makes Ghostty work on both
macOS and Linux with completely different GUI toolkits.

---

## What does a Surface own?

A Surface (`src/Surface.zig:62-135`) owns these things:

```
Surface
  ├── id: u64                    — unique identifier
  ├── app: *App                  — reference to the application
  ├── rt_surface: *apprt.Surface — platform-specific widget (macOS NSView, GTK widget)
  ├── renderer: Renderer         — GPU renderer (Metal on macOS, OpenGL on Linux)
  ├── renderer_state: State      — mutex-protected terminal state shared with renderer
  ├── renderer_thread: Thread    — dedicated thread for rendering
  ├── io: termio.Termio          — terminal I/O coordinator
  ├── io_thread: termio.Thread   — dedicated thread for I/O
  ├── mouse: Mouse               — mouse tracking state
  ├── keyboard: Keyboard         — keyboard input state
  ├── size: Size                 — dimensions in pixels and cells
  └── inspector: ?*Inspector     — optional debugging inspector
```

The two most important things a Surface owns are `io` (the Termio, which manages
the terminal state and the backend) and `renderer_state` (which the renderer thread
reads from to draw pixels).

---

## What is a Backend?

A Backend is the thing that provides content to a Surface. It is what connects the
Surface to a source of terminal data.

Today, there is exactly one kind of Backend: `exec` (`src/termio/backend.zig:14`):

```zig
pub const Kind = enum { exec };
```

The `exec` backend (`src/termio/Exec.zig`) manages a child process connected via
a PTY (pseudoterminal). When you open a new terminal in Ghostty, the `exec` backend:

1. Creates a PTY (a pair of connected file descriptors pretending to be a serial
   terminal)
2. Forks a child process (your shell — zsh, bash, fish, etc.)
3. Connects the child's stdin/stdout/stderr to the PTY slave end
4. Reads the child's output from the PTY master end
5. Feeds those bytes through the VT parser to update the Terminal state
6. Writes your keystrokes to the PTY master end (which the child reads as input)

The Backend is defined as a tagged union (`src/termio/backend.zig:24`):

```zig
pub const Backend = union(Kind) {
    exec: termio.Exec,
    // ... methods that dispatch to the active variant
};
```

This union pattern means: "a Backend is EITHER an exec OR... well, currently only
exec." But the structure is designed so that adding a new variant (like `.tmux`)
extends it naturally.

---

## Why are Surfaces and Backends separate?

Because the same Surface rendering logic should work regardless of WHERE the terminal
content comes from.

A Surface knows how to:
- Render a grid of characters with colors, styles, and cursor
- Handle keyboard input and mouse events
- Manage scrollback and selection
- Communicate with the renderer thread via shared state

A Backend knows how to:
- Get terminal data from somewhere (today: a subprocess PTY)
- Send user input somewhere (today: to the subprocess via PTY)
- Handle lifecycle events (process exit, resize)

This separation means if you want a Surface whose content comes from a different
source — say, a tmux pane — you don't need to change the rendering code. You
just need a different Backend that provides data from that other source.

---

## Journey: What happens when you type the letter "a"?

This walks through the complete data flow from keypress to pixel, showing how
each Surface component participates. Follow along with the component diagram
from "What does a Surface own?" above.

### Phase 1: OS → Backend (apprt) → Surface.keyCallback()

The macOS Cocoa event system detects the keypress. The Swift host app calls
`ghostty_surface_key()` (`src/apprt/embedded.zig`), which converts the native
key event into a platform-independent `input.KeyEvent` containing:
- the physical key (`.a`)
- the action (`.press`)
- modifier state (none)
- the UTF-8 text output (`"a"`)

This calls `core_surface.keyCallback(event)` (`src/Surface.zig:2625`).

**Backend involvement**: The apprt (embedded backend on macOS) is the bridge
between the OS and the platform-independent Surface. It translates Cocoa events
into Ghostty's input types. On Linux, GTK plays the same role.

### Phase 2: Surface processes the key

Inside `keyCallback()`, several Surface components participate in sequence:

1. **keyboard** — checks for key remappings (user-configured modifier changes)
2. **keyboard** — checks if this key matches a keybinding (leader sequences,
   key tables, default bindings). "a" matches nothing, so processing continues.
3. **mouse** — hides the mouse cursor if `mouse-hide-while-typing` is configured
4. **renderer_state** — the Surface locks the renderer mutex to read the
   Terminal's keyboard encoding mode (which protocol to use: legacy, kitty, etc.)
5. **encodeKey()** (`Surface.zig:3156`) — encodes the letter "a" into the bytes
   the shell expects. For legacy mode, this is just the byte `0x61`. For kitty
   keyboard protocol, it could be a CSI sequence.

### Phase 3: Surface → IO thread (via mailbox)

The encoded bytes are packaged as a `WriteReq` and sent via:
```
self.queueIo(.write_small, .unlocked)  →  self.io.mailbox.send(msg)
```
(`Surface.zig:2773-2790`)

This is an asynchronous, lock-free SPSC (single-producer single-consumer) message
to the **io_thread**. The Surface does not block.

After queueing, the Surface also (under renderer_state mutex):
- Clears the text selection if `selection-clear-on-typing` is set
- Scrolls to the bottom if `scroll-to-bottom.keystroke` is set
- Calls `queueRender()` to wake the renderer thread

### Phase 4: IO thread → Backend (exec) → PTY → shell

The **io_thread** (`src/termio/Thread.zig:289`) wakes up, drains its mailbox,
and finds the `.write_small` message. It calls:
```
termio.Termio.queueWrite()  →  backend.queueWrite()
```
The **exec Backend** (`src/termio/Exec.zig`) writes the byte `0x61` to the PTY
master file descriptor. The OS delivers it to the PTY slave end, which the shell
(zsh/bash) reads as standard input.

### Phase 5: Shell → PTY → exec read thread → VT parser → Terminal

The shell echoes "a" back (plus potentially prompt updates). The exec Backend's
dedicated **read thread** (`Exec.zig:1257`, `ReadThread.threadMainPosix`) is
sitting in a tight `posix.read()` loop on the PTY master fd. It reads the
shell's output and calls:
```
termio.Termio.processOutput(buf)
```
This feeds the bytes through the **StreamHandler** (`src/termio/stream_handler.zig`),
which runs the VT parser. The parser recognizes "a" as a printable character and
calls `terminal.print('a')` on the **Terminal** (`src/terminal/Terminal.zig`) —
updating the screen buffer: the character is placed at the cursor position, and
the cursor advances one cell to the right.

### Phase 6: Terminal → renderer_state → Renderer → GPU → pixels

After updating the Terminal, the IO thread calls `renderer_wakeup.notify()` — an
async cross-thread signal. The **renderer_thread** (`src/renderer/Thread.zig`)
wakes up and:

1. Locks `renderer_state.mutex`
2. Reads the Terminal's screen buffer (via `renderer_state.terminal`)
3. Rebuilds cell data: which character at each grid position, colors, styles
4. Releases the mutex
5. Syncs GPU buffers (cell data, font atlas textures, uniforms)
6. Encodes Metal render commands (background pass, then text pass using instanced
   drawing)
7. Commits the command buffer to the GPU
8. On completion, presents the IOSurface to the CALayer

The letter "a" appears on screen.

### Summary: the data flow in one line

```
Cocoa event → apprt → Surface.keyCallback → encode → mailbox → IO thread
→ exec Backend → PTY write → shell → PTY read → VT parser → Terminal
→ renderer_wakeup → Renderer thread → Metal GPU → pixels
```

---

## Why is a Renderer needed? How Metal works on macOS

### Why a renderer?

A Terminal stores characters, colors, and cursor state in a logical grid — it's
just data in memory. But the user needs to see pixels on a screen. The Renderer
is the component that converts the Terminal's grid into GPU draw commands that
produce visible output. Without it, the Terminal would be a silent in-memory
data structure.

### How it works (high level)

The Renderer runs on its own dedicated thread. It wakes up when notified (via
`renderer_wakeup`), reads the Terminal state under a mutex, and produces a frame.
It does NOT poll continuously — it only draws when something changes (terminal
content update, cursor blink, window resize).

### How Metal works on macOS

Ghostty uses Apple's Metal API for GPU rendering on macOS. The key pieces:

1. **IOSurfaceLayer** (`src/renderer/metal/IOSurfaceLayer.zig`) — a custom
   `CALayer` subclass that serves as the render target. It has a `display()`
   callback invoked by the OS when a redraw is needed.

2. **Triple buffering** — three `Frame` objects form a swap chain. While the GPU
   processes one frame, the CPU can prepare the next. A semaphore prevents
   overrunning the GPU.

3. **Render pipeline** — each frame encodes multiple render passes in sequence:
   - Background color or image
   - Cell backgrounds (colored rectangles)
   - Cell text (instanced drawing: 4 vertices × N glyph instances)
   - Images (kitty protocol)
   - Optional custom shader post-processing

4. **Font atlas** — glyphs are rasterized on-demand via CoreText and packed into
   GPU textures (grayscale for regular text, color for emoji). The atlas is synced
   to the GPU only when new glyphs are added.

5. **Presentation** — after the GPU finishes, a completion callback sets the
   rendered IOSurface as the CALayer's `contents`, making it visible immediately.

The renderer does not care where Terminal content came from — PTY subprocess or
tmux `%output`. It just reads the grid and draws.

---

## How does Ghostty create a Surface today?

Here is the sequence that happens when you open a new terminal (window, tab, or
split) in Ghostty:

### Step 1: The application runtime decides to create a surface

On macOS, this happens when you press Cmd+N (new window) or Cmd+T (new tab). The
Swift code calls into Ghostty's C API:

```
ghostty_surface_new(app, opts)  →  app.newSurface(opts)
```

(See `src/apprt/embedded.zig:1541-1556`)

The `opts` include the platform handle (an `NSView`), the content scale (2x for
Retina), and the initial size.

### Step 2: Surface.init() runs

`src/Surface.zig:467` — this is a large function (~300 lines). Here is what
happens, step by step:

**2a. Configuration** (`Surface.zig:477-493`)
- Applies conditional state (light/dark mode theme switching)
- Falls back to original config if conditional state fails
- Preserves working directory from original config

**2b. Font initialization** (`Surface.zig:496-526`)
- Creates a `DerivedConfig` from the full config
- Calls `Renderer.surfaceInit(rt_surface)` — main-thread renderer setup
- Reads content scale from the platform surface (e.g. 2x for Retina)
- Calculates DPI: `content_scale × 96` (default_dpi)
- Loads the font grid from the app's shared font grid cache (reuses across
  Surfaces if the same font config)

**2c. Size calculation** (`Surface.zig:529-554`)
- Reads the screen size from the platform surface
- Gets the cell size from the font grid metrics
- Calculates padding (explicit or balanced to center content)
- Builds a `Size` struct combining screen, cell, and padding dimensions

**2d. Renderer setup** (`Surface.zig:558-582`)
- Initializes the Renderer implementation (Metal on macOS) with config, font
  grid, size, and mailbox references
- Creates the `renderer_state` mutex that protects shared Terminal access
- Initializes the Renderer thread object (but does NOT spawn the OS thread yet)

**2e. IO thread setup** (`Surface.zig:585-586`)
- Creates the IO thread object (not spawned yet)

**2f. Exec Backend creation** (`Surface.zig:638-668`)
- Builds the environment map, injects `GHOSTTY_SURFACE_ID`
- Creates the exec Backend:

```zig
var io_exec = try termio.Exec.init(alloc, .{
    .command = command,
    .env = env,
    .shell_integration = config.@"shell-integration",
    // ... more config
});
```

**2g. Termio initialization** (`Surface.zig:675-685`)
- Creates Termio with the exec Backend:

```zig
try termio.Termio.init(&self.io, alloc, .{
    .backend = .{ .exec = io_exec },   // ← hardcoded to exec
    .mailbox = io_mailbox,
    .renderer_state = &self.renderer_state,
    // ... more config
});
```

Inside `Termio.init()` (`src/termio/Termio.zig:222-321`):
1. Creates the **Terminal** emulator (grid, cursor, modes, colors, scrollback)
2. Calls `backend.initTerminal(&term)` — exec registers the terminal
3. Creates the **StreamHandler** (VT sequence parser → Terminal mutations)
4. Wires up mailboxes to renderer and surface threads

**2h. Renderer state wiring** (`Surface.zig:606-609`)

```zig
.renderer_state = .{
    .mutex = mutex,
    .terminal = &self.io.terminal,  // ← renderer reads THIS Terminal
},
```

**2i. Initial actions** (`Surface.zig:692-750`)
- Reports cell size to the apprt (so it can set minimum window size)
- Reports size limits (min window width/height based on cell count config)
- Calls `self.resize()` for Retina-aware setup
- Recomputes initial window size if `window-width`/`window-height` are configured

**2j. Thread spawning** (`Surface.zig:719-735`)
- `Renderer.finalizeSurfaceInit()` — last main-thread renderer setup
- Spawns the **renderer thread** (`rendererpkg.Thread.threadMain`)
- Spawns the **IO thread** (`termio.Thread.threadMain`)

```zig
self.renderer_thr = try std.Thread.spawn(.{}, rendererpkg.Thread.threadMain, ...);
self.io_thr = try std.Thread.spawn(.{}, termio.Thread.threadMain, ...);
```

### Step 3: The IO thread starts, Backend launches the subprocess

When the IO thread starts, it calls `backend.threadEnter()` which in the exec
backend (`src/termio/Exec.zig:85-193`):
1. Opens the PTY (creates master/slave fd pair)
2. Forks the child process (your shell — zsh, bash, fish, etc.)
3. Connects the child's stdin/stdout/stderr to the PTY slave
4. Spawns a dedicated **read thread** (`ReadThread.threadMainPosix`) that sits
   in a tight `posix.read()` loop on the PTY master fd
5. Creates a quit pipe so the read thread can be signaled to stop

### Step 4: Data flows

The read thread reads bytes from the PTY → feeds them to the VT parser → updates
the Terminal state. The renderer thread reads the Terminal state → draws it with
the GPU. The user types → keystrokes go through the mailbox → IO thread writes
them to the PTY → the shell receives them.

---

## How would this work for tmux control mode (the firstmvp)?

The tmux control mode integration needs a Surface whose content comes from the
Viewer's Terminal instance for a tmux pane, NOT from a subprocess PTY. Here is
how the same steps would work with a `.tmux` backend.

### Step 1: Triggered by the Viewer, not the user

Today, when the user runs `tmux -CC` inside Ghostty, the exec Backend's PTY
read thread picks up the DCS sequence (`ESC P 1000 p`) that enters tmux control
mode. Here's what happens (verified from `smallestmvp/tier2_04_08/ghostty.log`):

1. The exec read thread reads bytes from the PTY (`Exec.zig` ReadThread)
2. The VT parser detects the DCS sequence (`Parser.zig` → `dcs.zig`)
3. The StreamHandler creates a Viewer (`stream_handler.zig:399`)
4. The Viewer enters its startup state machine:
   - `startup_block` → receives initial `%begin/%end` block
   - `startup_session` → receives `%session-changed` with session id/name
   - `command_queue` → starts issuing commands
5. The Viewer issues `display-message -p '#{version}'` → gets tmux version
6. The Viewer issues `list-windows -F '#{session_id} #{window_id}...'`
7. tmux responds with window/pane layout data
8. The Viewer creates a Terminal for each pane, issues `capture-pane` commands
9. The Viewer emits a `.windows` action with the complete window list

**Here is where it breaks.** At `stream_handler.zig:468-476`, the `.windows`
action is received with correct data but dropped:

```zig
.windows => |windows| {
    log.info("windows_action window_count={d}", .{windows.len});
    // ^^^ THIS DATA IS CORRECT BUT DROPPED — no apprt integration yet
},
```

**What needs to happen instead**: The stream handler needs to send a message
to the apprt layer (via the surface mailbox) requesting new Surface creation
for each tmux window/pane. Since Surface creation must happen on the main thread
(`Surface.zig:464` says "must be called from the main thread"), the IO thread
cannot create Surfaces directly — it must send a message through the app mailbox.

**File**: `src/termio/stream_handler.zig` — the `.windows` match arm (line 468)
**Change**: Instead of dropping, send a message via `self.surface_mailbox` to
the app, requesting Surface creation with a `.tmux` backend kind for each pane.

### Step 2: Surface.init() — with a tmux Backend instead of exec

The main thread receives the Surface creation request and calls `Surface.init()`,
but instead of creating an exec Backend, it creates a tmux Backend:

Instead of:
```zig
.backend = .{ .exec = io_exec },
```

It would be:
```zig
.backend = .{ .tmux = tmux_backend },
```

where `tmux_backend` holds a reference to the tmux pane ID and a mechanism to
send data to the original Surface's Viewer (for `send-keys`, `resize`, etc.).

**Files and changes needed**:

| File | Change |
|------|--------|
| `src/termio/backend.zig:14` | Add `.tmux` to `Kind = enum { exec, tmux }` |
| `src/termio/backend.zig:24` | Add `tmux: termio.Tmux` variant to the `Backend` union |
| `src/termio/backend.zig:27-112` | Add `.tmux =>` arms to every `switch(self)` (9 methods: `deinit`, `initTerminal`, `threadEnter`, `threadExit`, `focusGained`, `resize`, `queueWrite`, `childExitedAbnormally`, `getProcessInfo`) |
| NEW: `src/termio/Tmux.zig` | The tmux Backend struct with pane_id, Viewer reference, and mostly no-op method implementations |
| `src/Surface.zig:656-685` | Allow creating a Surface with `.tmux` backend (new code path alongside exec) |
| `src/termio/Termio.zig` | Handle `.tmux` in any backend-specific switch sites |
| `src/termio/Thread.zig` | Handle `.tmux` in any backend-specific switch sites |

### Step 3: The IO thread starts — but no subprocess

The tmux Backend's `threadEnter()` does NOT fork a process or create a PTY.
There is no read thread. The Terminal gets its content by a different mechanism.

**How `%output` flows** (this is where live updates come from):

```
tmux server sends %output to PTY
        │
        ▼
Exec read thread (original Surface)        ← ReadThread.threadMainPosix
reads from PTY master fd                      (src/termio/Exec.zig:1257)
        │
        ▼
processOutput() → VT parser → DCS handler ← dcs.zig detects tmux data
        │
        ▼
StreamHandler receives tmux notification   ← stream_handler.zig:393
        │
        ▼
control.zig Parser.put() parses            ← Parses "%output %0 hello\n"
"%output %<pane_id> <data>"                   Returns Notification{.output}
        │
        ▼
Viewer.next() dispatches to                ← viewer.zig:471
receivedOutput(pane_id, data)
        │
        ▼
Viewer looks up pane in self.panes map     ← viewer.zig:1121
Gets the Pane's Terminal reference            (AutoArrayHashMap keyed by pane_id)
        │
        ▼
pane.terminal.vtStream().nextSlice(data)   ← viewer.zig:1134-1136
VT parser updates the Viewer's Terminal       This Terminal is INSIDE the Viewer
```

**The gap for the MVP**: The Viewer's Terminal is updated, but it's a *different*
Terminal than the one the tmux Surface's renderer reads from. The renderer reads
from `self.io.terminal` (the Terminal owned by Termio). So there needs to be a
mechanism to forward the `%output` data from the Viewer's Terminal to the tmux
Surface's Terminal. Two approaches:

- **Copy bytes**: Forward the raw `%output` data to the tmux Surface's Termio
  (e.g., via its mailbox), and let the tmux Surface's own VT parser process it
  into its own Terminal. This is cleaner because each Terminal processes its own
  VT stream.
- **Copy state**: After the Viewer updates its pane Terminal, copy the screen
  state to the tmux Surface's Terminal. This is simpler for the first MVP but
  loses terminal modes and scroll state.

**File**: `src/terminal/tmux/viewer.zig` — `receivedOutput()` (line 1116)
**Change**: After updating the Viewer's pane Terminal, also forward the data
to the corresponding tmux Surface's Termio (via a reference or mailbox stored
in the Pane struct).

### Step 4: Data flows differently

Instead of: PTY read → VT parser → Terminal
It would be: Viewer receives `%output` → forwards decoded bytes → tmux Surface's Terminal

The renderer still works exactly the same way — it reads from
`renderer_state.terminal` which points to `self.io.terminal`, the Terminal
owned by Termio. The renderer does not care where the Terminal's content came
from.

### Sequence diagram: tmux control mode after the integration

```
┌──────────┐  ┌───────────────┐  ┌──────────┐  ┌────────────┐  ┌──────────────┐
│  tmux    │  │ Original      │  │ Stream   │  │  Viewer    │  │ tmux Surface │
│  server  │  │ Surface (exec)│  │ Handler  │  │            │  │ (new)        │
└────┬─────┘  └──────┬────────┘  └────┬─────┘  └─────┬──────┘  └──────┬───────┘
     │               │               │               │               │
     │ ═══ STARTUP (tmux -CC) ═══════════════════════════════════════ │
     │               │               │               │               │
     │  ESC P 1000 p │               │               │               │
     │──────────────►│               │               │               │
     │               │ DCS detected  │               │               │
     │               │──────────────►│               │               │
     │               │               │ create Viewer │               │
     │               │               │──────────────►│               │
     │               │               │               │               │
     │  %session-changed $0 mvp      │               │               │
     │──────────────►│──────────────►│──────────────►│               │
     │               │               │               │               │
     │               │               │  .command:    │               │
     │               │               │  list-windows │               │
     │               │               │◄──────────────│               │
     │  list-windows │               │               │               │
     │◄──────────────│◄──────────────│               │               │
     │               │               │               │               │
     │  %begin / response / %end     │               │               │
     │──────────────►│──────────────►│──────────────►│               │
     │               │               │               │ creates       │
     │               │               │               │ pane Terminals│
     │               │               │  .windows     │               │
     │               │               │◄──────────────│               │
     │               │               │               │               │
     │ ═══ SURFACE CREATION (the MVP change) ════════════════════════ │
     │               │               │               │               │
     │               │               │ send to apprt:│               │
     │               │               │ "create tmux  │               │
     │               │               │  surface for  │               │
     │               │               │  pane %0"     │               │
     │               │               │──────────────────────────────►│
     │               │               │               │  Surface.init │
     │               │               │               │  .backend =   │
     │               │               │               │  .{ .tmux }   │
     │               │               │               │  (no PTY,     │
     │               │               │               │   no fork)    │
     │               │               │               │               │
     │ ═══ STEADY STATE: live output ════════════════════════════════ │
     │               │               │               │               │
     │  %output %0   │               │               │               │
     │  "hello\r\n"  │               │               │               │
     │──────────────►│               │               │               │
     │               │ PTY read      │               │               │
     │               │──────────────►│               │               │
     │               │               │ notification  │               │
     │               │               │──────────────►│               │
     │               │               │               │ receivedOutput│
     │               │               │               │ update Viewer │
     │               │               │               │ Terminal      │
     │               │               │               │               │
     │               │               │               │ forward data  │
     │               │               │               │──────────────►│
     │               │               │               │               │ VT parse
     │               │               │               │               │ update
     │               │               │               │               │ Terminal
     │               │               │               │               │ notify
     │               │               │               │               │ renderer
     │               │               │               │               │ ───► GPU
     │               │               │               │               │      draws
     │               │               │               │               │      "hello"
     │               │               │               │               │
     │ ═══ USER INPUT (future, not first MVP) ══════════════════════ │
     │               │               │               │               │
     │               │               │               │  user types   │
     │               │               │               │  "ls" in tmux │
     │               │               │               │  Surface      │
     │               │               │               │◄──────────────│
     │               │               │               │ tmux Backend  │
     │               │               │  send-keys    │ queueWrite    │
     │               │               │◄──────────────│               │
     │  send-keys    │               │               │               │
     │  -t %0 'ls'   │               │               │               │
     │◄──────────────│◄──────────────│               │               │
     │               │               │               │               │
```

---

## Questions a Junior Engineer Might Ask

### Q1: If a Surface doesn't know if it's a window or tab, who decides?

The application runtime (apprt) layer. On macOS, the Swift code in
`macos/Sources/` creates `NSWindow` for windows and manages tabs. On Linux,
the GTK code in `src/apprt/gtk/` creates `GtkWindow` and manages pane splits.
Both call the same `ghostty_surface_new()` C API to create the underlying
Surface. The Surface just draws; the apprt arranges where it appears.

### Q2: Can two Surfaces share the same Terminal?

No. Each Surface has its own `Termio` (`src/Surface.zig:127`) which owns its
own `Terminal` (`src/termio/Termio.zig:41`). The renderer's pointer to the
Terminal is set once at Surface init (`Surface.zig:608`:
`.terminal = &self.io.terminal`) and never changes. Two Surfaces cannot point
their renderers at the same Terminal.

This is why the tmux integration must COPY content from the Viewer's Terminal
into the Surface's own Terminal, rather than sharing by reference.

### Q3: What happens when I resize a Ghostty window?

The apprt layer detects the resize → sends a resize message to the Surface →
Surface calls `backend.resize()` → the exec Backend calls `ioctl(TIOCSWINSZ)`
on the PTY to notify the child process → the child process receives `SIGWINCH`
and adjusts its output.

For a tmux backend, `resize()` would instead send `refresh-client -C WxH` to
tmux, telling it to recalculate pane layouts.

### Q4: What are the 9 Backend methods and which ones matter for tmux?

From `src/termio/backend.zig:27-112`:

| Method | What it does (exec) | What it would do (tmux) |
|--------|-------------------|----------------------|
| `deinit` | Cleans up PTY and subprocess | Cleans up tmux pane reference |
| `initTerminal` | Configures Terminal for subprocess | No-op (Termio creates Terminal) |
| `threadEnter` | Starts subprocess, spawns read thread | No-op (no subprocess) |
| `threadExit` | Stops read thread, kills subprocess | No-op |
| `focusGained` | Sends focus event to child via escape sequence | Could send focus to tmux pane |
| `resize` | Resizes PTY via ioctl | Would send `refresh-client -C` |
| `queueWrite` | Writes keystrokes to PTY | Would send `send-keys` to tmux |
| `childExitedAbnormally` | Shows error message in terminal | No-op (no child process) |
| `getProcessInfo` | Returns PID, command name | Returns null (no process) |

For the first MVP (read-only, no resize, no input), most methods are no-ops.

### Q5: How does the renderer know when to redraw?

The IO thread updates the Terminal state (under the `renderer_state.mutex`),
then wakes the renderer via `renderer_wakeup.notify()` — an async cross-thread
notification. The renderer thread wakes up, acquires the mutex, reads the
Terminal's screen buffer, builds GPU draw commands, releases the mutex, and
submits the frame to the GPU.

The renderer does not care HOW the Terminal was updated. Whether bytes came from
a PTY subprocess or from a tmux `%output` notification, the renderer just reads
whatever is in the Terminal's screen buffer.

### Q6: What is the Termio and how does it relate to the Backend?

Termio (`src/termio/Termio.zig`) is the coordinator between the Backend and the
rest of the system. It owns three critical things:

1. The `terminal: Terminal` — the actual terminal emulator state
2. The `backend: Backend` — what provides data (exec or, eventually, tmux)
3. The `StreamHandler` — what processes parsed VT sequences into Terminal mutations

Termio does not care which Backend kind is active. It calls `backend.threadEnter()`,
`backend.queueWrite()`, etc. through the tagged union dispatch. The Backend
implementation handles the specifics.

### Q7: If I add a `.tmux` variant to the Backend union, what breaks?

Zig's tagged union `switch` statements are exhaustive. Adding `.tmux` to the
`Kind` enum causes a compile error at EVERY `switch` site that doesn't handle
it. This is a safety feature — the compiler tells you exactly which code paths
need updating. There are approximately 10 switch sites across `backend.zig`,
`Termio.zig`, and `Thread.zig`.

### Q8: How does the macOS Swift app create a new tab?

The Swift code receives a "new tab" action → creates an `NSWindow` or tab →
calls `ghostty_surface_new()` (the C API in `src/apprt/embedded.zig:1541`) →
this calls `app.newSurface()` → which allocates a Surface, calls `Surface.init()`,
and returns a pointer. The Surface does its full initialization (fonts, renderer,
exec Backend, threads) and starts running.

For tmux integration, the same flow would happen, but triggered by the Viewer's
`.windows` action instead of a user keyboard shortcut. The Backend would be
`.tmux` instead of `.exec`.

### Q9: What thread is Surface.init() called on?

The main thread (the UI/app thread). The doc comment says (`Surface.zig:464`):
"Create a new surface. This must be called from the main thread." After init
completes, the Surface spawns its own renderer and IO threads. So init is
synchronous on the main thread, but the Surface's ongoing work happens on
dedicated threads.

This matters for the tmux integration because the `.windows` action is received
on the IO/read thread (not the main thread). Creating a Surface from there would
require sending a message to the main thread first — likely via the app mailbox.

### Q10: Where is the Terminal actually created?

Inside `Termio.init()` at `src/termio/Termio.zig:240-260`. The Terminal is
created with the configured number of rows and columns, default modes, and
color palette. The Backend then gets a reference to it via `initTerminal()`
at `Termio.zig:282`.

The renderer gets its pointer via `renderer_state.terminal = &self.io.terminal`
at `Surface.zig:608`. Both point to the same Terminal instance — the one owned
by Termio.

### Q11: What happens when a Surface is destroyed?

`Surface.deinit()` (`Surface.zig:770-810`):
1. Signals the IO thread to stop
2. Signals the renderer thread to stop
3. Joins both threads (waits for them to finish)
4. Destroys the renderer, Termio (which destroys the Backend and Terminal),
   and all other state

For a tmux Backend, the deinit would need to notify the Viewer that this pane's
Surface is going away (so the Viewer can stop routing `%output` to it).

### Q12: Can a Surface exist without a Backend?

No. `Termio.init()` requires a `backend` parameter (`Termio.zig:281`):
`var backend = opts.backend;`. The Backend is then called immediately with
`backend.initTerminal(&term)`. A Surface always has a Termio, and a Termio
always has a Backend.

However, a Backend CAN be mostly empty — a struct with no-op methods. The
first MVP's tmux Backend would be exactly this: a struct that holds a pane ID
and does almost nothing. The Terminal still gets created normally by Termio;
the Backend just doesn't actively fill it with data (for the first MVP, the
content is copied in separately after initialization).
