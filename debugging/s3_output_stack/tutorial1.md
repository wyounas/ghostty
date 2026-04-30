# Tutorial 1: Proving That tmux Owns the Real Pane Subprocesses and PTYs

This note answers a very specific question:

> How can I convince myself, with evidence, that in tmux control mode the real
> pane subprocesses and PTYs are already owned by tmux, so a future tmux-backed
> Ghostty pane surface may not need its own subprocess and PTY?

The answer has three parts:

1. first-principles reasoning
2. code evidence from Ghostty
3. a small walkthrough you can run in iTerm and tmux yourself

## 1. First principles

Start with the ordinary Ghostty case.

### Ordinary exec-backed terminal

One Ghostty surface owns:

- one child subprocess
- one PTY pair
- one write path to the PTY master
- one read path from the PTY master

That is exactly what the `exec` backend does.

Now compare that to tmux.

### tmux is already a terminal multiplexer

A tmux server already manages:

- sessions
- windows
- panes
- the shell or program running in each pane
- the PTY attached to each pane

So when a control-mode client connects to tmux, that client is not creating the
real pane subprocesses. It is observing and controlling pane state that tmux
already owns.

That is the core logic.

If Ghostty later creates a child surface that visually represents tmux pane `%3`,
then there are two possibilities:

1. launch a brand new subprocess and PTY for that child surface
2. treat the child surface as a viewer/editor for the pane tmux already owns

Option 1 would create a duplicate execution world. That is wrong for tmux panes.
Option 2 matches what tmux control mode actually is.

So the first-principles conclusion is:

- tmux pane child surfaces probably should not each launch their own subprocess
  and PTY
- instead, they should receive pane data from tmux and send pane-directed input
  back through tmux

## 2. Evidence from Ghostty code

### 2.1 Ordinary exec really does own subprocess + PTY

Ghostty's current backend abstraction says this directly:

- [backend.zig](/Users/waqas/code/ghostty_forked/src/termio/backend.zig:21)
  says a backend is responsible for owning PTY behavior and read/write
  capabilities

The only backend kind on `main` is:

- [backend.zig](/Users/waqas/code/ghostty_forked/src/termio/backend.zig:13)
  `pub const Kind = enum { exec };`

And `Exec` explicitly says what it owns:

- [Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:1)
  `Exec implements the logic for starting and stopping a subprocess with a pty`

More concrete proof:

- [Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:91)
  starts the subprocess
- [Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:128)
  creates the write stream from the PTY master write fd
- [Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:137)
  starts the dedicated PTY read thread
- [Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:985)
  connects child stdin/stdout/stderr to the PTY slave
- [Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:999)
  stores PTY master fds as the Ghostty-side read/write endpoints

The key lines are:

- child side:
  [Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:985)
  to [Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:987)
- Ghostty side:
  [Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:999)
  to [Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:1000)

That is strong evidence for the ordinary model:

```text
Ghostty exec backend owns:
  subprocess + PTY slave hookup + PTY master read/write
```

### 2.2 Termio is generic enough that it does not require a PTY forever

This is the next important clue:

- [Termio.zig](/Users/waqas/code/ghostty_forked/src/termio/Termio.zig:2)
  says `Termio` is flexible enough to be used in environments that do not have
  a PTY and can provide input/output using raw interfaces

That line matters a lot.

It means the architecture was not designed to mean:

> terminal state is only possible if Ghostty personally owns a PTY

Instead it means:

> `Termio` wants bytes in and bytes out, and the backend decides where those
> bytes come from

That is exactly the architectural opening a tmux-backed surface would use.

### 2.3 tmux control mode already treats tmux as the source of pane data

Ghostty's tmux parser says this:

- [control.zig](/Users/waqas/code/ghostty_forked/src/terminal/tmux/control.zig:13)
  describes the parser as taking input from a tmux control-mode session

And `Viewer` says what it is trying to build:

- [viewer.zig](/Users/waqas/code/ghostty_forked/src/terminal/tmux/viewer.zig:43)
  says a viewer is a tmux control-mode client that attempts to create
  Ghostty-native windows/tabs/splits from tmux state

That is not the language of:

> create fresh subprocesses and PTYs for each pane

It is the language of:

> observe tmux state and mirror it in Ghostty UI

### 2.4 `Viewer` already builds per-pane terminal state from tmux data

The current `main` branch already proves a lot of this shape.

