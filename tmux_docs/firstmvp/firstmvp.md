# First MVP: The Smallest Meaningful Step Toward tmux Control Mode Integration

---

## 1. Problem Statement

### Key concepts

**Surface** (`src/Surface.zig`): A Surface is Ghostty's fundamental display unit.
It is a rectangular widget where terminal content is drawn and where keyboard/mouse
events are received. A Surface does not decide whether it appears as a window, tab,
or split — that is decided by the application runtime (apprt) layer above it. A
Surface just draws and responds to events. Every visible terminal in Ghostty is a
Surface.

**PTY and subprocess**: When you open a terminal, the terminal emulator needs to
run a program (usually a shell like zsh or bash) and display its output. It does
this by creating a pseudoterminal (PTY) — an OS facility that creates two connected
file descriptors pretending to be a serial terminal. The terminal emulator holds one
end (the "master"); the shell holds the other (the "slave"). The shell writes output
to its end, and the terminal emulator reads it from the master end and renders it.
The shell process is the "subprocess" — a child process that Ghostty forks and execs.

**How Ghostty ties these together today**: Every Surface owns a Backend
(`src/termio/backend.zig`). Today, the only Backend kind is `exec` — which manages
a subprocess connected via a PTY. The Backend reads bytes from the child process
and hands them to `Termio.processOutput()`, which feeds them through the
StreamHandler's VT parser, which updates the Terminal state that the renderer
draws. (The Backend itself does NOT run the VT parser — the StreamHandler does,
owned by Termio.) The coupling is hardcoded: `Surface.zig:679` sets
`.backend = .{ .exec = io_exec }`. There is no other option.

**Viewer's Terminal instances**: When tmux runs in control mode (`tmux -CC`),
Ghostty's Viewer (`src/terminal/tmux/viewer.zig`) creates a real `Terminal`
object for each tmux pane. A `Terminal` (`src/terminal/Terminal.zig`) is Ghostty's
complete terminal emulator state: screen buffers (primary and alternate), cursor
position, color attributes, mode flags, scroll region, tab stops, and a VT parser.
The Viewer populates each pane's Terminal by issuing `capture-pane` commands to tmux
and feeding the captured content through the Terminal's VT parser. It also routes
live `%output` from tmux into the correct pane's Terminal. These Terminal instances
hold real, renderable content — the same data structure that Ghostty's renderer
normally reads from to draw pixels.

