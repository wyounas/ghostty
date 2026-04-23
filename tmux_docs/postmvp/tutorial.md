# An Oxford-Style Tutorial On Ghostty, tmux, And The First MVP

This tutorial is for a reader who is new to Unix terminals, tmux, Ghostty, and
Zig. The aim is simple:

- explain the data flow plainly
- explain why the MVP code changes have the shape they do
- give you enough understanding to reason about the design with maintainers

The single most useful rule to keep in mind is this:

- `stdin` is where a program reads input from
- `stdout` and `stderr` are where a program writes output to

One more important point:

- Ghostty does **not** normally talk to shells through Ghostty's own Unix
  `stdin` and `stdout`
- Ghostty talks to the shell through a **PTY master file descriptor**
- the shell sees the other side of that PTY as its own `stdin`, `stdout`, and
  `stderr`

That distinction is where many beginners get lost.

## 1. The Problem We Are Solving

Suppose you open Ghostty and run `tmux`.

In ordinary tmux usage, Ghostty does **not** see "two panes" or "three windows".
Ghostty only sees one byte stream coming from the tmux client.

So the old arrangement is better stated like this:

```text
shells in tmux panes
  -> tmux server combines their output into one terminal drawing stream
  -> tmux client writes that stream to the PTY
  -> Ghostty reads that one stream
  -> Ghostty draws pixels on screen
```

The short version:

```text
tmux decides the layout
Ghostty only paints what tmux drew
```

That is why normal tmux inside a terminal looks like a little text user
interface living inside the terminal window.

Ghostty can render it, but Ghostty does not understand it structurally.

Two quick clarifications:

- here `screen` means the actual pixels on your display, not the old `screen`
  program
- the one-line summary `shell output -> tmux -> Ghostty -> screen` is only a
  simplification; the fuller stdin/stdout picture comes next

## 2. What A Terminal Emulator Normally Does

Let us define the three basic pieces first.

### Terminal emulator

A terminal emulator such as Ghostty:

- shows terminal output on screen
- turns keyboard input into bytes
- reads bytes from a PTY
- interprets escape sequences

### Shell

A shell such as `zsh` or `bash`:

- reads commands from `stdin`
- runs programs
- writes output to `stdout` and `stderr`

### PTY

A PTY, or pseudoterminal, is the kernel object that sits between them.

It is best to think of it as a matched pair:

- **PTY master**: Ghostty holds this side
- **PTY slave**: the shell holds this side as its `stdin`, `stdout`, `stderr`

So, in plain terminal use:

```text
keyboard -> Ghostty -> PTY master -> PTY slave -> shell stdin
shell stdout/stderr -> PTY slave -> PTY master -> Ghostty -> screen
```

### Where stdin and stdout point in ordinary terminal use

| Thing | Reads from | Writes to |
|------|------------|-----------|
| Ghostty | PTY master | PTY master |
| Shell | PTY slave as `stdin` | PTY slave as `stdout`/`stderr` |

That table often surprises people, so say it again carefully:

- the shell's `stdin` points at the PTY slave
- the shell's `stdout` and `stderr` point at the PTY slave
- Ghostty reads and writes the **master** side of that same PTY

### What happens if you type `ls` in Ghostty?

The flow is:

```text
1. You type `l`, `s`, then Enter.
2. Ghostty encodes those keystrokes as bytes.
3. Ghostty writes those bytes to the PTY master.
4. The kernel delivers them to the shell's stdin on the PTY slave.
5. The shell reads `ls\n`.
6. The shell runs `ls`.
7. `ls` writes file names to stdout.
8. Those bytes go to the PTY slave.
9. Ghostty reads them from the PTY master.
10. Ghostty parses them and draws the result.
```

A compact sequence diagram:

```text
You        Ghostty        PTY          shell / ls
 |            |            |               |
 | type ls    |            |               |
 |----------> | write      |               |
 |            |----------> | stdin         |
 |            |            |-------------> |
 |            |            |               | run `ls`
 |            |            | stdout        |
 |            | <----------|<------------- |
 | sees text  | render     |               |
```

## 3. What tmux Adds In Normal Use

tmux adds two important things:

1. a **tmux client** attached to your terminal
2. a **tmux server** managing windows, panes, and the real shells

So now there are really **two terminal layers**:

- an **outer PTY** between Ghostty and the tmux client
- one **pane PTY** per shell managed by the tmux server

That is the key idea.

### The normal tmux picture

```text
keyboard -> Ghostty -> outer PTY -> tmux client -> tmux server -> pane PTY -> shell
shell output -> pane PTY -> tmux server -> tmux client -> outer PTY -> Ghostty -> screen
```

### Where stdin and stdout point in normal tmux usage

| Component | Reads from | Writes to |
|----------|------------|-----------|
| Ghostty | outer PTY master | outer PTY master |
| tmux client | outer PTY slave as `stdin` | outer PTY slave as `stdout`/`stderr` |
| tmux server | tmux socket from client, plus pane PTY masters | tmux socket to client, plus pane PTY masters |
| shell in a pane | pane PTY slave as `stdin` | pane PTY slave as `stdout`/`stderr` |

Two subtle but important points:

- the tmux client and tmux server talk to each other over tmux's own socket,
  not through the outer PTY
- each pane shell is attached to its **own** PTY managed by the tmux server

### What happens if you type `ls` in a normal tmux pane?

The full path is:

```text
1. You type `ls` in Ghostty.
2. Ghostty writes `ls\n` to the outer PTY master.
3. The tmux client reads `ls\n` on its stdin from the outer PTY slave.
4. The tmux client sends those key bytes to the tmux server over the tmux socket.
5. The tmux server decides which pane is active.
6. The tmux server writes `ls\n` into that pane's PTY master.
7. The pane shell reads it on its stdin from that pane PTY slave.
8. The shell runs `ls`.
9. `ls` writes to stdout.
10. The tmux server reads that output from the pane PTY master.
11. The tmux server converts pane state into terminal drawing bytes.
12. The tmux client writes those drawing bytes to stdout on the outer PTY slave.
13. Ghostty reads them from the outer PTY master.
14. Ghostty renders them.
```

Sequence diagram:

```text
You      Ghostty    outer PTY   tmux client   tmux server   pane PTY   shell
 |          |           |            |             |            |         |
 | type ls  |           |            |             |            |         |
 |--------> | write     |            |             |            |         |
 |          |---------> | stdin      |             |            |         |
 |          |           |----------> | send keys   |            |         |
 |          |           |            |-----------> | write      |         |
 |          |           |            |             |----------> | stdin   |
 |          |           |            |             |            |-------> |
 |          |           |            |             | read out   |         |
 |          |           | stdout     |<----------- |<---------- | stdout  |
 |          | <---------|<---------- |             |            |         |
 | sees UI  | render    |            |             |            |         |
```

Why this matters:

- Ghostty still sees only **one outer byte stream**
- tmux is the thing drawing borders, status bars, and pane arrangement
- Ghostty does not know where one tmux pane starts and another ends

## 4. What tmux Control Mode Changes

tmux control mode says:

> Do not draw the tmux interface into the terminal. Send structured events and
> command replies instead.

So instead of drawing pane borders itself, tmux sends messages such as:

- `%session-changed`
- `%layout-change`
- `%window-add`
- `%output`

Now the relationship changes:

- in normal tmux, tmux sends a **picture**
- in control mode, tmux sends **data**

That is the conceptual leap.

### What the source surface receives in control mode

The source Ghostty surface is still a normal exec-backed surface running a real
subprocess, `tmux -CC`.

So the source surface still has:

- a PTY
- a subprocess
- a read thread reading bytes from that PTY

But the bytes are different. Instead of a tmux-drawn TUI, Ghostty now reads a
control stream such as:

```text
%begin ...
%end ...
%session-changed ...
%output %0 ...
```

### Sequence diagram: normal tmux vs control mode

This side-by-side contrast is the heart of the feature.

```text
NORMAL TMUX

You        Ghostty       tmux client/server       shell
 |            |                 |                  |
 | type ls    |                 |                  |
 |----------> | bytes           |                  |
 |----------> |---------------> | route to pane    |
 |            |                 |--------------->  |
 |            |                 | pane output      |
 |            | <---------------|<---------------  |
 | sees tmux-drawn UI           |                  |


TMUX CONTROL MODE

You        Ghostty          tmux server            shell
 |            |                 |                  |
 | type ls    | send-keys cmd   |                  |
 |----------> |---------------> | route to pane    |
 |            |                 |--------------->  |
 |            |                 | pane output      |
 |            | <---------------|<---------------  |
 |            | `%output %0 ...`                   |
 | sees native Ghostty UI      |                  |
```

The short reading is:

- in normal tmux, Ghostty receives tmux's finished drawing
- in control mode, Ghostty receives tmux's structured events and pane output

### If a future full control-mode Ghostty pane receives `ls`

In a complete control-mode integration, typing `ls` in a native Ghostty tmux
pane would work like this:

```text
keyboard
  -> child Ghostty surface
  -> tmux backend turns the keys into a tmux command such as `send-keys`
  -> source surface sends that command to `tmux -CC`
  -> tmux server forwards the keys into the real pane shell
  -> shell output comes back as `%output`
  -> Ghostty routes `%output` to the correct pane
```

A compact diagram:

```text
keyboard -> child Ghostty pane -> `send-keys` command -> tmux -CC client -> tmux server -> shell
shell output -> tmux server -> `%output` -> Ghostty parser/viewer -> child Ghostty pane
```

### What the first MVP does instead

The first MVP does **not** implement that full input/output loop.

It only proves:

- Ghostty can create one tmux-backed child surface
- Ghostty can seed that child surface with one pane snapshot

So in the MVP:

- later live `%output` is **not** forwarded to the child
- typing in the child does **not** go back to tmux

That is deliberate scope, not an accident.

### Sequence diagram: what section 4 means in the MVP

```text
You        child surface     source surface       tmux server       shell
 |              |                 |                   |              |
 | type ls      |                 |                   |              |
 |------------> | stop            |                   |              |
 |              |                 |                   |              |
 |              |                 |  earlier snapshot |              |
 |              | <---------------|<------------------|<-----------  |
 | sees static child window       |                   |              |
```

In the MVP, section 4 is only half-built:

- Ghostty can receive tmux data and show one snapshot
- Ghostty cannot yet turn child keystrokes into tmux input

## 5. What Ghostty Already Had Before The MVP

Before the MVP, Ghostty already knew how to do most of the hard protocol work.

It could already:

1. detect tmux control mode in DCS
2. parse tmux control-mode notifications
3. build a `Viewer` state machine
4. ask tmux for windows, panes, captures, and pane state
5. build a `Terminal` object for each tmux pane
6. feed captured bytes into those pane terminals
7. route later `%output` into those pane terminals

So the main missing piece was **not** "understand tmux".

The missing piece was:

```text
How do we create a real visible Ghostty surface whose data source is tmux,
not a subprocess PTY?
```

That is why the `.windows` action was the important dead end.

## 6. Surface, Renderer, Termio, And Terminal

These four words must be kept separate.

### `Surface`

A `Surface` is the user-facing terminal widget.

It:

- receives keyboard and mouse input
- owns an IO thread
- owns a renderer thread
- owns a `Termio`
- appears as a window, tab, or split depending on the runtime

You may think of it as:

```text
the whole visible terminal unit
```

### `Terminal`

A `Terminal` is the in-memory terminal emulator state.

It holds things such as:

- the character grid
- scrollback
- cursor position
- current modes
- colours and attributes

You may think of it as:

```text
the terminal's memory of what the screen should look like
```

### `Renderer`

A renderer turns `Terminal` state into pixels.

It:

- reads the terminal grid
- builds GPU draw work
- paints the actual window contents

The renderer does **not** care whether the bytes came from:

- a local shell PTY
- tmux snapshot bytes
- future tmux live `%output`

It only cares about the `Terminal` state it is asked to draw.

### `Termio`

`Termio` is the coordinator.

It owns:

- the surface's `Terminal`
- the surface's backend
- the VT stream handler that feeds bytes into the terminal

Its job is:

- receive bytes from the backend
- process those bytes into terminal state
- send user input back out through the backend

### Why you should care about this split

Because a tmux pane is not useful to Ghostty until Ghostty has **all four**:

- a visible `Surface`
- a `Termio`
- a `Terminal`
- a `Renderer`

Parsed tmux data alone is not enough.

## 7. What A Backend Is, And Why The MVP Needed A New One

The backend is the part of `Termio` that answers two questions:

1. where do input bytes come from?
2. where do output bytes go?

### Before the MVP

Ghostty had one backend kind:

- `.exec`

That backend assumes:

- there is a subprocess
- there is a PTY
- there is a read thread blocking in `read()`

That design is perfectly correct for a normal terminal window.

### Why `.exec` assumes a subprocess and PTY

Because in ordinary Ghostty use the surface really does launch a program:

- shell
- ssh
- tmux
- or any other command

That program expects terminal semantics, so Ghostty gives it a PTY.

The read thread exists because:

- reading from a PTY is blocking
- Ghostty must not block the UI thread waiting for shell output

So the exec model is:

```text
launch subprocess
own PTY
spawn read thread
read bytes from PTY
feed bytes into Termio.processOutput()
```

### Why that does not fit a tmux child surface

The tmux child surface does **not** own the real shell.

The real shell already belongs to tmux.

More precisely:

- the real pane shell is attached to a pane PTY owned by the tmux server
- the child Ghostty surface does not create that shell
- the child Ghostty surface does not create that PTY

So giving the child surface an `.exec` backend would be a lie.

### Why the `.tmux` backend is the right shape

The `.tmux` backend says:

```text
This surface is real.
It has its own Termio and Terminal.
But it does not own a subprocess PTY.
Its bytes are injected from tmux-related code elsewhere.
```

That is why the new backend is not an optional refinement. It is the smallest
honest statement of what the child surface really is.

## 8. Why The Source Surface Uses `.exec`

The source surface is the original Ghostty window that launched `tmux -CC`.