The debugging architecture docs summarize it:

- [debugging/architecture.md](/Users/waqas/code/ghostty_forked/debugging/architecture.md:284)
  says by the time `.windows` is emitted, the `Viewer` already knows a lot
  about tmux windows and panes

And the `s7` session docs state:

- [debugging/s7_tmux_windows_handoff/README.md](/Users/waqas/code/ghostty_forked/debugging/s7_tmux_windows_handoff/README.md:67)
  `initLayout` creates or reuses per-pane `Terminal` state inside the `Viewer`

That is exactly the direction you would expect if tmux is the owner of pane
reality and Ghostty is mirroring it.

## 3. Do the tmux control-mode docs say anything about this?

Yes, indirectly and strongly.

There are two kinds of evidence:

1. Ghostty/tmux-MVP design docs
2. tmux's own control-mode and format documentation

### 3.1 tmux's own docs

tmux's control-mode docs say that control mode is a text protocol between a
client and tmux, and that pane output is reported to the control client as
`%output %pane ...`.

The most important sentence is this one:

- tmux says the `%output` payload is the output the application running in the
  pane sent to tmux

That is strong evidence for the ownership model:

- application runs inside pane
- tmux receives that pane output
- control-mode client receives it from tmux

Official references:

- tmux control-mode wiki:
  https://github.com/tmux/tmux/wiki/Control-Mode
- tmux man page:
  https://man.archlinux.org/man/tmux.1.en

tmux's format docs also give two useful variables:

- `pane_pid` = PID of first process in pane
- `pane_tty` = pseudo terminal of pane

Those variables matter because they let you ask tmux directly:

- what process do you think lives in this pane?
- what tty do you think belongs to this pane?

Official format reference:

- tmux formats wiki:
  https://github.com/tmux/tmux/wiki/Formats

### 3.2 tmux-MVP design material

The `tmux_mvp` design docs are not loaded on this branch, but they were written
to explain the architecture. They support the same mental model.

The clearest evidence is the reference dataflow description:

- the control-mode client starts `tmux -CC`
- the tmux client connects to the tmux server
- the tmux server already owns the session
- shell output is reported back to the client as `%output %pane ...`

That is exactly the model shown in the old `tmux_mvp` `dataflow.md` diagram:

- shell runs inside tmux pane
- tmux captures pane output
- tmux sends `%output` notifications to the control-mode client

That is not "client owns the pane PTY."
That is "tmux owns the pane PTY; client receives pane updates."

The `tmux_mvp` backend/surface docs also push the same idea:

- ordinary exec-backed surfaces own subprocess + PTY
- future tmux child surfaces likely should not each repeat that ownership

So yes: the tmux control-mode design material does support this mental model.

## 4. A simple iTerm + tmux walkthrough you can run yourself

This walkthrough is not about Ghostty code. It is about proving the Unix/tmux
ownership model to yourself.

Use two iTerm windows:

- **Window A**: where you run tmux
- **Window B**: where you inspect processes and pane metadata

Use a fresh tmux server name so you do not mix with your normal tmux session.

Before starting, clean up any old server with that name:

```bash
tmux -L prove -f /dev/null kill-server 2>/dev/null || true
```

### Step 1: Start a fresh tmux server and session in detached mode

In **Window A**:

```bash
tmux -L prove -f /dev/null new-session -d -s demo
```

This is important.

We are deliberately starting the session **without attaching a client first**.
That gives stronger evidence:

- tmux server can own the pane world before any UI client is attached

### Step 2: Create a second pane while still detached

In **Window A**:

```bash
tmux -L prove -f /dev/null split-window -h -d -t demo:0
```

Now tmux should have two panes even though no interactive client is attached.

### Step 3: Prove tmux already knows the panes, their processes, and their TTYs

```bash
tmux -L prove list-panes -a -F 'pane=#{pane_id} pid=#{pane_pid} tty=#{pane_tty} cmd=#{pane_start_command}'
```

You should see output like:

```text
pane=%0 pid=12345 tty=/dev/ttys012 cmd=/bin/zsh
pane=%1 pid=12378 tty=/dev/ttys013 cmd=/bin/zsh
```

What this means:

- tmux knows the process id for each pane
- tmux knows the tty for each pane
- tmux knows the command that started each pane
- each pane already has a real process and a real tty attached to it

That is your first strong piece of evidence, and notice:

- you have not attached an ordinary UI client yet
- you have not attached a control-mode client yet
- but tmux already owns pane process/tty state

### Very important clarification: what does `pane_tty` mean?

Here, `tty` does **not** mean "the PTY master that a GUI terminal emulator
owns."

It means:

- the pane's terminal device on the process side
- in practice, the terminal endpoint that the pane's shell/program is attached
  to

Simple model:

```text
ordinary PTY pair

terminal emulator / controller side  <->  process side
PTY master                           PTY slave / tty device
```

So if tmux shows:

```text
pane=%0 tty=/dev/ttys012
```

that is evidence for:

- "this pane already has a real terminal endpoint"
- "the pane process is attached to a real tty device"

and it is **not** evidence for:

- "Ghostty or iTerm owns the PTY master for this pane"

That distinction matters a lot.

In ordinary Ghostty `exec`:

- Ghostty uses the PTY master
- the child shell gets the PTY slave as its stdin/stdout/stderr

You can see that in Ghostty's exec code:

- [Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:985)
  to [Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:987)
  connect child stdin/stdout/stderr to `pty.slave`
- [Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:999)
  to [Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:1000)
  store the Ghostty-side read/write endpoints from `pty.master`

So `pane_tty` proves:

- tmux already knows the process-side terminal endpoint for the pane

It does **not** by itself prove:

- who owns the corresponding master side

But for the ownership argument in this tutorial, that is already enough:

- the pane is a real terminal/process world that exists inside tmux before a
  control-mode client attaches

### Step 4: Prove there may be no client attached yet

In **Window B**:

```bash
tmux -L prove list-clients -F 'client=#{client_name} pid=#{client_pid} tty=#{client_tty}'
```

It is fine if this prints nothing.

That is useful evidence too:

- tmux can have a living session and pane world even with zero attached clients

### Step 5: Inspect one pane process directly

Still in **Window B**, pick one `pane_pid` from the previous command and run:

```bash
ps -o pid,ppid,tty,stat,command -p <pane_pid>
```

For example:

```bash
ps -o pid,ppid,tty,stat,command -p 12345
```

In the default case, you will usually see that this process is your shell, and
its TTY matches `#{pane_tty}`.

But do not overclaim here:

- `pane_pid` is tmux's "PID of the first process in the pane"
- in a normal fresh pane that is commonly the shell
- later, depending on what is running, the foreground program may be something
  else, or the process tree may be more complicated than "just the shell"

This proves:

- tmux is tracking a real process for the pane
- that process is attached to the pane tty
- the pane tty is not an imaginary UI concept; it is a real terminal endpoint

One small precision point:

- tmux documents `pane_pid` as the **first process in the pane**
- in a normal shell-based pane this is usually the shell
- the exact program may vary later, but the important point is that tmux is
  tracking a real pane-owned process and real pane-owned tty

### Step 6: Inspect the tmux server process

Still in **Window B**:

```bash
ps -o pid,ppid,tty,command -A | grep '[t]mux -L prove'
```

You will see the tmux server and possibly the client.

The important conceptual point is:

- tmux server is the thing coordinating these panes
- the pane processes are part of tmux's session world, not something your GUI
  terminal creates separately for each pane when attaching to control mode

### Step 7: Attach an ordinary client, then detach again

In **Window A**:

```bash
tmux -L prove attach -t demo
```

You should now see the session normally.

Then detach with tmux's normal detach keystroke:

```text
Ctrl-b d
```

If you prefer a command form, this usually also works from inside the pane
shell because tmux exposes the current client/session through the `TMUX`
environment:

```bash
tmux detach-client
```

Now in **Window B** run again:

```bash
tmux -L prove list-panes -a -F 'pane=#{pane_id} pid=#{pane_pid} tty=#{pane_tty} cmd=#{pane_start_command}'
```

If the tmux server is still alive, you will still see the panes and their
processes.

That is very important evidence:

- the panes keep existing even after the UI client detaches
- therefore the UI client is not the owner of those shell subprocesses

### Step 8: Reattach in control mode

Now use iTerm's tmux control mode idea directly.

In **Window A**:

```bash
tmux -CC -L prove attach -t demo
```

You are now attached in control mode.

The crucial conceptual question is:

> did tmux create brand new pane shells and brand new pane ttys just because a
> control-mode client attached?

Now prove the answer.