**How the renderer connects to the Terminal**: Each Surface's renderer reads from
`renderer_state.terminal`, which is a pointer to `self.io.terminal`
(`Surface.zig:608`) — the Terminal owned by the Surface's Termio instance
(`Termio.zig:41`). This pointer is set once at Surface creation and never
changes. During `Termio.init`, the Backend's `initTerminal` method is called
with a reference to this Terminal (`Termio.zig:282`). This means each Surface
has exactly one Terminal, owned by its Termio, pointed to by its renderer.
A tmux Surface needs its own Termio with its own Terminal — you cannot point
the renderer at an external Terminal (like the Viewer's).

### What works

The entire tmux control mode pipeline is functional and tested (106 tests, empirically
verified in Tier 1 and Tier 2 experiments): DCS detection, protocol parsing, Viewer
state machine, command-response dance with tmux, Terminal creation and population,
live `%output` routing.

### What is broken

At `src/termio/stream_handler.zig:468-476`, the Viewer emits a `.windows` action
containing correct window/pane data. The stream handler drops it:

```zig
.windows => |windows| {
    // logs the data, but does nothing with it
},
```

No Surface is created for the tmux pane. The Viewer's Terminal instances hold
renderable content, but nothing reads them. The feature is invisible to users.

**Root cause**: `src/termio/backend.zig` defines `Kind = enum { exec }`. There is
only one kind of Backend, and it requires a subprocess PTY. A tmux pane has no
subprocess — its content comes from the Viewer's Terminal instance, not from a
PTY read loop. There is no mechanism to create a Surface backed by anything other
than a subprocess.

### Why this problem first

The parser, Viewer, and command queue are done (106 tests, 4 files). They are not
the bottleneck. The bottleneck is this single coupling: Surface → exec Backend.
Until that is loosened, no amount of parser or Viewer work produces visible output.

---

## 2. Why This Task First

**What it proves**: That Ghostty can create a Surface whose content comes from a
tmux pane's Terminal instance rather than from a subprocess PTY read loop. This is
the core architectural assumption of the entire tmux integration. If it's wrong,
the approach must change.

**What it unblocks**: Everything downstream:
- Input routing (`send-keys` to tmux) — needs a Surface to receive keystrokes
- Resize propagation (`refresh-client -C`) — needs a Surface to resize
- Multi-pane rendering — needs one Surface per pane
- Session persistence — needs Surfaces that can be recreated on reattach

**Why not alternatives**:
- More parser work — parser already handles all needed notifications
- Flow control — irrelevant until something renders
- Input routing — can't route keystrokes to a Surface that doesn't exist

The maintainer's own checklist confirms this. Mitchell identified the blocker:
"the ability to create new apprt things (windows/splits/tabs) that aren't attached
to a normal exec-based termio — which is pretty fundamentally hard."

### Success criteria

Running `tmux -CC new-session` in Ghostty causes a second Surface to appear
showing pane %0's captured content (shell prompt, any existing text). The Surface
is read-only (no typing) and shows a static snapshot (no live updates). The content
is rendered by Ghostty's native renderer — same font, same colors, same GPU
pipeline as normal terminals. This proves the architecture works.

---

## 3. Assumptions

**A1: Adding a new Backend Kind is the right approach.**
The plan assumes we add a `.tmux` variant to `backend.zig`'s `Kind` enum and
`Backend` union, rather than modifying the exec backend or using an entirely
different mechanism.

**A2: One Surface per tmux pane is the correct model.**
The plan assumes each tmux pane gets its own Ghostty Surface (the iTerm2 model),
rather than one Surface rendering multiple panes or a custom rendering approach.

**A3: The tmux Surface must have its own Terminal, populated independently.**
The renderer reads from `renderer_state.terminal = &self.io.terminal`
(verified: `Surface.zig:608`). `self.io` is the `Termio` instance, and
`Termio.terminal` is a `Terminal` owned by Termio (`Termio.zig:41`). This
pointer is set once at Surface init and never reassigned. A tmux Surface
therefore cannot share the Viewer's Terminal by reference — the renderer
would not know how to read from it. The tmux Surface must have its own
Terminal inside its own Termio, populated by feeding VT bytes (from the
Viewer's `capture-pane` response) through `Termio.processOutput()` — the
same pipeline the exec Backend uses for PTY data.

**A4: The parent surface (where `tmux -CC` runs) can remain visible during
tmux control mode.**
The plan assumes we don't need to hide or transform the parent surface. The first
MVP just adds a second Surface alongside it.

**A5: The Viewer's state machine is correct enough for a first MVP.**
The plan assumes the Viewer's startup handshake, command queue, and `%output` routing
work correctly. This is strongly supported by the Tier 1/Tier 2 experiments (25+
messages traced, all hypotheses passed) and by the Viewer's 8 integration tests.

**A6: A read-only Surface (no input routing) is a meaningful first step.**
The plan assumes that seeing tmux pane content rendered in a native Ghostty surface,
without being able to type into it, validates enough of the architecture to proceed.

---

## 4. Assumption Stress-Test

### A1: Adding a new Backend Kind

**Challenge 1:** "Backend has 9 methods (deinit, initTerminal, threadEnter,
threadExit, focusGained, resize, queueWrite, childExitedAbnormally, getProcessInfo).
A tmux backend needs to implement ALL of them. Some make no sense for tmux — what
does `childExitedAbnormally` mean for a tmux pane? This will be a mass of no-op
stubs."

Response: True, some methods will be no-ops (`childExitedAbnormally`,
`getProcessInfo`). But Zig's tagged union `switch` enforces exhaustive handling —
adding a new variant causes compile errors at every switch site, which is actually
a safety feature. The no-ops are explicit and documented. The alternative (modifying
exec backend to conditionally behave differently) would be worse — it mixes two
concerns into one type. **Assumption holds.**

**Challenge 2:** "The Backend union also has Config and ThreadData variants. A tmux
backend needs its own Config (what? the pane ID?) and ThreadData (what thread state?).
You're creating three new type variants, not one."

Response: Correct. `Config` needs at minimum a reference to the Viewer and a pane ID.
`ThreadData` may be minimal or empty for the first MVP (no thread-local state needed
if the Viewer handles everything). This is additional work but each variant is small
and follows the existing pattern. **Assumption holds, with noted complexity.**

**Challenge 3:** "Mitchell said the approach is 'pretty fundamentally hard.' Maybe
a new Backend kind is the WRONG abstraction and he envisions something different
entirely."

Response: This is the most serious challenge. The maintainer may want a different
architecture — for example, having the Viewer feed data directly to existing surfaces
through a shared Terminal reference, bypassing the Backend abstraction entirely. The
only way to resolve this is to ask. **Assumption holds conditionally — requires
maintainer confirmation before implementation.**

### A2: One Surface per tmux pane

**Challenge 1:** "Creating N Surfaces for N tmux panes means N renderer threads,
N IO threads, N font caches. For a session with 10 panes, that's 30+ threads.
Is that acceptable?"

Response: Font caches are shared across surfaces (the app's `font_grid_set` uses
ref-counting — `Surface.zig:523`, `Surface.zig:836`). However, **renderer threads
are NOT shared** — each Surface spawns its own renderer thread at `Surface.zig:722`.
So 10 tmux panes = 10 renderer threads + 10 IO threads = 20 extra threads. A tmux
backend's IO thread might be trivial (no subprocess to manage), and the renderer
thread sleeps when idle (wakeup-based, not polling), so actual CPU overhead may be
small. But this needs profiling, not just assumption. **Assumption holds for the
first MVP (1 pane), but may need revision for multi-pane performance.**

**Challenge 2:** "iTerm2's model works because iTerm2 was designed for it from the
start. Ghostty's Surface assumes a 1:1 relationship with a terminal session.
Sharing a Viewer across multiple Surfaces introduces shared mutable state."

Response: The Viewer already holds a `PanesMap` (hash map of pane ID → Terminal).
Each tmux Surface would have its own Terminal (owned by its Termio), populated by
forwarded bytes from the Viewer. **Important**: each Surface has its **own**
`renderer_state.mutex` — the original Surface's mutex and the tmux Surface's mutex
are independent. The Viewer runs on the original Surface's IO thread under the
original Surface's mutex. Forwarding data to the tmux Surface must go through the
tmux Surface's IO thread mailbox (lock-free, async) to avoid nested mutex
acquisition. This follows the same concurrency pattern Ghostty uses for all
cross-thread communication. **Assumption holds — the concurrency model is already
in place, but requires mailbox-based forwarding, not shared mutex access.**

**Challenge 3:** "What if the maintainer prefers a single Surface with a custom
renderer that draws all tmux panes as regions within one window?"

Response: This would be architecturally simpler but would sacrifice native tab/split
integration — the whole point of control mode. The overview documents and issue #1935
explicitly call for native tabs and splits. Still, the maintainer might want a
phased approach starting with single-surface. **Assumption holds for the intended
feature, but the first MVP targets only one pane anyway.**

### A3: Terminal content must be populated independently, not shared

**Challenge 1:** "Why can't the Surface just point to the Viewer's Terminal
directly?"

Response: Impossible. The renderer reads from `&self.io.terminal`
(`Surface.zig:608`) — a pointer to the Terminal that Termio owns
(`Termio.zig:41`). This pointer is set once during Surface init and never
reassigned (verified: no reassignment of `renderer_state.terminal` exists
anywhere in `Surface.zig`). A Surface's renderer has no mechanism to read from
an external Terminal. **Sharing by reference is architecturally impossible
without modifying the renderer.**

**Challenge 2:** "What's the right population strategy — copy Terminal state,
or feed VT bytes?"

There are two approaches:

- **Copy Terminal state**: Serialize the Viewer's pane Terminal (screen buffers,
  cursor, modes) into the Surface's Terminal. This requires understanding every
  field that affects rendering and copying them correctly — fragile and error-prone.

