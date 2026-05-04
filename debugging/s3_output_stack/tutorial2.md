# Tutorial 2: How `ls` Flows in Ghostty tmux Control Mode

This note answers one precise question:

> If Ghostty is integrated with tmux control mode, and I type `ls` then Enter in
> a tmux pane, how do the bytes flow from Ghostty to the real shell, and why does
> the tmux pane backend not need its own PTY?

If you remember only one sentence, remember this:

> In tmux control mode, Ghostty should still own one PTY to the `tmux -CC`
> client, but each tmux pane surface should not need a second PTY of its own.

That distinction is the whole design.

## 1. Start from first principles

### 1.1 Ordinary Ghostty

In ordinary Ghostty, one surface owns one subprocess and one PTY pair.

```text
keyboard -> Ghostty Surface -> PTY master -> shell
shell output -> PTY slave -> PTY master -> Ghostty Surface -> screen
```

More carefully:

- Ghostty writes your keystrokes to the PTY master.
- The shell is attached to the PTY slave as its `stdin/stdout/stderr`.
- The shell's output comes back through that same PTY pair.
- Ghostty reads those bytes, parses them, updates terminal state, and renders.

That is exactly what the `exec` backend does today.

### 1.2 tmux control mode

tmux control mode changes the ownership picture.

There are now two different "worlds":

1. the **tmux control connection**
2. the **real tmux panes**

The control connection is one stream between Ghostty and the `tmux -CC` client.
The real panes are managed by the tmux server.

So the correct mental model is:

```text
Ghostty source surface <-> tmux client <-> tmux server <-> pane shell
```

The tmux server already owns:

- the real pane shell process
- the real pane terminal device
- the pane layout and pane IDs

So a Ghostty child surface for pane `%3` should be thought of as:

- a viewer/controller for tmux pane `%3`
- not a fresh shell/PTy world

## 2. Who talks to whom?

This is the most important ownership table.

| Component | Talks directly to | Does not talk directly to |
|----------|-------------------|---------------------------|
| Ghostty source surface | tmux client process | tmux server socket |
| tmux client process | tmux server | pane shell directly |
| tmux server | pane shell / pane tty | Ghostty child pane surface |
| Ghostty child tmux pane surface | Ghostty source/control side | pane shell directly |

So when you ask, "what in Ghostty talks to tmux client and tmux server?", the
careful answer is:

- Ghostty code talks **directly** to the **tmux client**.
- The **tmux client** talks to the **tmux server**.
- Ghostty does **not** directly speak the tmux server socket protocol in this MVP.

That is why the PTY, where it exists, belongs on the source surface that runs
`tmux -CC`.

## 3. What the code says

### 3.1 Ordinary exec-backed Ghostty really owns subprocess + PTY

On `main`, the backend kind is only `exec` in `src/termio/backend.zig`.

`src/termio/Exec.zig` shows the normal ownership model:

- the child process gets `pty.slave` as `stdin/stdout/stderr`
- Ghostty stores `pty.master` as its read/write side
- the exec backend starts a dedicated PTY read thread
- writes go through `Exec.queueWrite`

This is the normal terminal model.

### 3.2 The tmux MVP diff introduces a second backend kind

In the `tmux_mvp` diff:

- `src/termio/backend.zig` adds `Kind = enum { exec, tmux }`
- `src/Surface.zig` adds `InitBackend`
- `src/termio/Tmux.zig` is added as a new backend

This is the architectural signal that the design is no longer:

> every surface must own a subprocess PTY

It becomes:

> some surfaces are `exec` surfaces, and some surfaces are tmux-backed surfaces

### 3.3 The source surface still uses `exec`

In the `tmux_mvp` diff, the source surface is still ordinary:

- it launches `tmux -CC` through the normal `exec` backend
- it still owns the PTY to that tmux client process
- it still uses the normal exec read thread

This is crucial. The tmux integration does **not** remove PTYs from the system.
It changes **where** the PTY is needed.

### 3.4 The child tmux pane surface uses `.tmux`

In the same diff, `src/App.zig`, `src/apprt/embedded.zig`, and `src/Surface.zig`
show the new child-surface path:

- the app receives `.new_tmux_window`
- the runtime creates a new surface with `backend = .tmux`
- `Surface.init()` branches on `.exec` vs `.tmux_mvp`

This is the important split:

- source surface: `exec`
- child pane surface: `tmux`

### 3.5 The new `.tmux` backend does not create a PTY

Look at `src/termio/Tmux.zig` in the `tmux_mvp` branch.

It has:

- `initTerminal`
- `threadEnter`
- `threadExit`
- `focusGained`
- `resize`
- `queueWrite`

But notice what it does **not** do:

- it does not fork a subprocess
- it does not open a PTY
- it does not spawn a PTY read thread

Its `threadEnter()` only installs backend state. Its `queueWrite()` is currently
a stub. That is strong evidence for the intended design:

> the child tmux pane surface is not supposed to own a fresh subprocess/PTy pair

### 3.6 How bytes reach the child surface without a PTY

This is the cleanest proof in the diff.

The `tmux_mvp` branch adds:

- `src/terminal/tmux/viewer.zig`: new `Action.pane_snapshot`
- `src/termio/message.zig`: new `Message.process_output`
- `src/termio/Thread.zig`: `process_output` calls `io.processOutput(v.data)`
- `src/termio/stream_handler.zig`: `.pane_snapshot` stores data on the source
  surface and flushes it to the child surface

That means the child surface can receive terminal bytes like this:

```text
source surface gets pane bytes
-> source surface sends .process_output mailbox message
-> child IO thread drains that message
-> child Termio.processOutput(data)
-> child Terminal updates
-> child renderer draws
```

No PTY is involved in that child path.

That is the strongest code evidence for "tmux child backend does not need its own PTY."

What exactly does "source surface gets pane bytes" mean?

1. The real shell is running inside a tmux pane.
2. That shell writes output to the pane's terminal device.
3. The tmux server already owns that pane, so it sees that output.
4. In control mode, tmux reports pane content back to the control client:
   - live output as notifications like `%output %<pane> ...`
   - initial/queried content through command responses like `capture-pane`
5. The tmux client (`tmux -CC`) writes that control-mode stream to its own
   `stdout`.
6. In Ghostty, the source surface is an ordinary `exec` surface running that
   tmux client as a subprocess.
7. So Ghostty reads those bytes exactly the normal exec way:
   - tmux client `stdout` is connected to the PTY slave
   - Ghostty owns the PTY master
   - Ghostty's exec read thread reads from that PTY master
8. Those bytes then go through:
   - `Termio.processOutput`
   - VT parser
   - DCS handler
   - tmux control parser
   - `Viewer`

## 4. The full `ls` flow

There are two versions of this answer:

1. what the `tmux_mvp` branch already proves
2. the full intended steady-state flow once child input is finished

You need both.

### 4.1 What the current `tmux_mvp` branch already proves

The current MVP already proves:

- Ghostty can run `tmux -CC` on a source `exec` surface
- Ghostty can parse tmux control mode
- `Viewer` can discover windows and panes
- the app thread can create a child surface with backend `.tmux`
- pane snapshot bytes can be injected into that child surface through
  `.process_output`

But it does **not** yet prove full interactive child-surface input, because
`src/termio/Tmux.zig:queueWrite()` is still a stub.

So when you read the next section, read it as:

- **input path** = intended design
- **output side and no-PTY child path** = already strongly supported by the MVP diff

### 4.2 Sequence diagram

```text
User
  |
  | type "ls" Enter
  v
Ghostty child pane surface (.tmux backend)
  |
  | Surface.keyCallback -> encodeKey -> Termio.queueWrite
  v
Tmux backend for child pane
  |
  | CURRENT tmux_mvp: queueWrite is still a stub
  | INTENDED: turn bytes into pane-directed tmux command
  |           e.g. send-keys -t %3 l s Enter
  v
Ghostty source surface (.exec backend, owns PTY)
  |
  | writes command bytes to PTY master
  v
tmux client process (`tmux -CC`)
  |
  | talks over tmux socket/protocol
  v
tmux server
  |
  | injects keys into the real shell in pane %3
  v
pane shell
  |
  | runs `ls`, writes output to pane tty
  v
tmux server
  |
  | sends pane output back on control stream
  | as %output or capture-pane response
  v
tmux client stdout
  |
  | source exec read thread reads PTY master
  v
Ghostty source surface
  |
  | Termio.processOutput
  | -> VT parser
  | -> DCS handler
  | -> tmux control parser
  | -> Viewer
  v
Ghostty routes pane bytes to child pane surface
  |
  | .process_output -> child Termio.processOutput
  v
child Terminal state
  |
  | renderer wakeup
  v
child renderer
  |
  v
screen
```

