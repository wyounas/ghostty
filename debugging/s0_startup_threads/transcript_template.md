# S0 Transcript

Date: 2026-04-28

Build used: `macos/build/Debug/Ghostty.app`

## Stop-by-stop notes

- `main.swift:8`
- `AppDelegate.swift:164`
- `AppDelegate.swift:203`
- `embedded.zig:1541`
- `Surface.zig:549`
- `Surface.zig:654`
- `Surface.zig:700`
- `Surface.zig:708`
- `renderer/Thread.zig:243`
- `Exec.zig:137`
- optional later stop: `Ghostty.App.swift:116`

## Answers to success criteria

1. On macOS, where is the real app thread?

The real app thread is the macOS main thread.

Important distinction:

- `main.swift:8` is the first practical Ghostty startup line
- but it is not a different "main app thread"
- it is early app code running on the macOS main thread

The main-thread startup path is roughly:

`main.swift -> NSApplicationMain -> AppDelegate.init -> applicationDidFinishLaunching -> Swift UI/runtime setup -> ghostty_surface_new -> Surface.init`

`Ghostty.App.appTick()` is also main-thread work, but it is the wakeup/mailbox
path, not the only way startup reaches Ghostty code.

2. What is the first practical startup line of Ghostty's own macOS app code?

`macos/Sources/App/macOS/main.swift:8`, the call to `ghostty_init(...)`.

After that:

- `main.swift:31` runs `ghostty_cli_try_action()`
- `main.swift:33` calls `NSApplicationMain(...)`

So `main.swift:8` is the best "starting point" breakpoint for this session.

3. Which parts of `Surface.init()` run before any child threads exist?

Before any child threads are spawned, `Surface.init()` does all of these:

- creates `app_mailbox`
- prepares `renderer_impl`
- allocates the renderer mutex
- creates the renderer thread manager object
- creates the IO thread manager object
- assigns the main `self.*` surface fields
- chooses the command to run
- builds the exec backend object with `Exec.init`
- creates the termio mailbox
- calls `Termio.init`
- performs initial size-related setup

Only after that does it spawn:

- renderer thread at `Surface.zig:700`
- IO thread at `Surface.zig:708`

So the important idea is: Ghostty wires the surface state first, then starts
the worker threads.

4. Which threads does a normal exec-backed surface create?

A normal exec-backed surface ends up with three important worker threads:

- one renderer thread
- one IO thread
- one extra PTY read thread

The first two are spawned directly by `Surface.init`.
The extra PTY read thread is spawned later by the exec backend inside
`Exec.threadEnter`.

5. Where does the first renderer wakeup come from?

The first renderer wakeup comes from the renderer thread itself.

In `src/renderer/Thread.zig`, inside renderer thread startup, Ghostty calls:

- `self.wakeup.notify()`

right after setting up the renderer thread's wait handlers.

So the first renderer wakeup is not sent by the app thread. It is sent from
inside the renderer thread's own startup code so the first frame can render
immediately.

## Review of the earlier rough answers

- The earlier answer mixed up "the macOS main thread" with "the first file that
  runs." Those are related, but not the same thing.
- The earlier answer listed only the PTY read thread for an exec-backed
  surface. That was incomplete. The renderer thread and IO thread are also part
  of the normal surface.
- The earlier answer about first renderer wakeup was too vague. The precise
  answer is the renderer thread's own `self.wakeup.notify()` during startup.
- The earlier PTY-read-thread line number was off. In the current code, the
  read thread is spawned at `Exec.zig:137`, and its read-loop entrypoint begins
  at `Exec.zig:1247`.

## Remaining confusions answered

### 1. What do shared renderer state and app-mailbox do at `Surface.zig:549`?

`app_mailbox` is the surface's way to send messages to the app thread.

Simple picture:

- some worker thread wants the app/runtime to do something
- it cannot safely touch app/UI state directly
- so it sends a message to the app mailbox
- the app thread wakes up and handles it

Why needed:

- macOS UI work must happen on the app thread
- Ghostty has many worker threads
- the mailbox is the safe bridge back to the app/runtime side

What problem it solves:

- "how do background threads ask the app/runtime to do UI work safely?"

What it is not:

- it is not the PTY
- it is not the shell
- it is not the renderer thread
- it is not the terminal screen buffer

`renderer_state` is the shared state between the code that updates terminal
content and the code that draws it.

Simple picture:

- terminal output changes the terminal state
- renderer reads that state and draws pixels
- both must not touch the same state at the same time without coordination

So `renderer_state` contains:

- a mutex
- a pointer to the `Terminal`
- a few extra render-relevant pieces of state

Why needed:

- one thread updates terminal content
- another thread renders
- they need a safe shared handoff

What problem it solves:

- "how can the renderer see the latest terminal contents without racing with
  the code that is updating them?"

What a tmux developer should know:

- tmux work must respect this boundary
- if tmux changes terminal-visible content, that content still has to reach the
  renderer through normal shared renderer state