- **Feed VT bytes** (preferred): The Viewer's `capture-pane -p -e` output is
  already VT-encoded text (with ANSI escape sequences for colors/styles). Feed
  those raw bytes into the tmux Surface's Terminal via `Termio.processOutput()`
  — the same path the exec Backend uses. The Surface's own StreamHandler/VT
  parser builds the Terminal state from scratch. This is simpler, consistent
  with how Ghostty already works, and naturally extends to live `%output`
  forwarding later.

For the first MVP, use the VT byte approach: after the Viewer's `capture-pane`
response arrives, forward the captured bytes to the tmux Surface's Termio. The
Terminal is populated the same way an exec Backend would populate it — just with
bytes from tmux instead of from a PTY. **Assumption is refined: not "copy" but
"feed bytes." The architectural constraint (each Surface has its own Terminal)
still holds.**

**Challenge 3:** "The Viewer destroys Terminals on layout changes. If the
Surface has its own Terminal, what triggers an update?"

Response: For the first MVP — nothing. The Surface shows a static snapshot.
This is deliberate scope limitation. After this MVP, the live-output task
forwards decoded `%output` bytes to the Surface's Termio, which feeds them
through the VT parser into the Surface's own Terminal. The Viewer can destroy
its internal pane Terminal without affecting the Surface's independent Terminal.
**Assumption holds. Staleness is acceptable for the proof-of-concept scope.**