It uses `.exec` for a simple reason:

- it really does launch a subprocess
- that subprocess is `tmux -CC ...`
- Ghostty really does talk to it through a PTY

So for the source surface the ordinary exec model is still exactly right.

### What the source surface owns

The source surface owns:

- the PTY connected to `tmux -CC`
- the subprocess running the tmux client
- the read thread that reads the control-mode byte stream
- the `Viewer` that turns tmux protocol data into Ghostty state

That is why the source surface is the "owner" of the tmux session in the MVP.

### Why the `.tmux` child is a child of the source surface

Here "child" means:

- it is created because the source surface discovered a tmux pane
- the source surface remembers which child belongs to which pane
- the source surface forwards the snapshot to that child when ready

So the child surface is not independent. It is a dependent window created from
the source surface's tmux state.

### Startup example

```text
1. Source surface launches `tmux -CC`.
2. Source read thread parses control-mode bytes.
3. Viewer discovers the first tmux window and its first pane.
4. Source surface asks the app thread to create one child surface.
5. Later, source surface forwards one snapshot to that child.
```

That is the MVP in one paragraph.

## 9. The Two Surfaces After The MVP

After the MVP there are two important surfaces.

### The source surface

The source surface:

- uses backend `.exec`
- has a PTY
- has the `tmux -CC` subprocess
- receives the tmux control-mode byte stream
- owns the `Viewer`

Its job is to **understand tmux**.

### The child surface

The child surface:

- uses backend `.tmux`
- does not launch a subprocess
- does not own a PTY
- owns its own `Termio`
- owns its own `Terminal`
- is seeded from one tmux pane snapshot

Its job is to **display one pane snapshot as a normal Ghostty surface**.

### What "seeded from a snapshot" means

It means:

- the Viewer captures visible bytes for one tmux pane
- those bytes are sent once into the child surface
- the child surface processes them through its own normal terminal path

So the child is not sharing the Viewer's `Terminal`.

It is building **its own** `Terminal` from the snapshot bytes.

### Sequence diagram: source surface and child surface side by side

```text
tmux server
   |
   | control-mode byte stream
   v
+---------------------------+        app thread handoff       +----------------------+
| source surface            | ------------------------------> | child surface        |
| backend = .exec           |                                 | backend = .tmux      |
| owns PTY                  |                                 | no PTY               |
| owns tmux -CC subprocess  |                                 | no subprocess        |
| owns Viewer               |                                 | owns its own Termio  |
| parses `%output`, layout  |                                 | owns its own Terminal|
| stores pending snapshot   | <------------------------------ | target ready message |
+---------------------------+                                 +----------------------+
              |
              | `.process_output` snapshot bytes
              v
       child IO thread
```

This diagram explains the single most important architectural split:

- the source surface understands tmux
- the child surface displays bytes forwarded from the source surface

### Post-MVP startup and snapshot flow

```text
tmux server
  -> source surface PTY
  -> source read thread
  -> DCS/parser/viewer
  -> `.windows`
  -> app thread creates child surface

later:

tmux `capture-pane` reply
  -> source read thread
  -> viewer emits `.pane_snapshot`
  -> source surface stores snapshot
  -> child target ready?
     yes -> send snapshot to child IO thread
     no  -> keep snapshot until child is ready
  -> child IO thread calls `processOutput(snapshot_bytes)`
  -> child Terminal updates
  -> child renderer draws
```

### If you type `ls` in the child window in the current MVP

Nothing useful happens.

The path is intentionally cut off:

```text
keyboard -> child surface -> read-only check / tmux queueWrite no-op -> stop
```

So the correct answer for the current MVP is:

- the child window is a snapshot viewer, not a live interactive pane

## 10. The Threads, Slowly And Precisely

This is the part that usually becomes confusing.

### Main or app thread

This is the GUI thread.

In the macOS embedding path, you can see it through:

- `ghostty_app_tick()` in `src/apprt/embedded.zig`
- `App.tick()` in `src/App.zig`

Its job is to:

- drain the app mailbox
- create windows and surfaces
- perform runtime actions

### Source IO thread

This is the source surface's ordinary Termio thread in `src/termio/Thread.zig`.

Its job is to:

- drain the source surface's IO mailbox
- handle writes, resize, focus, and similar requests
- call backend methods such as `queueWrite`

It is **not** the same thread as the read thread.

### Source read thread

This exists only because the source surface uses `.exec`.

It is spawned by `Exec.threadEnter()` in `src/termio/Exec.zig`.

Its job is to:

- block in `read()` on the PTY
- pass bytes into `Termio.processOutput()`
- therefore run the tmux parsing path

This is the thread where `.windows` is reached.

### Child IO thread

The child surface still has an IO thread, because every surface has a normal
Termio lifecycle.

But the child does **not** have an exec read thread, because the child backend
is `.tmux`, not `.exec`.

The child IO thread is where the snapshot bytes are consumed.

### Renderer threads

Each surface has its own renderer thread.

So after the MVP there are at least:

- one renderer thread for the source surface
- one renderer thread for the child surface

### Thread map with code anchors

| Thread | Where to look | What it does | Why it exists |
|-------|----------------|--------------|---------------|
| main / app thread | `src/apprt/embedded.zig`, `ghostty_app_tick()`; `src/App.zig`, `App.tick()` | drains app mailbox, performs runtime actions, creates windows | UI and surface creation must happen here |
| source IO thread | `src/termio/Thread.zig` | drains source IO mailbox, sends writes, handles resize/focus | keeps IO work off the app thread |
| source read thread | `src/termio/Exec.zig`, `ReadThread.threadMainPosix()` | blocks in `read()` on the source PTY and calls `processOutput()` | PTY reads block, so they need their own thread |
| child IO thread | `src/termio/Thread.zig` | drains child IO mailbox, handles `.process_output` snapshot bytes | child still needs normal Termio processing, but no PTY reader |
| renderer thread | `src/renderer/Thread.zig` | reads terminal state and draws pixels | rendering should not block IO or UI |

### What a mailbox message is

A mailbox message is just a queued piece of work for another thread.

Why use one?

- the sending thread can continue immediately
- the receiving thread handles the work later on the correct thread

Why should you care?

- Ghostty uses mailboxes to avoid direct cross-thread mutation
- that is how it crosses the read-thread -> app-thread boundary safely
- that is also how the source surface feeds bytes to the child IO thread safely

### One thread diagram for the MVP

```text
MAIN / APP THREAD
  drains App mailbox
  creates child window

SOURCE SURFACE
  renderer thread
  IO thread
  read thread  <- reads tmux control-mode PTY bytes

CHILD SURFACE
  renderer thread
  IO thread    <- receives `.process_output` snapshot bytes
  no read thread
```

### One concrete thread walkthrough: creating the child window

```text
1. source read thread reads tmux bytes from the PTY
2. source read thread runs parser + viewer
3. source read thread reaches `.windows`
4. source read thread pushes `new_tmux_window` to the app mailbox
5. app thread later drains that mailbox in `App.tick()`
6. app thread creates the child surface
7. runtime sends `tmux_mvp_target_ready` back to the source surface
8. source surface can now flush snapshot bytes to the child IO thread
9. child IO thread runs `processOutput(snapshot_bytes)`
10. child renderer thread paints the child window
```