## 5. The input path, step by step

### Step 1: You type in a Ghostty child pane surface

At the Ghostty surface level, input starts the usual way:

- `Surface.keyCallback`
- key encoding
- `queueIo`
- `Termio.queueWrite`

That part is not special yet.

### Step 2: The child backend must not write to a local PTY

This is the first big difference.

An ordinary `exec` surface writes those bytes to **its own** PTY master.
But a tmux child pane surface should not do that, because it does not own the
real pane shell.

If it created its own PTY and its own shell, that would not be "tmux pane `%3`".
That would be a completely new shell.

So the child `.tmux` backend must instead mean:

> "send these keys to tmux pane `%3`"

### Step 3: The child backend should turn bytes into a tmux command

From first principles, the correct action is something like:

```text
send-keys -t %3 l s Enter
```

The exact quoting/encoding details are an implementation detail.
The important point is the direction:

- not "write to local shell PTY"
- but "ask tmux to deliver these keys to pane `%3`"

### Step 4: Ghostty must send that command to the tmux client process

This is where the source surface matters.

The source surface is the one that owns:

- the `exec` backend
- the PTY
- the `tmux -CC` subprocess

So the source surface is the correct place to send control-mode commands.

In Ghostty's existing tmux control path, `Viewer` already emits `.command`
actions such as:

- `display-message`
- `list-windows`
- `capture-pane`

`src/termio/stream_handler.zig` already handles `.command` by calling
`messageWriter(...)`, which queues a write request. The IO side then reaches
`Exec.queueWrite`, which queues the PTY-master write.

So the existing code already proves the shape:

```text
Ghostty logic -> command text -> source exec backend -> PTY -> tmux client
```

 So Ghostty’s code path is:

  Surface.keyCallback
  -> queueIo(.write_*)
  -> IO thread drainMailbox
  -> Termio.queueWrite
  -> Exec.queueWrite
  -> Exec.queueWrtie queues bytes iinto exec.write_stream
  -> exec stream write on PTY master fd

  Why does that reach the tmux client?

  Because the child subprocess launched by the exec backend has its stdio attached
  to the PTY slave:

  .stdin = pty.slave,
  .stdout = pty.slave,
  .stderr = pty.slave,

  So:

  - Ghostty writes to the PTY master
  - the tmux client subprocess is on the PTY slave side
  - therefore the tmux client reads those bytes as its standard input

  That is the exact meaning of:

  > PTY -> tmux client

### Step 5: The tmux client talks to the tmux server

This is outside Ghostty code, but central to the design.

Ghostty does not directly inject keys into pane shells.

Instead:

- Ghostty writes command text to `tmux -CC`
- the tmux client sends that request to the tmux server
- the tmux server routes the keys to the real pane shell

That is why the PTY belongs on the source surface that runs the tmux client.

## 6. The output path, step by step

### Step 1: The real shell writes to the pane tty

When the shell in pane `%3` runs `ls`, its output goes to the pane's terminal
device inside tmux's world.

This is exactly why the earlier `pane_pid` / `pane_tty` walkthrough matters:
the pane already has a real process and a real tty under tmux.

### Step 2: The tmux server reports that output on the control stream

tmux control mode documentation says the client sends commands on `stdin` and
receives notifications on `stdout`. The important notification here is `%output`.

So the shell output comes back as tmux control-mode data, not as a direct read
from a child PTY owned by the pane surface.

### Step 3: The source surface reads that control stream

The source surface is still an ordinary exec-backed surface.