### A4-A6: Remaining assumptions

These are lower-risk and hold under scrutiny:
- **A4** (parent surface stays visible): Trivially true for a first MVP.
- **A5** (Viewer is correct): Empirically confirmed by 14/14 verification checks.
- **A6** (read-only is meaningful): It proves the hardest part (Surface creation
  from non-exec source). Input routing is plumbing, not architecture.

---

## 5. Sub-tasks and PR Breakdown

The first MVP target: when a user runs `tmux -CC new-session` in Ghostty, a second
Surface appears showing the content of pane %0 — a static snapshot captured during
the Viewer's initialization. The surface is read-only (no input) and does not update
with live `%output`. This proves that a non-exec Surface can exist and render tmux
pane content.

### Sub-task 1: Add `.tmux` variant to Backend Kind enum

**What:** Add `tmux` to the `Kind` enum, `Config` union, `Backend` union, and
`ThreadData` union in `backend.zig`. All new methods are stubs that do nothing
(or return null/empty). This causes compile errors at every `switch` on these types,
which Sub-task 2 will fix.

**Files:** `src/termio/backend.zig`

**Line estimate:** ~25 lines (new enum value + 4 union variants with stub methods)

**Success criterion:** `zig build` produces compile errors ONLY at `switch` sites
that don't handle the new `.tmux` variant. No errors in `backend.zig` itself.

**Key invariant — union tag symmetry:** All four types (`Kind`, `Backend`,
`Config`, `ThreadData`) are tagged with `Kind`. Zig enforces that each union
has exactly the fields that `Kind` has — if you add `.tmux` to `Kind` but
forget to add it to `Config`, the compiler rejects the `union(Kind)` definition.
However, add a comptime assertion at the top of `backend.zig` to make this
guarantee explicit and catch any future drift if someone adds a fifth type
that uses `Kind`:

```zig
comptime {
    // All backend-related unions must have the same number of variants as Kind.
    // If you add a new Kind, you must add a corresponding variant to each union.
    const kind_fields = @typeInfo(Kind).@"enum".fields.len;
    assert(kind_fields == @typeInfo(@typeInfo(Backend).@"union".tag_type.?).@"enum".fields.len);
    assert(kind_fields == @typeInfo(@typeInfo(Config).@"union".tag_type.?).@"enum".fields.len);
    assert(kind_fields == @typeInfo(@typeInfo(ThreadData).@"union".tag_type.?).@"enum".fields.len);
}
```

**Why this matters:** This is the foundational type-level invariant for the
entire backend system. If `Kind` has a variant that any union lacks, the system
is internally inconsistent — methods will dispatch to a variant that has no
data. Zig's `union(Kind)` already enforces this, but the explicit comptime
block documents the contract and serves as a tripwire if the pattern is ever
extended (e.g., a `BackendState` union added later).

**Dependencies:** None.

### Sub-task 2: Fix all switch sites to handle `.tmux`

**What:** At every `switch` on `Kind`, `Backend`, `Config`, or `ThreadData`, add
a `.tmux` arm. For the first MVP, most arms are `{}` (no-op) or `return null`.
The key one is `Backend.queueWrite` which should be a no-op (read-only Surface).

**Important architecture note:** `Termio.zig` and `Thread.zig` do NOT switch on
backend type directly — they call `self.backend.method()` which dispatches through
the tagged union methods defined in `backend.zig`. All 9 switch sites are inside
`backend.zig`'s method implementations (lines 27-112). There may be additional
switch sites on `Kind`, `Config`, or `ThreadData` in `backend.zig` as well.

**Files:** `src/termio/backend.zig` (all switch sites are here)

**Line estimate:** ~15 lines (one `.tmux =>` arm per switch, ~12-15 sites total
across Backend methods + Kind/Config/ThreadData switches)

**Success criterion:** `zig build` compiles cleanly with no errors. All existing
tests pass. The new `.tmux` backend can be instantiated but isn't used by anything
yet.

**Key invariant — no `else` in backend switches:** Every `switch` on
`Backend`, `Config`, or `ThreadData` must use explicit arms (`.exec =>`,
`.tmux =>`), never `else =>`. Zig's exhaustive switch already enforces this
for tagged unions, but the invariant to defend is deeper: **no tmux arm may
contain `unreachable`**. An `unreachable` compiles but panics at runtime,
silently deferring the bug to production. Every `.tmux` arm must have a
real implementation (even if that implementation is `{}` or `return null`).