### The same walkthrough, expanded with code anchors

Step 1: source read thread reads tmux bytes from the PTY.

- The source surface uses the exec backend.
- `Exec.threadEnter()` starts the subprocess and spawns the read thread at
  `src/termio/Exec.zig:84-143`.
- That read thread later blocks in `posix.read()` at
  `src/termio/Exec.zig:1298` and calls `Termio.processOutput(...)` at
  `src/termio/Exec.zig:1326`.

Step 2: source read thread runs parser + viewer.

- `Termio.processOutput()` feeds bytes into the terminal stream/parser path.
- When tmux control mode begins, `dcs.zig` detects `ESC P 1000 p` in
  `src/terminal/dcs.zig:50-74`.
- `stream_handler.zig` receives `.enter` and creates the `Viewer` at
  `src/termio/stream_handler.zig:397-405`.
- Later notifications are passed into `viewer.next(...)` at
  `src/termio/stream_handler.zig:439`.

Step 3: source read thread reaches `.windows`.

- The Viewer emits `.windows` from its normal state-machine path.
- `stream_handler.zig` handles that action at
  `src/termio/stream_handler.zig:458-492`.

Step 4: source read thread pushes `new_tmux_window` to the app mailbox.

- This is the exact point where it happens:
  `src/termio/stream_handler.zig:484-491`.
- Before that, `stream_handler.zig` picks the first pane leaf of the first
  tmux window with `layout.firstPane()` at
  `src/termio/stream_handler.zig:472` and
  `src/terminal/tmux/layout.zig:93-105`.
- So the code that sends `new_tmux_window` is `stream_handler.zig`, not
  `viewer.zig` directly.

Step 5: app thread later drains that mailbox in `App.tick()`.

- `ghostty_app_tick()` in `src/apprt/embedded.zig` calls `App.tick()`.
- `App.tick()` calls `drainMailbox()` in `src/App.zig:238-266`.
- The specific `new_tmux_window` case is handled at `src/App.zig:247-250`.

Step 6: app thread creates the child surface.

- `App.newTmuxWindow()` builds a `SurfaceConfig` with:
  - backend = `.tmux`
  - source surface pointer
  - pane id
  - cols
  - rows
- That happens at `src/App.zig:307-326`.
- The runtime receives that config through
  `new_window_with_surface_config`.
- In `src/apprt/embedded.zig:537-557`, the runtime converts that config into
  `CoreSurface.InitBackend.tmux_mvp` and calls `Surface.init(...)`.

At this point, what does the child surface contain?

- a real `Surface`
- its own `Termio`
- its own `Terminal`
- its own IO thread
- its own renderer thread
- backend `.tmux`
- no subprocess
- no PTY
- no exec read thread

You can see the backend selection in `src/Surface.zig:656-698`, especially:

- `.tmux_mvp => ... termio.Tmux.init(...)` at `src/Surface.zig:685`
- `Termio.init(...)` at `src/Surface.zig:688-698`

Step 7: runtime sends `tmux_mvp_target_ready` back to the source surface.

- This happens in `src/apprt/embedded.zig:560-578`.
- The runtime pushes a surface message back to the source surface saying:
  the child target exists, here is its surface pointer.

Step 8: source surface can now flush snapshot bytes to the child IO thread.

- The source surface handles `.tmux_mvp_target_ready` in
  `src/Surface.zig:1208-1213`.
- It stores the child pointer in `self.tmux_mvp.target`.
- Then it immediately calls `tmuxMvpFlushPendingSnapshotLocked()`.
- That flush function is at `src/Surface.zig:1237-1246`.

What this means in plain English:

- if snapshot bytes were already waiting, the source now has enough information
  to deliver them
- if snapshot bytes are not waiting yet, nothing happens yet, but the target is
  now recorded

Step 9: child IO thread runs `processOutput(snapshot_bytes)`.

- The source does not mutate the child terminal directly.
- Instead, it sends the child an IO mailbox message `.process_output` at
  `src/Surface.zig:1241-1245`.
- The child IO thread drains that message in `src/termio/Thread.zig:354-356`.
- That code calls `io.processOutput(v.data)`.

This is an important design choice:

- the source thread sends bytes
- the child IO thread performs terminal mutation

Step 10: child renderer thread paints the child window.

- Once `processOutput()` has updated the child terminal, the normal renderer
  wakeup/render path takes over.
- The child renderer thread is just a normal Ghostty renderer thread for that
  child surface.
- So the child is not a fake view of tmux state. It is a normal Ghostty
  surface rendering its own terminal state.

## 11. What Happens When `tmux -CC` Starts

Let us walk the actual startup in order.

```text
1. Source surface launches `tmux -CC` through the exec backend.
2. The source read thread reads the DCS entry for tmux control mode.
3. Ghostty creates the `Viewer`.
4. The Viewer learns the tmux session and window layout.
5. The Viewer emits `.windows`.
6. `stream_handler.zig` picks the first pane leaf of the first window.
7. It sends `new_tmux_window` to the app mailbox.
8. The app thread creates the child surface with backend `.tmux`.
9. The runtime notifies the source surface that the target child is ready.
10. Later the Viewer emits `.pane_snapshot` for the primary visible capture.
11. The source surface forwards that snapshot to the child IO thread.
12. The child processes the bytes and renders them.
```

That is the smallest successful end-to-end story of the first MVP.

### The same startup walkthrough, with the key code points

Step 1: Source surface launches `tmux -CC` through the exec backend.

- `Exec.threadEnter()` starts the subprocess at
  `src/termio/Exec.zig:84-101`.
- It also spawns the source read thread at `src/termio/Exec.zig:137-143`.

Step 2: The source read thread reads the DCS entry for tmux control mode.

- The read thread reads PTY bytes at `src/termio/Exec.zig:1298-1326`.
- `dcs.zig` recognizes tmux control mode at `src/terminal/dcs.zig:54-74`.

Step 3: Ghostty creates the `Viewer`.

- `stream_handler.zig` handles `.enter` and allocates the `Viewer` at
  `src/termio/stream_handler.zig:397-405`.

Step 4: The Viewer learns the tmux session and window layout.

- `stream_handler.zig` feeds tmux notifications into `viewer.next(...)` at
  `src/termio/stream_handler.zig:439`.
- `viewer.next()` dispatches according to Viewer state at
  `src/terminal/tmux/viewer.zig:321-343`.

Step 5: The Viewer emits `.windows`.

- That action is later observed by `stream_handler.zig` in the action loop at
  `src/termio/stream_handler.zig:439-492`.

Step 6: `stream_handler.zig` picks the first pane leaf of the first window.

- The `.windows` handler begins at `src/termio/stream_handler.zig:458`.
- It calls `windows[0].layout.firstPane()` at `src/termio/stream_handler.zig:472`.
- `firstPane()` itself is defined at `src/terminal/tmux/layout.zig:93-105`.