### Step 9: Compare pane process ids and TTYs again

In **Window B**:

```bash
tmux -L prove list-panes -a -F 'pane=#{pane_id} pid=#{pane_pid} tty=#{pane_tty} cmd=#{pane_start_command}'
```

Look at the pane ids, pids, and tty names.

You should find that:

- the panes already existed before control-mode attach
- control-mode attach did not invent a second set of pane subprocesses

This is the clearest practical evidence for the claim:

> tmux already owns the real pane subprocesses and ttys

The control-mode client is attaching to tmux's existing world, not creating its
own separate shell-per-pane world.

What this means for your mental model:

- tmux is not just storing layout metadata
- tmux is coordinating real per-pane process/tty state
- a control-mode client attaches to that already-existing world
- so a future Ghostty tmux-pane surface does not obviously need to create a
  second subprocess/PTy pair of its own

### Step 10: Prove the control-mode client is a client, not the pane owner

In **Window B**:

```bash
tmux -L prove list-clients -F 'client=#{client_name} pid=#{client_pid} tty=#{client_tty} session=#{session_name}'
```

You should now see a client entry.

That matters because it separates two concepts:

- tmux pane process/tty ownership
- tmux client attachment

The control-mode UI is a client attached to tmux's world. It is not the thing
that created the pane shells.

### Step 11: Type in one pane and observe that tmux still knows which pane owns it

While attached in control mode, run a simple command in one pane such as:

```bash
echo hello from pane
```

Then in **Window B**:

```bash
tmux -L prove capture-pane -p -t %0
```

or replace `%0` with the pane you used.

This shows that tmux can provide the pane contents on demand.

That matters because it reinforces the mental model:

- pane output lives in tmux's world
- a control-mode client can ask for it or receive it as notifications
- the client does not need to own a new subprocess/PTy to see that pane

Why that last point is true, from first principles:

- a subprocess produces bytes
- those bytes go to some terminal endpoint
- whoever already owns that terminal/process path can read those bytes and
  report them

In ordinary Ghostty, Ghostty owns the subprocess and PTY, so Ghostty must read
the PTY master itself to see the output.

In tmux control mode, tmux already owns the pane's process/terminal world and
already receives the pane's output. The control-mode client can then learn the
pane content because tmux relays it:

- live, through notifications like `%output`
- or on demand, through commands like `capture-pane`

So the client does not need a **second** subprocess/PTy pair just to "see the
pane." It can see the pane because tmux is already supplying the pane's content.

If the client created another subprocess/PTy pair, that would not be the same
pane. It would be a brand new shell/process world.

### Step 12: Optional extra proof from tmux's control protocol

If you want to connect the ownership proof to the actual control-mode protocol,
read tmux's own control-mode documentation:

- it says pane output is sent to the control client as `%output %pane ...`
- and that output is what the application in the pane sent to tmux

That is the protocol-level version of the same argument:

- pane application writes
- tmux receives it
- control-mode client is informed about it

In iTerm you usually see native UI instead of the raw `%output` lines, so the
official docs are the clearest place to confirm the protocol wording.

## 5. What this proves and what it does not prove

This walkthrough proves:

- tmux can create and maintain pane process/tty state before any client is
  attached
- pane shells and pane ttys already exist inside tmux's session world
- those pane processes survive client detach/reattach
- control-mode attach is attaching to an already-owned world

This walkthrough does **not** by itself prove:

- the exact future Ghostty `.tmux` backend API
- the exact per-pane write/read method a future Ghostty child surface should use

But it gives you the key first-principles evidence:

> if tmux already owns the real pane subprocesses and ttys, then a tmux-backed
> Ghostty pane surface should at least be suspected of not needing its own fresh
> subprocess and PTY

## 6. The simple conclusion

The safest mental model is:

- ordinary Ghostty surface:
  "I own the subprocess and PTY"
- future tmux pane surface:
  "tmux owns the real subprocess and PTY; I consume pane data and send pane
  input through tmux"

That is why people talk about a new backend, possibly one without its own
subprocess/PTY for each tmux pane child surface.

## 7. Cleanup

This tutorial used a separate tmux server name, `prove`, specifically so you
can clean it up without touching your normal tmux setup.

When you are done, run:

```bash
tmux -L prove -f /dev/null kill-server
```

That removes the temporary tmux session/server created by this walkthrough.