Add this as a doc comment above the Backend union:

```zig
/// INVARIANT: Every method's switch must handle all Kind variants with an
/// explicit implementation. No arm may use `unreachable` — if a method does
/// not apply to a backend kind, it must be an explicit no-op (`{}`) or
/// return a safe default (`null`, empty slice, etc.). This ensures that
/// calling any Backend method on any Kind is always safe at runtime.
```

**Why this matters:** The whole point of the Backend abstraction is that
calling code (Termio, Thread) does not know which backend is active — it
calls `backend.resize()` unconditionally. If any arm is `unreachable`, the
abstraction leaks: calling code would need to check the backend kind before
calling the method, defeating the purpose of the union dispatch. This
invariant guarantees that the Backend is a safe, total interface.

**Dependencies:** Sub-task 1.

### Sub-task 3: Create a tmux Backend stub implementation

**What:** Create `src/termio/Tmux.zig` (analogous to `Exec.zig`) with the
minimum implementation: a struct that holds a pane ID, plus stub implementations
of all 9 Backend interface methods. Key design points:
- `threadEnter`: Does NOT spawn a PTY read thread (unlike `Exec.threadEnter`
  which spawns `ReadThread` at `Exec.zig:139-143`). A tmux Surface has no
  subprocess, so it needs only 2 extra threads (renderer + IO), not 3.
- `initTerminal`: No-op (the Termio creates and owns the Terminal; the tmux
  Backend does not manage it like Exec does).
- `queueWrite`: No-op for the first MVP (read-only Surface).
- `resize`: No-op (no resize propagation yet).
- `childExitedAbnormally`, `getProcessInfo`: No-op / return null (no child process).

**Files:** `src/termio/Tmux.zig` (new file), `src/termio/backend.zig` (update
union to reference it)

**Line estimate:** ~30 lines (struct definition + stub methods)

**Success criterion:** `Tmux.zig` compiles. The `Backend` union's `.tmux` variant
now holds a `termio.Tmux` instance instead of void stubs.

**Key invariant — no PTY, no child process, no read thread:** The Tmux backend
must never hold a file descriptor, a process handle, or spawn a read thread.
This is the defining structural difference from Exec. The Exec backend asserts
its identity with `assert(td.backend == .exec)` at the top of `threadExit`,
`focusGained`, and `processExitCommon` (`Exec.zig:196,237,270`). The Tmux
backend should mirror this pattern:

```zig
// In every Tmux method that receives ThreadData:
pub fn threadEnter(self: *Tmux, alloc: Allocator, io: *termio.Termio, td: *termio.Termio.ThreadData) !void {
    assert(td.backend == .tmux);
    // No PTY, no subprocess, no read thread — intentional no-op.
    _ = self;
    _ = alloc;
    _ = io;
}
```

And as a struct-level compile-time assertion:

```zig
comptime {
    // Tmux backend must not hold any OS resource handles.
    // If you find yourself adding a fd or process field, you're
    // likely mixing exec concerns into the tmux backend.
    assert(!@hasField(Tmux, "pty"));
    assert(!@hasField(Tmux, "subprocess"));
    assert(!@hasField(Tmux, "process"));
}
```

**Why this matters:** The exec Backend's entire complexity comes from managing
a PTY and child process lifecycle (fork, read thread, signal handling, exit
detection). If any of that creeps into Tmux.zig, the abstraction is wrong —
it means the tmux backend is being forced into the exec model instead of
being its own thing. This invariant prevents structural contamination and
ensures the tmux backend stays minimal. The `assert(td.backend == .tmux)`
guards also catch any accidental dispatch where Exec code runs with tmux
thread data or vice versa.

**Dependencies:** Sub-task 2.

### Sub-task 4: Wire the `.windows` action to create a Surface

**This is the hardest sub-task.** It requires a cross-thread message path that
does not exist today. This is likely what the maintainer meant by "pretty
fundamentally hard."

**The threading problem:** The `.windows` action arrives on the IO thread (inside
`stream_handler.zig`, called from the exec Backend's read thread via
`processOutput`). But `Surface.init()` must be called from the main thread
(`Surface.zig:464`: "This must be called from the main thread") because renderer
initialization requires main-thread access.

**No existing mechanism bridges this gap.** The `surface_mailbox`
(`src/apprt/surface.zig:135-155`) can send ~20 message types (set_title, close,
child_exited, etc.) but **none create a new Surface**. The apprt `performAction`
system has `new_window`/`new_tab`/`new_split` actions, but these are dispatched
synchronously on the main thread and always create exec-backed Surfaces.