Step 7: It sends `new_tmux_window` to the app mailbox.

- This is the exact line range:
  `src/termio/stream_handler.zig:484-491`.
- So, to answer the natural question directly:

```text
`stream_handler.zig` sends `new_tmux_window` to the app mailbox.
```

Step 8: The app thread creates the child surface with backend `.tmux`.

- `App.drainMailbox()` receives the message at `src/App.zig:247-250`.
- `App.newTmuxWindow()` builds the `SurfaceConfig` and calls
  `new_window_with_surface_config` at `src/App.zig:307-326`.
- The runtime converts that config into `InitBackend.tmux_mvp` and calls
  `Surface.init(...)` at `src/apprt/embedded.zig:537-557`.
- `Surface.init(...)` chooses backend `.tmux` at `src/Surface.zig:656-698`,
  especially `src/Surface.zig:685`.

Step 9: The runtime notifies the source surface that the target child is ready.

- That happens at `src/apprt/embedded.zig:560-578`.
- The message is `tmux_mvp_target_ready`.

Step 10: Later the Viewer emits `.pane_snapshot` for the primary visible capture.

- `viewer.zig` appends `.pane_snapshot` at
  `src/terminal/tmux/viewer.zig:820-833`.

Step 11: The source surface forwards that snapshot to the child IO thread.

This is worth slowing down for.

First, `stream_handler.zig` receives `.pane_snapshot` at
`src/termio/stream_handler.zig:494-502`.

Then it:

- checks the pane id matches the pane chosen for the MVP
- stores the bytes with `tmuxMvpStoreSnapshotLocked(...)`
- tries to flush them immediately with `tmuxMvpFlushPendingSnapshotLocked(...)`

The actual source-surface storage and flush code lives here:

- store snapshot: `src/Surface.zig:1226-1228`
- flush snapshot to child IO thread: `src/Surface.zig:1237-1246`

The flush is not "copy terminal state into the child".
It is:

```text
source surface -> child IO mailbox -> `.process_output`
```

Step 12: The child processes the bytes and renders them.

- The child IO thread handles `.process_output` at
  `src/termio/Thread.zig:354-356`.
- It calls `io.processOutput(v.data)`.
- After that, the child follows the normal Ghostty rendering path.

## 24. Debugger Walkthrough For Section 11

This section is for a reader with little or no debugger experience.

The goal is not to debug a bug. The goal is to **validate the walkthrough in
section 11 with your own eyes**.

We will use LLDB on macOS and stop at a small set of high-value points.

Important note:

- the line numbers below are correct for the code as read for this tutorial
- if the code changes later, expect some line numbers to drift a little

### What you are trying to see

You want to see these moments happen, in this order:

1. Ghostty launches `tmux -CC`
2. the source read thread starts reading bytes
3. DCS detects tmux control mode
4. `stream_handler.zig` creates the Viewer
5. `stream_handler.zig` handles `.windows`
6. `stream_handler.zig` sends `new_tmux_window`
7. `App.zig` receives `new_tmux_window`
8. the runtime creates the child surface
9. the runtime sends `tmux_mvp_target_ready`
10. `viewer.zig` emits `.pane_snapshot`
11. `stream_handler.zig` receives `.pane_snapshot`
12. the source surface flushes `.process_output`
13. the child IO thread runs `processOutput(...)`

That is enough. Do not try to breakpoint every helper.

### Before you begin

Use a Debug build of Ghostty.

If you are following the repo's usual macOS flow, the executable is typically:

```text
macos/build/Debug/Ghostty.app/Contents/MacOS/ghostty
```

You also want a deterministic initial command, so use the checked-in attach
script from the validation docs if possible.

### What is LLDB?

LLDB is the debugger.

Very small working vocabulary:

- `breakpoint set ...` means "stop when execution reaches here"
- `run` starts the program
- `continue` resumes after a stop
- `thread backtrace` shows the current call stack
- `frame variable` shows local variables in the current frame
- `next` steps over one source line
- `step` steps into a function call

That is enough for this walkthrough.

### Start LLDB

From the repository root:

```bash
lldb /Users/waqas/code/ghostty_forked/macos/build/Debug/Ghostty.app/Contents/MacOS/ghostty
```

At the `(lldb)` prompt, add these breakpoints.

### Breakpoint set: the essential path

1. Source surface launches `tmux -CC` and spawns the read thread:

```text
breakpoint set --file Exec.zig --line 91
breakpoint set --file Exec.zig --line 138
```

What you will see:

- line 91: subprocess start
- line 138: read-thread spawn

2. Source read thread begins processing tmux bytes:

```text
breakpoint set --file Exec.zig --line 1298
```

What you will see:

- the read thread stopping in `posix.read(...)`

3. DCS detects tmux control mode:

```text
breakpoint set --file dcs.zig --line 60
breakpoint set --file dcs.zig --line 63
```

What you will see:

- line 60: the check for `ESC P 1000 p`
- line 63: return of `.tmux = .enter`

4. `stream_handler.zig` creates the Viewer:

```text
breakpoint set --file stream_handler.zig --line 398
breakpoint set --file stream_handler.zig --line 401
```

What you will see:

- line 398: `.enter`
- line 401: Viewer allocation

5. `stream_handler.zig` handles `.windows` and sends `new_tmux_window`:

```text
breakpoint set --file stream_handler.zig --line 458
breakpoint set --file stream_handler.zig --line 472
breakpoint set --file stream_handler.zig --line 484
```

What you will see:

- line 458: `.windows` action handler entered
- line 472: first pane chosen with `firstPane()`
- line 484: `new_tmux_window` pushed to app mailbox

6. App thread receives `new_tmux_window`:

```text
breakpoint set --file App.zig --line 250
breakpoint set --file App.zig --line 307
```

What you will see:

- line 250: `drainMailbox()` handling `.new_tmux_window`
- line 307: `newTmuxWindow(...)`

7. Runtime creates the child surface:

```text
breakpoint set --file embedded.zig --line 537
breakpoint set --file embedded.zig --line 550
breakpoint set --file Surface.zig --line 656
breakpoint set --file Surface.zig --line 685
breakpoint set --file Surface.zig --line 688
```

What you will see:

- line 537: runtime switches on backend kind
- line 550: `Surface.init(...)`
- line 656: backend choice in `Surface.init(...)`
- line 685: `.tmux = termio.Tmux.init(...)`
- line 688: `Termio.init(...)` for the child

8. Runtime sends `tmux_mvp_target_ready`:

```text
breakpoint set --file embedded.zig --line 568
breakpoint set --file Surface.zig --line 1208
```

What you will see:

- line 568: source-surface message push
- line 1208: source surface handles `.tmux_mvp_target_ready`

9. Viewer emits `.pane_snapshot`:

```text
breakpoint set --file viewer.zig --line 826
breakpoint set --file viewer.zig --line 828
```

What you will see:

- line 826: primary-screen check
- line 828: append `.pane_snapshot`

10. Source surface receives snapshot and flushes it:

```text
breakpoint set --file stream_handler.zig --line 494
breakpoint set --file Surface.zig --line 1226
breakpoint set --file Surface.zig --line 1237
breakpoint set --file Surface.zig --line 1241
```