So the output path starts at the normal place:

- exec read thread reads bytes from the PTY master. After the exec read thread reads bytes from the PTY master, it calls Termio.processOutput directly, synchronously, on that same
  read thread.
- `Termio.processOutput`
- VT parser
- DCS detection for tmux control mode
- tmux control parser
- `Viewer`

That is the source-side input parser path.

How does `Termio.processOutput` reach the VT parser?

- `Termio.processOutput` locks `renderer_state.mutex`
- then calls `processOutputLocked(buf)`
- `processOutputLocked(buf)` calls:
  - `self.terminal_stream.nextSlice(buf)`
- `terminal_stream.nextSlice(buf)` is the important handoff: it feeds the byte
  slice into Ghostty's terminal parsing pipeline
- that pipeline runs the VT parser and dispatches the resulting actions through
  the stream handler

So the concise picture is:

```text
Termio.processOutput
-> processOutputLocked
-> terminal_stream.nextSlice(buf)
-> VT parser runs
-> handler mutates Terminal state
```

### Step 4: `Viewer` decides which pane the bytes belong to

This is the job of the tmux-aware layer.

The control-mode parser can tell:

- this is `%output`
- it belongs to pane `%3`

So now Ghostty knows which child pane surface should receive those bytes.

### Step 5: The child surface receives bytes through Ghostty, not through a PTY

This is the decisive design point.

In the MVP diff, Ghostty already added a path where **pane snapshot bytes** are
forwarded as data:

- `Viewer` emits `pane_snapshot`
- source `stream_handler` stores and flushes it
- the target child surface receives `.process_output`
- child IO thread calls `io.processOutput(data)`

That already proves the important transport point. The child surface can be fed
from Ghostty-owned bytes in memory, not from a child-owned PTY.

So for the child surface, the real source of truth is:

```text
Ghostty mailbox message carrying pane bytes
```

not:

```text
kernel PTY master fd for a child shell
```

For live `%output`, the exact child-surface routing is still an architectural
follow-up, but it should follow the same shape:

```text
source/control side receives pane bytes
-> Ghostty routes bytes to target child surface
-> child Termio.processOutput(data)
-> child Terminal updates
```

How does the target child surface actually receive `.process_output`?

- the source surface does not call the child parser stack inline
- instead, it enqueues a mailbox message into the child surface's `Termio`

The key source-side step is:

```text
target.io.queueMessage(.process_output, ...)
```

More concretely:

1. the source receives `pane_snapshot`
2. the source stores it as `pending_snapshot`
3. `tmuxMvpFlushPendingSnapshotLocked()` checks whether the child target surface
   pointer is ready
4. if it is ready, the source calls `target.io.queueMessage(...)` with
   `.process_output`
5. later, the child IO thread drains that mailbox message
6. in `termio/Thread.zig`, the `.process_output` arm calls:
   - `io.processOutput(v.data)`

So the child path is:

```text
source stores snapshot
-> source enqueues .process_output into child Termio mailbox
-> child IO thread drains mailbox
-> child Termio.processOutput(data)
-> child parser / Terminal / renderer path runs normally
```

One subtle but important detail:

- if the child surface is not ready yet, the source cannot flush immediately
- so the source keeps the bytes in `pending_snapshot`
- once the child becomes ready, Ghostty sends `.tmux_mvp_target_ready`
- then the source flushes that pending snapshot into the child mailbox

### Step 6: The child renderer draws from the child Terminal

Once the child surface has fed those bytes through `Termio.processOutput`,
everything becomes ordinary again:

- the child `Terminal` updates
- renderer is woken
- renderer draws the child surface

The renderer does not care where the bytes originally came from.

## 7. Why the child tmux backend does not need its own PTY

Now we can say the key point very plainly.

### 7.1 What a PTY is for

A PTY is needed when Ghostty itself is the thing directly connected to a child
process.

That is the ordinary `exec` case:

- Ghostty needs a write side for child input
- Ghostty needs a read side for child output
- the kernel PTY pair is the boundary between Ghostty and that child

### 7.2 Why that is different for a tmux pane surface