**What must happen:**

1. **IO thread → main thread signaling**: The `.windows` handler in
   `stream_handler.zig` must send a message that reaches the main thread. Two
   candidate mechanisms:
   - Add a new `apprt.surface.Message` variant (e.g., `.tmux_surface_request`)
     to the surface mailbox. The app processes this on the main thread.
   - Use `performAction` with an existing action type (e.g., `.new_window`) but
     with metadata indicating it should use a tmux backend. This piggybacks on
     existing infrastructure.

2. **Main thread creates the Surface**: The main thread receives the request and
   calls `Surface.init()` with a `.tmux` backend instead of `.exec`.

3. **Surface.init accepts non-exec backends**: Today, `Surface.zig:656-685`
   hardcodes exec Backend creation. This code path needs a branch: if the
   creation request specifies a tmux backend, skip the exec setup (no command,
   no env, no PTY) and create a `termio.Backend{ .tmux = tmux_backend }`.

4. **On macOS (embedded apprt)**: The `performAction` callback crosses the C ABI
   to Swift (`embedded.zig:266-286` → `opts.action`). If using a new action type,
   the Swift side must handle it (create an NSWindow/tab). If reusing
   `new_window`, the Swift side already handles window creation — but the backend
   selection must happen in the Zig layer before Swift creates the view.

**Files:**
- `src/termio/stream_handler.zig` — send the creation request (~10 lines)
- `src/apprt/surface.zig` or `src/apprt/action.zig` — new message/action type
  (~15 lines)
- `src/apprt/embedded.zig` — handle the new action (~20 lines)
- `src/Surface.zig` — new init path for tmux backends (~30 lines)
- `macos/Sources/` — handle the action on Swift side, if a new action type is
  used (~20-40 lines)

**Line estimate:** ~95-115 lines across 5+ files

**Open question for maintainer (see Q3):** Which mechanism is preferred? A new
message type? Reusing `new_window` with metadata? Or something else entirely?
The answer significantly affects the implementation.

**Success criterion:** When running `tmux -CC`, a second Ghostty Surface window
appears. It may be blank (Terminal not yet populated) but it EXISTS. The creation
itself is the proof.

**Key invariant — Surface.init() runs on the main thread only:** This is the
most critical threading invariant in the entire MVP. `Surface.zig:464` states
"This must be called from the main thread." Violating this causes undefined
behavior in the renderer (Metal/OpenGL contexts are thread-bound) and in the
apprt layer (NSView must be created on the main thread on macOS).

The `.windows` action arrives on the IO thread. The engineer must **never**
call `Surface.init()` from the `.windows` handler directly. Instead, the
handler sends a message to the main thread, and the main thread creates the
Surface.

Add an assertion at the point where the main thread receives the creation
request and calls Surface.init():

```zig
// At the call site where the tmux Surface is created (main thread handler):
if (comptime builtin.os.tag == .macos) {
    // On macOS, assert we're on the main thread.
    // objc.NSThread.isMainThread() or equivalent.
    assert(objc.msgSend(objc.getClass("NSThread"), "isMainThread", bool));
}
```

And a negative assertion in the IO thread path to prevent future mistakes:

```zig
// In stream_handler.zig, at the .windows handler:
// INVARIANT: Do NOT create a Surface here. This runs on the IO thread.
// Surface.init() must be called from the main thread. Send a message instead.
```

**Why this matters:** This invariant is the reason Sub-task 4 is the hardest
task. If you could call Surface.init() from any thread, the task would be
trivial — just create the Surface in the `.windows` handler. The threading
constraint is what forces the cross-thread messaging path. Violating it
produces crashes that are non-deterministic and hard to reproduce (GPU context
corruption, Cocoa main-thread assertion failures), making the bug extremely
costly to diagnose. The assertion makes the failure immediate and obvious.

**Dependencies:** Sub-task 3.

### Sub-task 5: Populate the tmux Surface with captured pane content

**What:** After the Viewer completes its `capture-pane -p -e` sequence for pane
%0, forward the captured VT bytes to the tmux Surface's Terminal. The Viewer's
`capture-pane` response is already VT-encoded text (with ANSI escape sequences
for colors, styles, cursor position). Rather than copying Terminal state fields,
feed these bytes into the tmux Surface's `Termio.processOutput()` — the same
path the exec Backend uses. The Surface's own StreamHandler/VT parser builds the
Terminal state from scratch, exactly as it would from PTY output.