What you will see:

- line 494: `.pane_snapshot` action handler
- line 1226: snapshot bytes stored
- line 1237: flush helper entered
- line 1241: child gets `.process_output`

11. Child IO thread processes snapshot bytes:

```text
breakpoint set --file Thread.zig --line 354
breakpoint set --file Thread.zig --line 356
```

What you will see:

- line 354: `.process_output` branch
- line 356: `io.processOutput(v.data)`

### Automating the breakpoint setup

You do not need to type all those breakpoints by hand every time.

This tutorial now includes two helper files:

- [lldb_tmux_mvp_breakpoints.lldb](/Users/waqas/code/ghostty_forked/tmux_docs/postmvp/lldb_tmux_mvp_breakpoints.lldb)
- [run_ghostty_lldb_tmux_mvp.sh](/Users/waqas/code/ghostty_forked/tmux_docs/postmvp/run_ghostty_lldb_tmux_mvp.sh)

The first file is an LLDB command file that sets the breakpoint list for this
walkthrough.

The second file launches Ghostty under LLDB and preloads that command file.

So the easiest way to start is:

```bash
sh /Users/waqas/code/ghostty_forked/tmux_docs/postmvp/run_ghostty_lldb_tmux_mvp.sh
```

That will drop you into LLDB with the tutorial breakpoints already installed.

If you want to start LLDB yourself and only preload the breakpoint file, use:

```bash
lldb -S /Users/waqas/code/ghostty_forked/tmux_docs/postmvp/lldb_tmux_mvp_breakpoints.lldb \
  /Users/waqas/code/ghostty_forked/macos/build/Debug/Ghostty.app/Contents/MacOS/ghostty
```

If you are already inside LLDB, you can load the file with:

```text
command source /Users/waqas/code/ghostty_forked/tmux_docs/postmvp/lldb_tmux_mvp_breakpoints.lldb
```

### Run the program

Now run Ghostty under LLDB.

If you want Ghostty to start directly in the validation attach path:

```text
run --quit-after-last-window-closed=true --window-save-state=never --initial-command=direct:/Users/waqas/code/ghostty_forked/tmux_docs/firstmvp/validation/ghostty_tmux_fullmvp_attach.sh
```

If you prefer, you can also just:

```text
run
```

and then type your tmux command manually in Ghostty.

### What to do each time LLDB stops

At each breakpoint, use this tiny routine:

1. See where you are:

```text
thread backtrace
```

2. Inspect locals if they seem important:

```text
frame variable
```

3. If you want to look at one important variable:

```text
frame variable windows
frame variable pane
frame variable msg
frame variable v
```

4. Resume:

```text
continue
```

That is enough for this walkthrough.

### A suggested first pass

On your **first** debugger pass, do not step deeply. Just watch the stops in
order and confirm the architecture.

Focus on these questions:

- Did `stream_handler.zig` really send `new_tmux_window`?
- Did `App.zig` really receive it on the app thread?
- Did `Surface.init(...)` really choose backend `.tmux` for the child?
- Did `viewer.zig` really emit `.pane_snapshot`?
- Did the source really flush `.process_output` into the child?

If you can answer yes to those with your own eyes, section 11 has become real.

### A suggested second pass

On your **second** pass, pick only three breakpoints and step more carefully:

1. `stream_handler.zig:458`
2. `App.zig:307`
3. `Surface.zig:1237`

Those three give you:

- tmux discovery
- app-thread child creation
- snapshot delivery

That is the most compact mental model of the MVP.

### What not to do

- Do not breakpoint every helper in the call graph.
- Do not step instruction-by-instruction.
- Do not try to understand all threads at once.
- Do not worry if stops happen on different threads; that is expected here.

The aim is architectural validation, not microscopic tracing.

### One sentence summary of the debugger plan

Use a small set of breakpoints to watch the handoff:

```text
tmux bytes -> Viewer -> `.windows` -> `new_tmux_window` -> child surface ->
`tmux_mvp_target_ready` -> `.pane_snapshot` -> `.process_output` -> child render
```

### Sequence diagram: startup path of the first MVP

```text
tmux -CC      source read     Viewer / stream      app thread      child IO / renderer
process       thread          handler              / runtime       thread
   |              |                |                  |                 |
   | DCS + tmux   |                |                  |                 |
   | bytes        |--------------> | create Viewer    |                 |
   |              |                |                  |                 |
   | session +    |--------------> | discover windows |                 |
   | list data    |                | emit `.windows`  |                 |
   |              |                |----------------> | create child    |
   |              |                |                  |--------------->  |
   |              |                | <----------------| target ready     |
   | capture-pane |--------------> | emit `.pane_snapshot`              |
   | bytes        |                | store/flush snapshot               |
   |              |                |---------------------------------->  |
   |              |                |                  | processOutput    |
   |              |                |                  | render           |
```

This is the startup story in one picture:

- tmux speaks only to the source surface
- the child appears only after the app thread creates it
- the child is populated only after snapshot bytes are flushed to it

## 12. Why The App Thread Is Needed

This point is simple but crucial.

The source read thread is good at:

- reading bytes
- parsing bytes
- updating tmux-related state

But it is **not** allowed to:

- create native windows
- create native UI views
- perform the main-thread surface initialization path

So when `.windows` arrives, the source read thread must do this:

```text
source read thread -> app mailbox -> app thread
```

Why that boundary exists:

- GUI runtimes expect UI creation on the main thread
- Ghostty's app/runtime state is owned there
- `Surface.init()` is a main-thread operation

That is why the app thread is not optional machinery. It is the thread that is
allowed to turn "I found a pane" into "there is now a real window".

## 13. Where `.windows`, `.pane_snapshot`, And The New Messages Come From

This is the file-by-file explanation.

### `viewer.zig`

`viewer.zig` produces the two key actions:

- `.windows`
- `.pane_snapshot`

Where do they come from?

- `.windows` is emitted when the Viewer has processed `list-windows` output and
  synchronized its internal window/layout state
- `.pane_snapshot` is emitted when the Viewer processes the **primary-screen
  visible** `capture-pane` response for a pane

So:

```text
`.windows` answers: "what windows and panes exist?"
`.pane_snapshot` answers: "what bytes should seed this pane right now?"
```

### `stream_handler.zig`

This is the glue file.

It now does two important things:

1. when it receives `.windows`, it asks for a tmux child window
2. when it receives `.pane_snapshot`, it stores and flushes snapshot bytes

In other words:

```text
Viewer -> Action
stream_handler -> turns Action into cross-thread work
```

### `App.zig`

`App.zig` adds the app-mailbox message:

- `new_tmux_window`

Why does this matter?

- because it is the bridge from background tmux logic to main-thread window
  creation

`App.tick()` drains the app mailbox, and `newTmuxWindow()` turns that message
into a runtime action carrying a `SurfaceConfig`.

### `apprt/action.zig`

This adds:

- `new_window_with_surface_config`

Why care?

- the old "new window" action was too vague
- the runtime needed an explicit way to say "make a window with backend `.tmux`
  and these tmux fields"

