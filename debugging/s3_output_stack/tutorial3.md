# Tutorial 3: What the tmux MVP Validation Is Actually Proving

This tutorial explains the **validation flow** for the `tmux_mvp` branch from
first principles and matches it against the code changes in that branch.

It answers this question:

> When the tmux MVP validation runs, what exactly happens, on which threads, and
> what does that prove?

The most important correction to keep in mind is this:

> the first control-mode bytes are **not** processed on the source IO thread

They are first read and parsed on the **source exec read thread**.

That detail matters a lot.

## 1. What the validation is trying to prove

The validation docs under `tmux_docs/firstmvp/validation/` are proving a narrow,
deliberate first MVP:

- Ghostty starts tmux control mode on a **source surface**
- Ghostty learns about tmux pane `%0`
- Ghostty opens a **second native Ghostty window**
- that second window is seeded from a **snapshot**
- that second window stays **static**
- typing into that second window does **not** go back into tmux

So this is **not** yet a live, fully interactive tmux pane integration.

It is:

- "create a child window from a captured pane snapshot"

not:

- "create a live tmux pane surface that fully mirrors output and forwards input"

That distinction explains a lot of the code.

## 2. The validation setup in plain language

The validation docs do something very careful:

1. create the tmux session **before** Ghostty starts
2. print `FULLMVP_SNAP_A` into the real tmux pane
3. only then launch Ghostty with `tmux -CC attach`

Why?

Because the MVP child window is seeded from `capture-pane`.

So the snapshot marker must already exist in tmux history before Ghostty
attaches.

That is why the validation docs insist on this order.

## 3. The three important surfaces/processes

During validation, think in terms of these three things:

### 3.1 The real tmux pane

This is the real tmux world:

- tmux server
- pane `%0`
- shell running inside pane `%0`

This world exists before Ghostty attaches.

### 3.2 The Ghostty source surface

This is an ordinary exec-backed Ghostty surface.

It:

- launches `tmux -CC attach -t fullmvp`
- owns the PTY to that tmux client subprocess
- has the normal Ghostty exec read thread

This source surface is where tmux control mode is first detected and parsed.

### 3.3 The Ghostty child surface

This is the second native Ghostty window created by the MVP.

It:

- uses the new `.tmux` backend
- does **not** launch its own subprocess
- does **not** open its own PTY
- receives snapshot bytes through Ghostty's own message path

This child is the window you visually inspect for `FULLMVP_SNAP_A`.

## 4. The correct thread model for the validation

There are four thread roles that matter here:

### 4.1 App thread

The main Ghostty/macOS app thread.

This is the only place allowed to create the new child window/surface.

### 4.2 Source renderer thread

Draws the original source surface.

Not the main actor in the validation logic.

### 4.3 Source IO thread

Owns the source surface's Termio mailbox handling and backend thread context.

This is where queued writes to the `tmux -CC` client eventually happen.

### 4.4 Source exec read thread

This is the crucial one.

It:

- reads bytes from the source surface PTY master
- calls `Termio.processOutput`
- feeds the VT parser / DCS handler / tmux parser / Viewer path

So when tmux first sends control-mode bytes, they arrive here first.

### 4.5 Child IO thread

The child `.tmux` surface still has a normal Ghostty IO thread.

It does **not** read from a PTY.

But it **does** drain mailbox messages such as `.process_output`, and that is
how the snapshot bytes reach the child Terminal.

## 5. The whole validation flow, step by step

Now we can state the branch-accurate flow.

### Step 1: tmux session is created before Ghostty starts

The validation creates a dedicated tmux session and prints:

```text
FULLMVP_SNAP_A
```

into the real tmux pane before Ghostty launches.

That means:

- tmux already owns the real pane
- the pane already contains the snapshot marker
- Ghostty has not attached yet

### Step 2: Ghostty launches the source surface

Ghostty starts with an initial command that effectively runs:

```text
tmux -L ghostty_fullmvp -f /dev/null -CC attach -t fullmvp
```

This happens in the **source surface**, which is still an ordinary exec-backed
Ghostty surface.