This approach is preferred over copying Terminal state because:
- It's simpler (no need to enumerate and copy every Terminal field)
- It's consistent with how Ghostty already works (bytes → VT parser → Terminal)
- It naturally extends to live `%output` forwarding later (same mechanism)

**Files:** `src/terminal/tmux/viewer.zig` (forward capture-pane bytes to the
tmux Surface's Termio), `src/termio/Tmux.zig` (expose a method or mailbox to
receive forwarded bytes)

**Line estimate:** ~20 lines

**Success criterion:** The tmux Surface shows the pane's content (shell prompt,
any existing output). This is a static snapshot — it does not update with new
`%output`. But the content is correct and rendered with Ghostty's native renderer.

**Key invariant — a Terminal is only mutated through its owning Termio's
processOutput path, under its own renderer_state mutex:** Each Surface has
its own `renderer_state.mutex` (created at `Surface.zig:569-571`). The
renderer thread reads the Terminal under this mutex. The IO thread writes to
the Terminal under this same mutex (inside `processOutput`). If you write to
a Terminal without holding its mutex, the renderer may read a half-updated
screen buffer — torn frames, corrupted cursor position, or crashes in the
page allocator.

When forwarding `capture-pane` bytes to the tmux Surface's Terminal, the
bytes must flow through the tmux Surface's own IO thread mailbox → its
`Termio.processOutput()` → its StreamHandler → its Terminal. Never write
directly to the Terminal from the original Surface's IO thread:

```zig
// WRONG — violates mutex invariant:
// The original Surface's IO thread writes directly to the tmux Surface's Terminal
tmux_surface.io.terminal.print('a');  // No mutex held! Data race!

// RIGHT — uses the mailbox, respects thread boundaries:
// The original Surface's IO thread sends bytes to the tmux Surface's IO thread
tmux_surface_io_mailbox.send(.{ .process_output = captured_bytes });
// The tmux Surface's IO thread processes them under its own mutex
```

As a defensive measure, add a comment at the forwarding call site:

```zig
// INVARIANT: These bytes are sent via the tmux Surface's IO mailbox.
// They will be processed by the tmux Surface's IO thread under its
// own renderer_state.mutex. Do NOT call processOutput() directly —
// we are on the original Surface's IO thread and do not hold the
// tmux Surface's mutex.
```

**Why this matters:** This invariant protects the renderer's view of the
Terminal from data races. It's the same invariant that the exec Backend
already respects — the read thread calls `processOutput()` which acquires
the mutex. The tmux data path must respect the same contract. Violating it
doesn't just cause visual glitches — it can corrupt the Terminal's internal
PageList allocator, causing use-after-free crashes that appear unrelated to
tmux. The invariant ensures the tmux data path is as safe as the exec path.

**Dependencies:** Sub-task 4.

---

## 6. What Comes Next (if this MVP succeeds)

### Next task 1: Live output routing (make the Surface update in real time)

The first MVP shows a static snapshot. The next step makes it live: when tmux
sends `%output %0 <data>`, the decoded bytes should reach the tmux Surface's
Terminal, and the renderer should redraw.

**What to change:**
- `src/terminal/tmux/viewer.zig` (`receivedOutput`, line ~1116): Instead of only
  feeding `%output` into the Viewer's internal Terminal, ALSO forward the decoded
  bytes to the tmux Surface's Terminal via its Termio.
- `src/termio/Tmux.zig`: Add a mechanism to receive forwarded output bytes and
  feed them to the Surface's Terminal via `Termio.processOutput()`, then wake
  the renderer.

**Concurrency warning — two separate mutexes:** The Viewer runs on the
**original** Surface's IO thread (the exec Backend's read thread calls
`processOutput` → StreamHandler → Viewer). It operates under the original
Surface's `renderer_state.mutex`. The tmux Surface has its **own separate**
`renderer_state.mutex` (created during its `Surface.init()`). These are two
independent mutexes protecting two independent Terminals.

To forward `%output` bytes from the Viewer to the tmux Surface's Terminal,
you must NOT acquire the tmux Surface's mutex while holding the original
Surface's mutex (deadlock risk). Instead, send the bytes via the tmux Surface's
IO thread mailbox — this is the same asynchronous, lock-free pattern Ghostty
uses everywhere else. The tmux Surface's IO thread drains its mailbox,
calls `processOutput()` under its own mutex, and wakes its own renderer.

**Estimated scope:** ~30-50 lines across viewer.zig and Tmux.zig.

**Success criterion:** Type in an attached tmux session; see the text appear in
the Ghostty Surface in real time.