### `apprt/surface.zig`

This defines the shared `SurfaceConfig`.

For the MVP that config carries:

- backend kind
- source surface pointer
- pane id
- cols
- rows

It also adds the surface messages:

- `tmux_mvp_target_ready`
- `tmux_mvp_target_closed`

Why care?

- `target_ready` tells the source surface "the child exists now"
- `target_closed` tells it "stop holding that child pointer"

### One compact message flow

```text
Viewer emits `.windows`
  -> stream_handler sends App.Message.new_tmux_window
  -> App.tick() handles it on app thread
  -> runtime action `new_window_with_surface_config`
  -> child surface created
  -> runtime sends `tmux_mvp_target_ready` back to source surface

Viewer emits `.pane_snapshot`
  -> stream_handler stores snapshot on source surface
  -> source flushes snapshot to child with IO message `.process_output`
```

## 14. How The Child Window Gets Its Text

The child does not get its text at window-creation time.

It gets its text when both of these are true:

1. the child surface exists
2. the snapshot bytes for the chosen pane exist

That is why the source surface stores pending state.

### The two orderings

Ordering A:

```text
child ready first
snapshot later
-> snapshot is flushed immediately when it arrives
```

Ordering B:

```text
snapshot first
child ready later
-> source keeps snapshot in memory until child is ready
```

That is a small but important piece of robustness.

### The exact delivery path

```text
Viewer emits `.pane_snapshot`
  -> source surface stores bytes
  -> source surface sends child IO message `.process_output`
  -> child IO thread calls `io.processOutput(bytes)`
  -> child Terminal updates itself
  -> child renderer paints the result
```

So the child receives bytes, not a copied `Terminal`.

## 15. Why The Snapshot Is Sent As Bytes

This choice is both simpler and safer.

Why not copy the whole `Terminal` struct?

Because that would mean copying a large amount of internal emulator state:

- grids
- cursor state
- modes
- scrollback
- and whatever else affects rendering

That is brittle.

Sending bytes is better because Ghostty already knows how to do this safely:

- feed bytes into `processOutput()`
- let the child's own terminal parser build the child's own terminal state

So the path stays familiar:

```text
bytes -> processOutput -> Terminal state -> renderer
```

Why this is safe:

- the child mutates its **own** terminal
- mutation happens on the child IO thread
- the source surface never reaches across and edits the child terminal directly

That is exactly the kind of boundary you want in concurrent code.

## 16. Why The Child Window Stays Static

This is deliberate MVP scope.

The MVP forwards only:

- one initial pane snapshot

It does **not** forward:

- later live `%output`

So later shell activity still updates the Viewer's internal pane terminal inside
the source surface, but the child window receives nothing new.

Why choose that narrow scope?

- it proves the new surface/backend path works
- it avoids mixing the first proof with live-stream routing problems
- it makes debugging much cleaner

That is why this is a **snapshot MVP**, not a live tmux pane MVP.

## 17. Why The Child Window Is Read-Only

Again, this is deliberate.

Two things enforce it:

1. the child surface is marked read-only
2. `Tmux.queueWrite()` is a no-op in this MVP

So when you type in the child:

- Ghostty does not send those bytes back to tmux

Why is that a sensible first step?

- input forwarding is a second problem
- it needs `send-keys` design, target-pane handling, and correctness checks
- the first MVP only asks: can Ghostty create and render a non-exec surface?

So the read-only child is not unfinished by accident. It is unfinished by
design, because that is the cleanest way to prove the architectural step.

## 18. The Validation Markers, Clearly Explained

The three markers are not random strings. Each one isolates one claim.

| Marker | When created | Where it should appear | What it proves |
|-------|--------------|------------------------|----------------|
| `FULLMVP_SNAP_A` | before Ghostty attaches | source pane and child window | child was seeded from snapshot bytes |
| `FULLMVP_LIVE_B` | after child exists | source pane only | child is static, not live |
| `FULLMVP_CHILD_INPUT` | typed into child | nowhere in real tmux pane | child is read-only |

### `FULLMVP_SNAP_A`

This marker is created **before** Ghostty attaches.

Why must it be created before?

- because the child is seeded from `capture-pane`
- the snapshot can only include content tmux already has at capture time

So if the child shows `FULLMVP_SNAP_A`, you have proved:

- the child window exists
- snapshot bytes crossed from source to child
- the child rendered them

### `FULLMVP_LIVE_B`

This marker is created **after** the child already exists.

If the source pane shows it but the child does not, that proves:

- the real tmux pane kept changing
- the child window is only a snapshot

That is exactly the intended MVP behavior.

### `FULLMVP_CHILD_INPUT`

This is typed into the child itself.

If it never appears in the real tmux pane, that proves:

- child input is not being forwarded back into tmux

So the markers together test three different claims without ambiguity.

## 19. What The First MVP Has Actually Achieved

It is important not to overclaim.

The first MVP does **not** mean:

- full tmux control mode integration is done
- native multi-pane layout is done
- live pane mirroring is done
- interactive child panes are done

The first MVP **does** mean:

- Ghostty can create a visible surface with a non-exec backend
- that surface can have its own Termio and Terminal
- that surface can be sized from tmux pane dimensions
- that surface can be seeded from tmux bytes and rendered normally

That is a real architectural proof.

## 20. What Should Happen Next

The next steps follow naturally from the MVP.

### Live output forwarding

Later `%output` for the chosen pane should be forwarded into the child surface,
not only into the Viewer's internal pane terminal.

### Input forwarding

Typing in the child surface should become tmux commands such as `send-keys`.

### Resize propagation

Resizing the child should become the appropriate tmux-side resize command.

### More panes and windows

Ghostty should create more than one child surface and arrange them as native
tabs and splits.

So the MVP is the foundation, not the finished feature.

## 21. Quick Questions And Answers

### Q1. Is Ghostty reading the shell through Ghostty's own `stdin` and `stdout`?

No.

Ghostty talks to terminal subprocesses through PTY file descriptors.

### Q2. In normal tmux use, why does Ghostty not know about tmux panes?

Because Ghostty only sees the tmux client's outer byte stream, not tmux's
internal pane structure.

### Q3. In control mode, why is the source surface still exec-backed?

Because the source surface really does launch `tmux -CC` as a subprocess over a
PTY.

### Q4. Why can the child not use the existing exec backend?

Because the child does not own a subprocess or PTY. The real shell is already
inside tmux's own pane PTY.

### Q5. Why not point the child renderer directly at the Viewer's terminal?

Because Ghostty's surface model assumes each surface owns its own `Termio` and
its own `Terminal`. The MVP preserves that contract.

### Q6. What is the single most important thread fact to remember?

`.windows` is reached on the **source read thread**, but surface creation must
happen on the **app thread**.

### Q7. What is the single sentence summary of the MVP?

Ghostty can now open one extra native window whose content comes from a tmux
pane snapshot instead of from a subprocess PTY.

## 22. Editorial Review Comments

If one were to review this tutorial in the spirit of Kernighan and Knuth, the
comments would likely sound something like these.

