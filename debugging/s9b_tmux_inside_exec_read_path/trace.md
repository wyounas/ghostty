# S9B Trace

This session answered the other half of the ordinary tmux story:

> After I pressed Enter on `ls` inside a tmux split pane, how did the bytes come
> back from the PTY and become rendered output?

The answer is: the read path was ordinary Ghostty terminal output processing
the whole way. tmux was running *inside* the normal exec-backed terminal
session, so Ghostty still followed its standard:

```text
PTY read -> processOutput -> parser -> renderer
```

This file explains the same session in simple language and ignores most of the
raw LLDB noise.

## The short story

The important stops in the session were:

1. the `io-reader` thread stopped at the PTY read line
2. the same `io-reader` thread stopped at the direct handoff into
   `Termio.processOutput`
3. the same `io-reader` thread stopped at the bulk parser entry
4. the renderer thread later stopped when it locked shared state to draw

So the session really did prove the whole read-side chain.

## Step 1: Ghostty first saw returned bytes on the `io-reader` thread

The first useful stop was at
[Exec.zig:1298](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:1298):

```zig
const n = posix.read(fd, &buf) catch |err| { ... };
```

The most important fact here is the thread identity:

- thread name: `io-reader`

That tells you:

- Ghostty does **not** read returned PTY output on the app thread
- Ghostty does **not** read returned PTY output on the IO mailbox thread
- Ghostty uses a dedicated read thread for this work

This matches the exec backend setup code in
[Exec.zig:137](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:137),
where Ghostty explicitly spawns the read thread and names it `io-reader`.

So the first important lesson is:

> returned terminal bytes first enter Ghostty on the dedicated exec read thread

## Step 2: the read thread handed the bytes directly into `Termio`

The next useful stop was at
[Exec.zig:1326](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:1326):

```zig
@call(.always_inline, termio.Termio.processOutput, .{ io, buf[0..n] });
```

This is one of the most important lines in the session.

It means:

- the read thread already has bytes in its local buffer
- it does **not** send them through a mailbox first
- it calls `Termio.processOutput(...)` directly, on the same read thread

So the second important lesson is:

> PTY output does not go through an extra queue before parsing starts. The exec
> read thread calls `Termio.processOutput` directly.

That is an important contrast with the write path from `s9a`, where app-side
input crossed into the IO thread by queueing a message first.

## Step 3: `Termio` fed the returned bytes into the bulk parser path

The next useful stop was at
[Termio.zig:728](/Users/waqas/code/ghostty_forked/src/termio/Termio.zig:728):

```zig
self.terminal_stream.nextSlice(buf)
```

This is the bulk parser entry.

In plain language:

- `Termio` received a slice of bytes that came back from the PTY
- it handed those bytes to Ghostty's terminal byte-stream parser
- the parser then interpreted terminal control sequences and screen updates

This is where a lot of people expect to see plain text like:

```text
default.profraw
dist
example
...
```

But the session log showed much more than that.

The returned `buf` contained lots of escape-sequence-heavy data, such as:

- cursor movement
- region changes
- screen redraw instructions
- status-line updates

That is normal.

Why?

Because this session was not reading output from a bare shell prompt. It was
reading output from **tmux inside a terminal**. tmux often redraws pane content
using many VT control bytes, not just raw printable filenames.

So the third important lesson is:

> the parser stop may show a large VT-heavy redraw buffer, not just plain `ls`
> text, and that is exactly what you should expect from ordinary tmux output

## Step 4: the renderer later read shared terminal-visible state

The final useful stop was at
[generic.zig:1173](/Users/waqas/code/ghostty_forked/src/renderer/generic.zig:1173):

```zig
state.mutex.lock();
```

This stop happened on the renderer thread, not the read thread.

The backtrace in the session showed the renderer path:

- `renderer.Thread.wakeupCallback`
- `renderer.Thread.renderCallback`
- `renderer.generic.Renderer.updateFrame`

That means:

- the output path already updated terminal-visible state
- now the renderer thread is locking shared state so it can safely read it
- then it can build the frame that appears on screen

So the fourth important lesson is:

> rendering is a later, separate ownership stage. The read thread updates the
> terminal model, and the renderer thread later reads that shared model to draw.

## Why you saw the `ls` result in Ghostty even though the log felt confusing

The raw transcript felt confusing for two reasons:

1. Some LLDB commands were stepped too aggressively
2. The returned data was full of VT redraw sequences instead of simple text

That made the session *feel* like the parser or renderer steps had been missed.

But they were not missed.

The session definitely reached:

- PTY read at `Exec.zig:1298`
- direct handoff at `Exec.zig:1326`
- parser entry at `Termio.zig:728`
- renderer state read at `generic.zig:1173`

And seeing the `ls` output in the Ghostty window at the end is completely
consistent with that path having succeeded.

## The full read-side story in plain language

Here is the whole ordinary tmux-inside-Ghostty read story:

1. You pressed Enter on `ls` in a tmux pane.
2. The shell inside tmux ran `ls`.
3. tmux produced terminal output for that pane.
4. That output came back through the ordinary PTY connection.
5. Ghostty's `io-reader` thread read those bytes from the PTY.
6. The read thread called `Termio.processOutput(...)` directly.
7. `Termio` fed the bytes into `terminal_stream.nextSlice(buf)`.
8. Ghostty parsed the VT/control bytes and updated terminal-visible state.
9. The renderer thread later locked shared state and drew the updated frame.

That is the whole architectural point of `s9b`.

## What this session proved about current Ghostty

This session also reinforced the bigger current-state conclusion:

> ordinary tmux inside Ghostty is still just one normal exec-backed Ghostty
> surface with one PTY stream

Ghostty did not create a native Ghostty child surface for the right tmux pane.

Instead, Ghostty simply:

- read bytes from one PTY
- parsed them
- rendered them

tmux pane structure was real, but it stayed inside tmux's own world.

## One final practical note about the transcript

The raw transcript contains some LLDB input noise and some step-over noise near:

- `Termio.zig:729`
- `Exec.zig:1327`

Those are not the main story.

The high-signal read-path story is:

- `Exec.zig:1298` = PTY read happens
- `Exec.zig:1326` = bytes are handed directly into `Termio`
- `Termio.zig:728` = bulk parser starts
- `generic.zig:1173` = renderer reads shared state to draw

That is the read-path story this session was designed to teach.