- if tmux wants Ghostty to create or destroy surfaces, that must go through an
  app-thread message path, not by touching UI state from a worker thread

If you type `ls` in Ghostty:

- input eventually becomes a write request
- shell produces output
- `Termio.processOutput` updates terminal state under the renderer mutex
- renderer thread wakes and reads that shared state
- app mailbox is usually not involved in the ordinary `ls` output path

So:

- `renderer_state` is directly involved in showing the result of `ls`
- `app_mailbox` is more about app/runtime coordination than ordinary shell I/O

### 2. Why are `Exec` and `Termio` installed into the surface at `Surface.zig:654`?

`Exec` is the backend that runs a child process attached to a PTY.

Very simple view:

- `Exec` starts the shell
- `Exec` owns the PTY-side process plumbing
- `Exec` writes your input toward the shell
- `Exec` starts the extra read thread that reads shell output back

`Termio` is the coordinator for terminal I/O.

Very simple view:

- `Termio` owns the logical `Terminal`
- `Termio` owns the backend (`Exec` here)
- `Termio` owns the input/output message path
- `Termio` feeds output bytes into the terminal parser
- `Termio` wakes the renderer when terminal state changes

Why install them into the surface:

- a surface needs some source of terminal bytes
- it also needs the logic that turns those bytes into terminal state
- `Exec` provides the "where bytes come from/go to"
- `Termio` provides the "how Ghostty handles those bytes"

What problems they solve:

- `Exec` solves subprocess + PTY management
- `Termio` solves terminal-I/O coordination and terminal-state updates

What they are not:

- `Exec` is not the renderer
- `Exec` is not the `Terminal`
- `Termio` is not just a dumb pipe; it also owns the logical terminal and parser

What a tmux developer should know:

- today the surface is exec-backed
- tmux integration will likely change the backend story, not the need for a
  surface, renderer thread, IO coordination, and terminal state
- that is why the `Surface` / `Backend` split matters

If you type `ls` in Ghostty:

1. key event reaches `Surface.keyCallback`
2. Ghostty encodes bytes for `l`, `s`, and Enter
3. those bytes are sent to `Termio`
4. `Termio` passes the write to the `Exec` backend
5. `Exec` writes the bytes to the PTY
6. shell reads them and runs `ls`
7. shell output comes back through the PTY
8. exec read thread reads those bytes
9. `Termio.processOutput` parses them and updates the `Terminal`
10. renderer wakes and draws the result

So the shortest summary is:

- `Exec` talks to the shell
- `Termio` talks to Ghostty's terminal machinery

## Remaining confusion after these corrections

- Above you said "A normal exec-backed surface ends up with three important worker threads:

- one renderer thread
- one IO thread
- one extra PTY read thread"

can you please explain the role of above and how do these work if I type 'ls' in Ghostty and what work do they perform? 

Answer:

Yes. The easiest way to understand the three threads is to give each one one
job.

### Renderer thread

Role:

- reads terminal state
- prepares a frame
- draws pixels to the screen

What it does not do:

- it does not talk to the shell directly
- it does not read the PTY
- it does not decide terminal semantics like how `ls` output changes the screen

If you type `ls`:

- the renderer thread mostly waits at first
- later, after terminal state changes, it wakes up
- it reads the latest terminal contents
- it renders the prompt, typed text, and then the `ls` output

So the renderer thread's job is: **show the result**.

### IO thread

Role:

- receives Ghostty-side messages through the termio mailbox
- handles writes, resize, focus, config changes, and backend startup

What it does not do:

- it is not the thread that continuously reads shell output bytes from the PTY
- it is not the renderer

If you type `ls`:

1. `Surface.keyCallback` encodes your keystrokes
2. Ghostty sends a write message to `Termio`
3. the IO thread wakes up and drains that mailbox message
4. it calls into the backend write path
5. the backend sends the bytes toward the shell

So the IO thread's job is: **handle Ghostty's side of outgoing requests and
control messages**.

### PTY read thread

Role:

- sits in the read loop on the PTY
- reads output bytes coming back from the shell
- forwards those bytes into `Termio.processOutput`

What it does not do:

- it does not render
- it does not manage app-thread UI work
- it does not handle the write mailbox logic

If you type `ls`:

1. shell receives `ls` and Enter
2. shell runs `ls`
3. shell writes output bytes to the PTY
4. the PTY read thread reads those bytes
5. it passes them into `Termio.processOutput`
6. terminal state changes
7. renderer later wakes and draws the result

So the PTY read thread's job is: **bring shell output back into Ghostty**.

### The full `ls` story across the three threads

Very short version:

1. app/main thread:
   input event reaches Ghostty
2. IO thread:
   outgoing write message is handled and sent to the shell
3. PTY read thread:
   shell output is read back into Ghostty
4. renderer thread:
   updated terminal state is drawn

So the clean mental model is:

- IO thread: send work out
- PTY read thread: bring output back
- renderer thread: show the result