For a tmux pane surface, Ghostty is **not** directly attached to the real pane shell.

The real shell is already behind:

- tmux server
- tmux client
- source surface PTY

So a second PTY at the child pane surface would be solving the wrong problem.

It would create:

- a second boundary
- a second shell if you also launched a subprocess
- a second terminal world that is not the tmux pane

That is why "tmux child backend without its own PTY" is not a hack.
It is the natural result of the ownership model.

### 7.3 The child backend still has a job

"No PTY" does **not** mean "no backend."

The child `.tmux` backend still has real responsibilities:

- know which pane ID it represents
- receive pane bytes from the source/control side
- feed those bytes into the child `Terminal`
- eventually turn local keystrokes into pane-directed tmux commands
- eventually forward resize/focus information in tmux terms

So the correct sentence is:

> the tmux child backend does not need its own PTY, because the transport edge
> to the real shell already exists elsewhere

not:

> tmux integration has no backend responsibilities

## 8. Why this explanation is correct

It is supported by four different kinds of evidence.

### 8.1 tmux's own control-mode docs

tmux control mode says:

- commands go in on `stdin`
- notifications come out on `stdout`
- pane output is reported as `%output`

That already implies relay, not direct pane-PTY ownership by the UI client.

### 8.2 Ghostty's ordinary exec code

The ordinary `exec` backend explicitly owns:

- subprocess creation
- PTY master/slave setup
- PTY read thread
- PTY writes

So when the tmux MVP introduces a second backend kind, that distinction matters.

### 8.3 The `tmux_mvp` diff

The diff shows all of these at once:

- source surface remains `exec`
- child pane surface becomes `.tmux`
- `.tmux` backend has no PTY/subprocess startup
- child pane bytes can be injected via `.process_output`

That is direct code evidence for the new ownership model.

### 8.4 The detached tmux walkthrough

The `pane_pid` / `pane_tty` walkthrough shows:

- tmux already owns real pane process/tty state before a client attaches
- attach/detach does not recreate the pane world
- control-mode clients attach to that already-existing world

That is the runtime proof behind the architectural design.

## 9. A short practical proof you can run yourself

If you want to prove the tmux-side ownership model again:

### Step 1: Start tmux detached

```bash
tmux -L prove -f /dev/null kill-server 2>/dev/null || true
tmux -L prove -f /dev/null new-session -d -s demo
tmux -L prove -f /dev/null split-window -h -d -t demo:0
```

### Step 2: Ask tmux what panes already exist

```bash
tmux -L prove list-panes -a -F 'pane=#{pane_id} pid=#{pane_pid} tty=#{pane_tty}'
```

This proves tmux already knows the real pane process and the pane terminal
device before any control-mode client is attached.

### Step 3: Attach in control mode and ask again

```bash
tmux -CC -L prove attach -t demo
```

In another terminal:

```bash
tmux -L prove list-panes -a -F 'pane=#{pane_id} pid=#{pane_pid} tty=#{pane_tty}'
tmux -L prove list-clients -F 'client=#{client_name} pid=#{client_pid} tty=#{client_tty}'
```

The important observation is:

- the pane process/tty world already existed
- the control-mode client appears as a client
- it did not create a second set of pane shells

### Cleanup

```bash
tmux -L prove -f /dev/null kill-server
```

## 10. Final conclusion

The correct first-principles model is:

- the **source surface** is an ordinary `exec` surface that owns the PTY to the
  `tmux -CC` client
- the **tmux client** talks to the **tmux server**
- the **tmux server** owns the real pane shells and pane terminal devices
- the **child tmux pane surface** should receive pane bytes and send pane input
  through tmux, not by launching its own subprocess/PTy pair

So if you type `ls` in a tmux-backed Ghostty pane, the right story is:

```text
Ghostty child pane surface
-> tmux command for pane %N
-> Ghostty source exec surface
-> tmux client
-> tmux server
-> real shell in pane %N
-> tmux server
-> tmux client
-> Ghostty source surface parser/viewer
-> Ghostty child pane surface Terminal
-> renderer
```

That is why the child tmux backend does not need its own PTY.
