# S9A Trace

This session answered one narrow question:

> When I type `l`, then `s`, then Enter in a tmux split pane inside ordinary
> Ghostty, how do those bytes leave Ghostty and reach the PTY master?

The answer is: the path was ordinary Ghostty terminal IO the whole way. tmux
did not create a special Ghostty pane object or a special Ghostty tmux backend
here. From Ghostty's point of view, this was still one normal exec-backed
surface talking to one PTY.

## The short story

For each key you typed, the same three-part handoff happened:

1. The macOS main thread stopped in `Surface.keyCallback`.
2. The IO thread stopped in `termio.Thread.drainMailbox`.
3. The exec backend stopped in `termio.Exec.queueWrite`.

That happened once for:

- `l`
- `s`
- Enter

So the session proved that each typed byte followed the same outbound write
path.

## Step 1: the app thread turned the key into a write request

The first useful stop was at [Surface.zig:2765](/Users/waqas/code/ghostty_forked/src/Surface.zig:2765):

```zig
self.queueIo(switch (write_req) { ... }, .unlocked);
```

This is still on the macOS main thread. That means:

- Ghostty has already received the key event from AppKit / embedded surface
  glue.
- Ghostty has already decided that this key should produce terminal output.
- Ghostty has already built a write request.

The session log showed this for ordinary character keys and for Enter:

- for `l`, the request was a small one-byte write
- for `s`, the request was a small one-byte write
- for Enter, the request was also a small one-byte write

So the first important lesson is:

> `Surface.keyCallback` does not write to the PTY directly. It packages the
> outbound bytes and hands them toward the IO side with `queueIo(...)`.

One LLDB nuance from this stop:

- LLDB stopped twice on the same source line as `breakpoint 1.1` and
  `breakpoint 1.2`

That is normal here. LLDB found two code locations on the same line. It does
not mean Ghostty handled the key twice.

## Step 2: the IO thread drained the mailbox

The next useful stop was at [Thread.zig:336](/Users/waqas/code/ghostty_forked/src/termio/Thread.zig:336):

```zig
.write_small => |v| try io.queueWrite(...)
```

Now we are no longer on the app thread. We are on the `io` thread.

The log also showed:

```text
io_thread: mailbox message=write_small
```

That tells the story in plain language:

- the app-side code produced a mailbox message
- the IO thread woke up
- the IO thread popped a `write_small` message
- the IO thread forwarded the bytes into backend write logic

This is the important ownership boundary:

- app thread: "this key should send bytes"
- IO thread: "I am the thread that is allowed to perform terminal backend work"

So the second important lesson is:

> `queueIo(...)` is not the PTY write. It is the handoff from app-side code to
> the IO thread, and the IO thread is the one that continues the write path.

## Step 3: the exec backend queued the PTY-master write

The last breakpoint was at [Exec.zig:457](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:457):

```zig
exec.write_stream.queueWrite(...)
```

This is the closest useful Ghostty-side proof that the bytes are being handed
to the PTY master.

The session log showed:

- for `l`, `data = ... len = 1`
- for `s`, `data = ... len = 1`
- for Enter, `data = "\r" ... len = 1`

That last detail is important:

- Enter was being sent as carriage return (`\r`) in this path
- `linefeed` was `false`

So the third important lesson is:

> by the time you reach `Exec.queueWrite`, Ghostty is no longer deciding
> whether the key should become terminal output. It is now doing transport work:
> queueing concrete bytes to the PTY stream.

## Where the PTY handoff actually happens

Your question was exactly right: at the last breakpoint, you can see a stream
write, but you do not yet visibly see the words "PTY master" on that line.

The proof is spread across a few lines in `Exec.zig`.

### Proof 1: the write stream is created from the PTY write fd

At [Exec.zig:128](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:128):

```zig
var stream = xev.Stream.initFd(pty_fds.write);
```

So `stream` is not an abstract mystery object. It is an `xev` stream built from
the PTY write file descriptor.

### Proof 2: that stream is stored into exec backend state

At [Exec.zig:146](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:146):

```zig
td.backend = .{ .exec = .{
    ...
    .write_stream = stream,
    ...
} };
```

So later, when you see `exec.write_stream`, that is the same stream that was
created from `pty_fds.write`.

### Proof 3: the child process is attached to the PTY slave

In the subprocess setup path at
[Exec.zig:1007](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:1007):

```zig
.stdin = ... pty.slave
.stdout = ... pty.slave
.stderr = ... pty.slave
```

And in the Flatpak path at
[Exec.zig:985](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:985):

```zig
.stdin = pty.slave
.stdout = pty.slave
.stderr = pty.slave
```

So the child subprocess lives on the PTY slave side.

### Proof 4: Ghostty keeps the PTY master side

At [Exec.zig:999](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:999)
and [Exec.zig:1065](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:1065):

```zig
.read = pty.master,
.write = pty.master,
```

So Ghostty keeps the master side, and the subprocess gets the slave side.

### Putting those four facts together

This is the concrete handoff:

1. `pty_fds.write` is used to create `stream`
2. `stream` becomes `exec.write_stream`
3. `Exec.queueWrite` calls `exec.write_stream.queueWrite(...)`
4. therefore that call queues bytes onto the PTY master write side

That is why the last breakpoint is the right place to say:

> this is the Ghostty-side PTY handoff

Even though the line itself says `write_stream.queueWrite(...)`, the earlier
setup code tells you that this stream is the PTY-master write stream.

## What the session proved for each key

### `l`

- app thread built a `write_req`
- IO thread drained `.write_small`
- exec backend queued one-byte write `l`

### `s`

- same path again
- same ownership transitions again
- exec backend queued one-byte write `s`

### Enter

- same path again
- exec backend queued one-byte write `\r`

That is a very useful result, because it shows the write path is structural.
The path does not care whether the key is "letter in a command" or "submit the
command". The same architecture handles all of them.

## What this means for your mental model

Here is the clean model to keep:

```text
typed key
-> Surface.keyCallback on main thread
-> queueIo(...)
-> IO thread drains mailbox
-> io.queueWrite(...)
-> Exec.queueWrite(...)
-> exec.write_stream.queueWrite(...)
-> PTY master
```

And one equally important non-conclusion:

> In ordinary tmux-inside-Ghostty, Ghostty still does not know about tmux split
> panes as native Ghostty surfaces here.

It only sees:

- one exec-backed Ghostty surface
- one PTY stream
- ordinary terminal input bytes leaving for that PTY

tmux split structure is real, but it is real inside tmux's own world, not in
Ghostty's surface model on current `main`.

## One final practical note about the transcript

The session log contains some extra LLDB stepping noise and duplicate same-line
breakpoint locations. That is normal. The high-signal story is still simple:

- `Surface.zig:2765` = app-side handoff
- `Thread.zig:336` = IO-thread handoff
- `Exec.zig:457` = PTY-master write handoff

That is the write-path story this session was designed to teach.