So the source surface has:

- `Exec` backend
- PTY
- tmux client subprocess

### Step 3: tmux control-mode bytes arrive on the source exec read thread

This is the first key correction to your summary.

The bytes coming back from `tmux -CC` are first read by:

- the source surface's **exec read thread**

The code shape is:

```text
posix.read(fd, &buf)
-> Termio.processOutput(io, buf[0..n])
```

So this path is:

```text
tmux client stdout
-> source PTY slave
-> source PTY master
-> source exec read thread
-> Termio.processOutput
```

Not:

```text
source IO thread first
```

### Step 4: `Termio.processOutput` drives VT/DCS/tmux parsing

On that same source read thread:

1. `Termio.processOutput(buf)` is called
2. Ghostty locks renderer state
3. `processOutputLocked(buf)` calls:
   - `terminal_stream.nextSlice(buf)`
4. that runs the VT parser
5. DCS handler detects tmux control mode
6. tmux control parser parses notifications and command blocks
7. `stream_handler` feeds them into `Viewer`

So the source-side parse path is:

```text
source exec read thread
-> Termio.processOutput
-> terminal_stream.nextSlice
-> VT parser
-> DCS handler
-> tmux control parser
-> Viewer
```

### Step 5: `Viewer` discovers windows and panes

`Viewer` runs its startup sequence:

- session change
- version query
- `list-windows`
- `capture-pane`
- `list-panes`

From the validation point of view, the important fact is:

- `Viewer` learns about the first tmux pane
- `Viewer` emits a `.windows` action
- `Viewer` also emits `pane_snapshot` data from `capture-pane`

### Step 6: `.windows` is handled on the source read thread

This is another important nuance.

When `stream_handler` receives `.windows`, that handling is still happening on
the **source read thread**, because we are still inside the source-side
`processOutput` parsing flow.

The MVP branch changes the old `// TODO` into:

- pick the first pane from the first window
- mark the source surface as having requested a child
- send `.new_tmux_window` to the **app mailbox**

So this is the bridge:

```text
source read thread
-> stream_handler sees .windows
-> app mailbox message: .new_tmux_window
```

That mailbox hop matters because surface creation cannot happen on the read
thread.

### Step 7: the app thread creates the child window

The app thread drains `.new_tmux_window` and creates a new surface/window with:

- backend = `.tmux`
- a pointer back to the source surface
- the chosen pane ID

This is the moment where the second native Ghostty window appears.

So:

- `.windows` is discovered on the source read thread
- actual child-surface creation happens on the app thread

That is exactly what the branch diff shows.

### Step 8: the child surface announces that it is ready

After the child surface is created, the runtime sends a surface message back to
the source:

- `.tmux_mvp_target_ready`

This tells the source surface:

- which child surface is the target
- which pane ID it corresponds to

Now the source knows where to send the pending snapshot bytes.

### Step 9: `pane_snapshot` bytes are stored on the source

When the source-side `Viewer` emits `.pane_snapshot`, `stream_handler` does:

1. check that the snapshot pane ID matches the requested pane
2. call `source.tmuxMvpStoreSnapshotLocked(snapshot.data)`
3. call `source.tmuxMvpFlushPendingSnapshotLocked()`

So the snapshot data first lives on the **source surface** as `pending_snapshot`.

### Step 10: the source enqueues `.process_output` into the child Termio mailbox

This is the next crucial nuance.

The source does **not** directly call the child parser pipeline inline.

Instead, once the child target is ready, the source does:

```text
target.io.queueMessage(.process_output, ...)
```

So the real handoff is:

```text
source surface pending snapshot
-> child Termio mailbox
```

This is the exact branch behavior.

### Step 11: the child IO thread drains `.process_output`

Now the child IO thread becomes important.

The child `.tmux` surface does not have a PTY read thread, but it does have a
normal IO thread draining mailbox messages.

When it sees:

- `.process_output`

it does:

```text
io.processOutput(v.data)
```

So the child path is:

```text
child Termio mailbox
-> child IO thread
-> .process_output
-> child Termio.processOutput(data)
```

### Step 12: the child parser updates the child Terminal

Once `child Termio.processOutput(data)` runs, the child follows the ordinary
Ghostty terminal path:

- `terminal_stream.nextSlice(data)`
- VT parser
- handler updates Terminal state

So the child window text is not drawn by copying pixels.

It is drawn because the child surface processes the snapshot bytes into its own
Terminal model.

### Step 13: the child renderer draws the snapshot

After the child Terminal updates:

- Ghostty queues render work
- the child renderer thread draws the child surface

That is why the child window visibly shows:

```text
FULLMVP_SNAP_A
```

So yes, the end of your summary is roughly right:

- bytes reach child IO side
- child Termio processes them
- child renderer draws them

But the earlier source-side thread story needed correction.

## 6. What happens after that in the validation

The remaining validation steps are deliberately proving that this is only a
snapshot MVP.

### 6.1 The source tmux pane keeps changing

The validation sends:

```text
FULLMVP_LIVE_B
```

into the real tmux pane.

That proves the source pane is still live.

### 6.2 The child stays static

The child window should still show:

- `FULLMVP_SNAP_A`

and should **not** show:

- `FULLMVP_LIVE_B`

This proves:

- the child is not a live mirror
- the child is a static snapshot surface

### 6.3 The child is read-only in practice

The validation types:

```text
FULLMVP_CHILD_INPUT
```

into the child window.

That text must **not** appear in the real tmux pane.

This matches the branch too:

- the `.tmux` backend's `queueWrite()` is still effectively a no-op stub
- the child is not yet forwarding input back through tmux

So the read-only result is exactly what this MVP is supposed to do.

## 7. A compact sequence diagram

```text
real tmux pane already contains FULLMVP_SNAP_A
        |
        v
Ghostty source surface starts tmux -CC attach
        |
        v
source exec read thread reads PTY bytes
        |
        v
Termio.processOutput
-> VT parser
-> DCS handler
-> tmux parser
-> Viewer
        |
        +-----------------------> .windows
        |                           |
        |                           v
        |                    app mailbox: new_tmux_window
        |                           |
        |                           v
        |                      app thread creates child surface
        |                           |
        |                           v
        |                    source gets target_ready
        |
        +-----------------------> .pane_snapshot
                                    |
                                    v
                            source stores pending snapshot
                                    |
                                    v
                            source enqueues .process_output
                            into child Termio mailbox
                                    |
                                    v
                               child IO thread
                                    |
                                    v
                            child Termio.processOutput
                                    |
                                    v
                               child Terminal updates
                                    |
                                    v
                               child renderer draws
                                    |
                                    v
                          child window shows FULLMVP_SNAP_A
```

## 8. The simplest corrected summary

Your original summary was close in shape, but the precise branch-accurate form
is:

1. tmux session is pre-created and already contains snapshot text
2. Ghostty launches a **source exec surface** running `tmux -CC attach`
3. the **source exec read thread** reads control-mode bytes from the PTY master
4. those bytes go through:
   - `Termio.processOutput`
   - VT parser
   - DCS handler
   - tmux parser
   - `Viewer`
5. `.windows` causes an **app mailbox** request for a child tmux window
6. the **app thread** creates the child surface
7. `.pane_snapshot` is stored on the source and then flushed to the child as
   `.process_output`
8. the **child IO thread** drains `.process_output`
9. the child runs its own `Termio.processOutput`
10. the child renderer draws the snapshot text
11. later source-pane changes do **not** update the child
12. child typing does **not** go back into tmux

That is what the validation process is actually proving.

## 9. Final conclusion

So, to answer your question directly:

- yes, the validation flow really is proving a source-surface parse path and a
  child-surface render path
- but no, it is not "source PTY read bytes and this happens in IO thread"

The branch says:

- **source PTY bytes are first read and parsed on the exec read thread**
- **child snapshot bytes are later consumed on the child IO thread**

That is the accurate thread and data-flow story for the `tmux_mvp` first-MVP
validation.