### Clarity

1. Name the concrete endpoints before using abstractions.
   The revised tutorial now introduces `stdin`, `stdout`, PTY master, and PTY
   slave before talking about Ghostty internals. That is the right order for a
   beginner.

2. Prefer one precise sentence over one catchy but incomplete sentence.
   `shell output -> tmux -> Ghostty -> screen` is memorable, but by itself it
   hides too much. The fuller version with PTYs is what teaches.

3. Repeat the same distinction until it sticks.
   The most important distinction is now repeated in several places:
   source surface = `.exec`, child surface = `.tmux`.

### Precision

4. Say when a statement is a simplification.
   The revised draft does this more often. That matters, because terminal
   systems are full of useful lies told for teaching.

5. Separate "what is true in Unix" from "what is true in Ghostty".
   The PTY explanations are Unix facts. The surface/backend/thread structure is
   Ghostty design. Mixing those layers too early confuses the reader.

6. Distinguish the current MVP from the future full design every time the data
   path changes.
   This is especially important in section 4, because otherwise the reader will
   not know whether a diagram is describing current reality or later intent.

### Simplicity

7. Use fewer diagrams, but make each one do more work.
   The added diagrams in sections 4, 9, and 11 are useful because each carries
   a whole idea, not just one line of code flow.

8. Do not explain five new nouns in one paragraph.
   `Surface`, `Terminal`, `Renderer`, `Termio`, and `Backend` are now separated.
   That is good. Readers new to the topic need one mental box at a time.

9. Prefer small contrasts.
   "normal tmux" versus "control mode", and "source surface" versus "child
   surface", are the right teaching contrasts for this material.

### Flow

10. The document is strongest when it moves in this order:
    Unix facts -> normal terminal -> normal tmux -> control mode -> Ghostty MVP.
    That is a natural staircase. Keep it.

11. The thread discussion should come only after the reader understands the two
    surfaces.
    The current order now does that, which is better.

12. End with the hard questions, not with triumph.
    The maintainer questions at the end are useful because they remind the
    reader that the MVP is a proof, not the finished design.

### One sentence summary of the editorial review

This tutorial is now much closer to what a beginner needs: concrete endpoints,
explicit simplifications, repeated contrasts, and diagrams placed where the
reader first needs them.

## 23. Maintainer Questions And Answers

Suppose Mitchell Hashimoto were reviewing this MVP as Ghostty maintainer. These
are the kinds of questions he might reasonably ask to judge whether the design
is sound.

### Q1. Why is a new backend the right abstraction instead of a special-case hack in the source surface?

Because the child surface is genuinely a different kind of thing.

- it owns no subprocess
- it owns no PTY
- it still needs a normal `Surface` + `Termio` + `Terminal` lifecycle

So a new backend says the truth plainly in the type system instead of smearing
 tmux-specific behavior across the exec path.

### Q2. Why create a second `Terminal` for the child instead of reusing the Viewer's pane terminal?

Because the current Ghostty surface contract assumes:

- each surface owns its own `Termio`
- each `Termio` owns its own `Terminal`
- each renderer reads that surface-owned terminal

Reusing the Viewer's terminal would be a larger architectural change. The MVP
keeps the existing ownership model intact and proves the smaller thing first.

### Q3. Why is the first child window a new native window rather than a tab or split?

Because a new native window is the smallest visible proof.

It proves:

- app-thread surface creation works
- a `.tmux` backend can back a real surface
- snapshot bytes can cross into a visible target

It does not yet prove full native tmux layout recreation, and it does not claim
to.

### Q4. Why choose the first pane of the first window instead of the active pane?

Because the MVP is proving surface creation, not correctness of focus policy.

Choosing the first layout leaf is deterministic and cheap. It avoids adding
another axis of complexity to the first proof. That said, a maintainer is right
to note that active-pane selection would matter for the full feature.

### Q5. Is the cross-thread handoff sound, or are we creating windows from the wrong thread?

The handoff is sound in the MVP design because:

- `.windows` is received on the source read thread
- that thread only pushes `new_tmux_window` into the app mailbox
- the app thread later drains the mailbox and creates the child surface

So the read thread requests creation; it does not perform creation.

### Q6. Is snapshot delivery sound if the child is not ready yet?

Yes, within MVP scope.

The source surface stores pending snapshot bytes. Then it handles either order:

- target ready first, snapshot later
- snapshot first, target ready later

Only when both exist does it flush `.process_output` to the child IO thread.

### Q7. Why send bytes rather than copying terminal state directly?

Because bytes are the safer unit of transfer here.

- Ghostty already knows how to turn bytes into terminal state
- the child updates its own terminal on its own IO thread
- no cross-thread direct mutation of the child terminal is needed

This preserves existing processing paths and reduces custom state-copy logic.

### Q8. Why is it acceptable that the child is static and read-only?

Because the MVP is testing one architectural claim:

> can Ghostty create and render a non-exec surface at all?

Live output forwarding and input forwarding are important, but they are next
steps. Keeping them out of the MVP makes the proof smaller, easier to validate,
and easier to discuss with maintainers.

### Q9. What are the main risks that remain after this MVP?

The biggest remaining risks are:

- live `%output` routing into child surfaces
- input routing from child surfaces back to tmux
- resize propagation
- multiple pane/window surface management
- focus and active-pane correctness
- lifetime management when panes or windows disappear

So the MVP lowers one architectural risk, but not all feature risk.

### Q10. Is this design efficient enough for the final feature?

Not proven yet.

The MVP proves correctness of one narrow path, not final scalability. A
maintainer would be right to ask later about:

- many surfaces
- many renderer threads
- duplicated terminal state
- high-rate `%output`

Those are good future questions, but they should not block the first proof.

### Q11. What would justify saying this MVP is sound?

It is sound if it is judged against its real claim, not a larger imaginary one.

Its real claim is:

- a tmux-discovered pane can cause app-thread creation of a real Ghostty child
  surface
- that child surface can be backed by `.tmux`, not `.exec`
- that child surface can render a snapshot through Ghostty's normal terminal and
  renderer pipeline

If those claims hold, the MVP is sound as an MVP.

### Q12. What would a maintainer still want to hear in discussion?

Probably this:

- why the backend boundary is the right one
- why duplicating the terminal is acceptable for now
- what the next step is for live `%output`
- how child input would later become `send-keys`
- how lifetime and pane-close events will be handled later

Those are the questions that turn "this works once" into "this can grow into a
real feature".

### Q4. Why can the child not use the existing exec backend?

Because the child does not own a subprocess or PTY. The real shell is already
inside tmux's own pane PTY.

### Q5. Why not point the child renderer directly at the Viewer's terminal?

Because Ghostty's surface model assumes each surface owns its own `Termio` and
its own `Terminal`. The MVP preserves that contract.

### Q6. What is the single most important thread fact to remember?

`.windows` is reached on the **source read thread**, but surface creation must
happen on the **app thread**.

### Q7. What is the single sentence summary of the MVP?

Ghostty can now open one extra native window whose content comes from a tmux
pane snapshot instead of from a subprocess PTY.