### Next task 2: Input routing (make the Surface accept keystrokes)

The Surface is read-only. The next step routes keystrokes from the tmux Surface
back to tmux via `send-keys`.

**What to change:**
- `src/termio/Tmux.zig` (`queueWrite`): Instead of being a no-op, translate the
  incoming bytes into a `send-keys -t %<pane_id> <hex-encoded-bytes>` command
  and queue it for the Viewer to send.
- `src/termio/stream_handler.zig`: The Viewer already supports `.command` actions.
  The tmux Backend just needs to emit these.
- `src/terminal/tmux/viewer.zig`: May need a `user` command variant (which already
  exists at line 813 but is currently a no-op) to accept arbitrary commands from
  backends.

**Estimated scope:** ~40-60 lines across Tmux.zig and stream_handler.zig.

**Success criterion:** Type in the Ghostty tmux Surface; see the keystrokes appear
in the tmux pane (visible in an attached `tmux attach` session).

### After that

- **Resize propagation**: Surface resize → `refresh-client -C WxH` → tmux recalculates layout
- **Multi-pane**: Create N Surfaces from the `.windows` layout tree, arranged as splits
- **Window close**: Handle `%window-close` → destroy the corresponding Surface
- **Flow control**: `refresh-client -f pause-after=N` to prevent disconnect on heavy output
- **Session reattach**: `tmux -CC attach` restores Surfaces from existing session state

Each of these builds on the foundation of "a non-exec Surface exists and can
receive content." That is why this first MVP matters.

---

## 7. Questions for Existing Maintainers

### Blockers (answers could change the approach)

**Q1: Is a new Backend Kind the right approach for tmux-backed Surfaces?**
The plan adds `.tmux` to the `Backend` union. But you might envision a different
mechanism — for example, having the Viewer feed data directly to existing Surfaces
through a shared Terminal reference without a new backend type. If the Backend
abstraction is wrong for this, the entire sub-task breakdown changes.

**Q2: Should the tmux Surface's Terminal be populated by feeding VT bytes or by
copying Terminal state from the Viewer?**
Sharing by reference is impossible (the renderer reads from `&self.io.terminal`,
set once at init, never reassigned). The plan proposes feeding the Viewer's
`capture-pane -p -e` response bytes into the tmux Surface's `Termio.processOutput()`
— the same path exec uses for PTY data. This is simpler than copying Terminal
state (which requires enumerating every field) and naturally extends to live
`%output` forwarding. But if you have a preferred approach (e.g., Terminal
clone, ownership transfer, or reference counting), that changes Sub-tasks 3-5.

**Q3: What cross-thread mechanism should be used to create tmux Surfaces?**
This is the hardest engineering problem in the MVP. The `.windows` action arrives
on the IO thread, but `Surface.init()` must run on the main thread. Today, no
mechanism exists to request Surface creation from the IO thread — the
`surface_mailbox` has ~20 message types but none create Surfaces, and
`performAction` dispatches synchronously on the main thread. Three options:
  - (a) Add a new `apprt.surface.Message` variant (e.g., `.tmux_surface_request`)
    sent via the existing surface mailbox → app mailbox path
  - (b) Reuse `performAction(.new_window)` with metadata indicating a tmux backend
    (piggybacks on existing infrastructure but adds coupling)
  - (c) A different mechanism entirely (e.g., a dedicated tmux surface manager)

On macOS, any new action type requires handling on the Swift side
(`macos/Sources/`) via the C ABI bridge in `embedded.zig`. This affects scope
significantly. Which approach do you prefer?

### Non-blockers (affect details, not direction)

**Q4: Should the parent surface (where `tmux -CC` runs) be hidden or transformed
when tmux control mode activates?**
The first MVP leaves it visible. But if you want it hidden, that's a UI decision
that doesn't affect the backend architecture.

**Q5: Should the first tmux Surface appear as a new window, a new tab, or a new
split?**
The plan doesn't specify. For a first MVP, any of these would work. The choice
affects which apprt action is used in Sub-task 4.

**Q6: Is there a naming preference for the new file — `Tmux.zig`, `TmuxBackend.zig`,
or something else?**
Following the `Exec.zig` convention, `Tmux.zig` seems right. But this is a
style question.

**Q7: Are there any existing plans or design docs for non-exec surfaces that we
should align with?**
The checklist in issue #1935 mentions "Apprt API changes to note
non-subprocess-based surfaces" as an item. If there's a design sketch or discussion
beyond the issue, we should read it before Sub-task 4.
