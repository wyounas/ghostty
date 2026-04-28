# S0 Tutorial

This tutorial explains the first debugging session, `s0_startup_threads`, in
simple language. The goal is not to teach all of Ghostty. The goal is to help
you see what happens when Ghostty starts and creates its first terminal
surface.

## 1. What are we trying to understand?

We are trying to answer five questions:

1. Where does Ghostty start on macOS?
2. Where does the first terminal surface get created?
3. What work happens before Ghostty starts worker threads?
4. Which threads does one normal terminal surface have?
5. Where does the first render come from?

This session is only about startup. It is not about tmux control mode yet.

## 2. The first useful startup point

If you ask, "What is the absolute first instruction of the process?", the real
answer is: loader and runtime code before Ghostty's own source files. That is
too low-level for this session.

So we use the first practical Ghostty-owned startup line instead:

- [main.swift](/Users/waqas/code/ghostty_forked/macos/Sources/App/macOS/main.swift:8)

That line calls:

```swift
ghostty_init(...)
```

This is the first useful place to stop if you want to say, "Ghostty app code is
starting now."

Then startup continues:

```text
main.swift:8   -> ghostty_init(...)
main.swift:31  -> ghostty_cli_try_action()
main.swift:33  -> NSApplicationMain(...)
```

`NSApplicationMain(...)` hands control to AppKit, the macOS application
framework.

## 3. What happens after AppKit takes over?

AppKit starts the app lifecycle. The next important stops are:

- [AppDelegate.swift](/Users/waqas/code/ghostty_forked/macos/Sources/App/macOS/AppDelegate.swift:164)
  `AppDelegate.init`
- [AppDelegate.swift](/Users/waqas/code/ghostty_forked/macos/Sources/App/macOS/AppDelegate.swift:203)
  `applicationDidFinishLaunching`

The important idea is simple:

- `main.swift` starts the app
- AppKit takes over
- AppDelegate does app setup
- later, Ghostty creates the first terminal surface

## 4. What is a surface?

A `Surface` is one terminal view.

It might appear to the user as:

- a window
- a tab
- a split pane

But `Surface` itself does not care which one it is. It is the core terminal
widget: a place that can receive input and display terminal output.

Ghostty says this clearly at the top of
[Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:1).

## 5. Where is the first surface created?

The first ordinary surface creation stop is:

- [embedded.zig](/Users/waqas/code/ghostty_forked/src/apprt/embedded.zig:1541)
  `ghostty_surface_new`

This is important because it tells you:

- the first surface is created through the runtime API
- surface creation is normal app/runtime work
- we are still on the macOS main thread here

One useful thing you learned in debugging is that this stop may happen before
`Ghostty.App.appTick()`. That is not a bug. It just means the first surface is
being created directly from normal Swift app startup, not through the app
mailbox wakeup path.

## 6. What happens inside `Surface.init()`?

The heart of the session is understanding that `Surface.init()` does a lot of
setup before it spawns worker threads.

The two key stops are:

- [Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:549)
- [Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:654)

At a high level, Ghostty does this:

```text
create app mailbox handle
prepare renderer
create renderer mutex
prepare renderer thread object
prepare IO thread object
store main surface fields
create exec backend
create termio mailbox
initialize Termio
only then spawn renderer and IO threads
```

That order matters a lot.

Ghostty does **not** start the threads first and hope the rest of the state is
ready in time. It builds the important state first, then starts the threads.

## 7. What is `app_mailbox`?

At [Surface.zig:549](/Users/waqas/code/ghostty_forked/src/Surface.zig:549),
Ghostty creates:

```zig
const app_mailbox: App.Mailbox = .{ .rt_app = rt_app, .mailbox = &app.mailbox };
```

This is a handle for sending messages back to the app thread.

Simple meaning:

- some worker thread wants the app/runtime to do something
- it cannot safely touch app/UI state directly
- so it puts a message into the app mailbox
- the app thread wakes up and handles it

The app mailbox exists because Ghostty is multi-threaded.

It solves this problem:

> How do background threads ask the app/runtime to do work safely?

It is **not**:

- the PTY
- the shell
- the renderer
- the terminal screen itself

## 8. What is shared renderer state?

Also around [Surface.zig:549](/Users/waqas/code/ghostty_forked/src/Surface.zig:549),
Ghostty prepares renderer-facing shared state. The important field is:

- [renderer/State.zig](/Users/waqas/code/ghostty_forked/src/renderer/State.zig:10)

This state contains:

- a mutex
- a pointer to the `Terminal`
- some extra render-relevant state

Why needed?

Because two sides need the same terminal data:

- one side updates terminal state when output arrives
- the other side reads terminal state to draw pixels

Without coordination, those two sides could race.

So Ghostty uses a mutex:

- output side locks, updates terminal state
- renderer locks, copies what it needs, unlocks, then draws

That is the shared handoff between terminal logic and rendering.

## 9. What are `Exec` and `Termio`?

At [Surface.zig:654](/Users/waqas/code/ghostty_forked/src/Surface.zig:654),
Ghostty finishes installing the surface's I/O system.

Two names matter here:

### `Exec`

`Exec` is the backend that manages a subprocess and PTY.

Simple version:

- starts the shell
- manages the PTY
- writes input toward the shell
- starts the PTY read thread

See:

- [Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:1)

### `Termio`

`Termio` is the coordinator for terminal I/O.

Simple version:

- owns the logical `Terminal`
- owns the backend (`Exec` here)
- owns the mailbox used by the IO thread
- parses child output
- wakes the renderer when terminal state changes

See:

- [termio.zig](/Users/waqas/code/ghostty_forked/src/termio.zig:1)
- [Termio.zig](/Users/waqas/code/ghostty_forked/src/termio/Termio.zig:1)

Very short summary:

- `Exec` talks to the shell
- `Termio` talks to Ghostty's terminal machinery

## 10. When do the threads actually start?

Only after the setup above.

The spawn points are:

- renderer thread:
  [Surface.zig:700](/Users/waqas/code/ghostty_forked/src/Surface.zig:700)
- IO thread:
  [Surface.zig:708](/Users/waqas/code/ghostty_forked/src/Surface.zig:708)

This is one of the main lessons of `s0`:

> Ghostty wires the surface first, then starts the worker threads.

## 11. Which threads does one normal exec-backed surface have?

A normal exec-backed surface ends up with three important worker threads:

1. renderer thread
2. IO thread
3. PTY read thread

The first two are started directly by `Surface.init()`.

The third is started later by the exec backend in:

- [Exec.zig:137](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:137)

This is why it is important not to confuse:

- the IO thread
- the PTY read thread

They are different.

## 12. What does each thread do?

### App thread

The app thread is the macOS main thread.

It is responsible for:

- app lifecycle
- UI/runtime work
- creating the first surface
- handling app-thread mailbox work

### Renderer thread

The renderer thread is responsible for:

- waking up when rendering is needed
- reading terminal state safely
- drawing the frame

In your debugging session, you stopped at:

- [renderer/Thread.zig:243](/Users/waqas/code/ghostty_forked/src/renderer/Thread.zig:243)

That line sends the renderer's first wakeup:

```zig
try self.wakeup.notify();
```

This means the renderer gives itself an initial "go render now" signal during
startup.

### IO thread

The IO thread is responsible for:

- draining the termio mailbox
- handling resize, writes, focus, and similar messages
- running backend startup logic

In your debugging session, you saw the IO thread enter:

- `Termio.threadEnter`
- `Backend.threadEnter`
- `Exec.threadEnter`

That is the path where backend-specific startup begins.

### PTY read thread

The PTY read thread is responsible for:

- reading bytes from the child process PTY
- forwarding those bytes into `Termio.processOutput`

This is a dedicated read-side thread created by `Exec`.

## 13. A concrete startup story

Here is the startup story in plain English.

### Step 1

Ghostty's macOS app code starts in `main.swift`.

### Step 2

It performs global Ghostty initialization, then hands control to AppKit.

### Step 3

AppKit runs the app delegate and window startup logic.

### Step 4

Swift UI/runtime code decides to create the first terminal surface.

### Step 5

That reaches `ghostty_surface_new`, then `Surface.init`.

### Step 6

`Surface.init` prepares:

- app mailbox handle
- renderer object
- renderer shared state and mutex
- renderer thread object
- IO thread object
- exec backend
- termio mailbox
- termio coordinator

### Step 7

Only after that does it spawn:

- renderer thread
- IO thread

### Step 8

The renderer thread starts and immediately gives itself an initial wakeup so it
can render the first frame.

### Step 9

The IO thread starts and enters backend startup.

### Step 10

Because the backend is `Exec`, backend startup spawns one more thread:

- the PTY read thread (`io-reader`)

That is the full thread picture for one ordinary exec-backed surface.

## 14. If I type `ls`, where do these pieces matter?

This is slightly beyond pure startup, but it helps make the pieces concrete.

If you type `ls`:

1. the surface receives the key event
2. the input is encoded into bytes
3. those bytes go through `Termio`
4. `Exec` writes them to the PTY
5. the shell reads them and runs `ls`
6. output bytes come back through the PTY
7. the PTY read thread reads those bytes
8. `Termio.processOutput` updates the logical terminal
9. shared renderer state now reflects the new terminal contents
10. renderer wakes and draws the result

In that story:

- `Exec` is the subprocess/PTTY side
- `Termio` is the terminal-I/O coordination side
- shared renderer state is the handoff to rendering
- app mailbox is usually not the main player for ordinary `ls` output

## 15. Why this matters for future tmux work

Even though `s0` is not a tmux session, it teaches the boundaries that tmux
work must respect.

Most importantly:

- app-thread work must stay on the app thread
- renderer work must go through shared renderer state
- backend-specific subprocess/PTY behavior lives below `Surface`
- one surface is already a multi-threaded object with clear responsibilities

That means future tmux work should not start by breaking these boundaries. It
should start by understanding them.

## Q&A

### Q1. Is `main.swift` the app thread?

Not exactly. `main.swift` is early code running on the macOS main thread. The
real idea is: the app thread is the macOS main thread, and `main.swift` is one
of the first user-code files executed on it.

### Q2. Why did `ghostty_surface_new` fire before `appTick()`?

Because the first surface can be created directly from ordinary Swift app
startup code. `appTick()` is the mailbox/wakeup path, not the only path into
Ghostty code.

### Q3. Why does Ghostty need both an IO thread and a PTY read thread?

Because they do different jobs.

- IO thread handles Ghostty-side mailbox and backend coordination
- PTY read thread does the read loop for child output

### Q4. Why is `renderer_state` shared?

Because one side updates terminal state and another side renders it. They need
a safe shared handoff.

### Q5. Is `Exec` the terminal?

No.

- `Exec` is the backend for subprocess + PTY
- the `Terminal` is the logical screen state
- `Termio` coordinates between backend bytes and terminal state

### Q6. If tmux work comes later, why should I care about `s0`?

Because tmux integration still has to fit into Ghostty's existing threading,
surface, renderer, and backend structure. If you skip `s0`, later tmux
sessions become much harder to reason about.
