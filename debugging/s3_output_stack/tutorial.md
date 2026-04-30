# S3 Tutorial: PTY Master, PTY Slave, Backend, and Why tmux May Need a New Backend

This note answers one common confusion from `s3_output_stack`:

1. Is the PTY slave involved?
2. Does Ghostty only deal with the PTY master?
3. Why does Ghostty have a backend at all?
4. Why might tmux control mode need a different backend, perhaps one without
   its own subprocess and PTY?

## 1. Yes, the PTY slave is involved

Yes. The PTY slave is absolutely involved in normal terminal operation.

The correct statement is:

- the PTY slave is part of the Unix runtime path
- but Ghostty does not have source code "running inside the PTY slave"

So in the debugger you can stop in Ghostty when:

- Ghostty writes to the PTY master
- Ghostty reads bytes back from the PTY master

But you cannot stop in Ghostty at a line that means:

- "the PTY slave itself is executing code"

because the PTY slave is a kernel-managed terminal endpoint, not a Ghostty
software component.

## 2. Ordinary Ghostty: who talks to what?

For a normal exec-backed surface, the simple picture is:

```text
Ghostty write path:
Ghostty -> PTY master -> kernel PTY machinery -> PTY slave -> shell

Ghostty read path:
shell -> PTY slave -> kernel PTY machinery -> PTY master -> Ghostty
```

So, yes:

- Ghostty directly deals with the PTY master
- the kernel mediates the master/slave pair
- the child process is attached to the slave side

That is why in `s3` the useful Ghostty-side stops are:

- write side: [Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:457)
- read side: [Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:1298)

## 3. Why do we need a backend?

Because Ghostty wants to separate two different jobs:

### Job A: terminal logic

This is generic terminal-emulator work:

- mailbox handling
- parser entry
- terminal state updates
- renderer coordination

That is mainly `Termio`, `Terminal`, and renderer code.

### Job B: transport/process mechanics

This is the "where do bytes come from and where do bytes go?" job:

- start subprocess
- own PTY
- write to PTY
- read from PTY
- resize PTY
- watch process exit

That is backend work.

The code says this directly in
[backend.zig](/Users/waqas/code/ghostty_forked/src/termio/backend.zig:21):

- a backend owns PTY behavior
- a backend provides read/write capabilities

And in
[Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:1):

- `Exec` starts/stops a subprocess with a PTY
- `Exec` spins up the read thread that reads from the PTY and forwards bytes to
  `Termio`

So the backend exists because Ghostty does not want `Termio` to hard-code
"subprocess attached to PTY" forever.

## 4. Why is the read thread part of the backend?

Because the read thread is not generic terminal logic. It is part of the
transport.

`Termio` does not know how bytes physically arrive.

The backend knows:

- which file descriptor to read
- whether there is a subprocess
- how the read loop should work
- how to shut it down

For `exec`, that means:

- start subprocess and PTY in [Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:84)
- start read thread in [Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:137)
- read bytes in [Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:1298)
- forward them to `Termio.processOutput` in [Exec.zig](/Users/waqas/code/ghostty_forked/src/termio/Exec.zig:1326)

That is why the read thread belongs to the backend.

## 5. First-principles reason tmux may need a different backend

Start from the ordinary case.

### Ordinary exec-backed surface

One Ghostty surface owns:

- one subprocess
- one PTY pair
- one write path to that subprocess
- one read path from that subprocess

That is a very direct model.

### tmux changes the architecture

With tmux control mode, Ghostty is no longer talking directly to each shell as
its own subprocess/PTY pair.

Instead, tmux sits in the middle and already owns the panes.

Very simple picture:

```text
shell inside pane
-> pane PTY inside tmux world
-> tmux
-> tmux control-mode stream
-> Ghostty
```

So if Ghostty later shows one tmux pane as a "child surface", that child
surface may not need:

- its own subprocess
- its own PTY

Why?

Because tmux already owns the real subprocesses and PTYs for its panes.

If Ghostty launched a new subprocess and new PTY for every tmux pane surface,
it would be creating a second, duplicate execution world. That would be wrong.

## 6. Then how does shell output reach the screen in tmux control mode?

This is the key first-principles answer.

In ordinary Ghostty:

- shell output comes back through the shell's PTY to Ghostty

In tmux control mode:

- shell output first goes into the pane that tmux owns
- tmux then reports pane content/output to Ghostty through the tmux control
  channel

So Ghostty's input source changes.

Instead of:

```text
my child process wrote to my PTY
```

it becomes more like:

```text
tmux told me what happened in pane X
```

That is why a tmux-backed child surface likely wants a different backend:

- same higher-level terminal/render machinery above
- different transport/source-of-bytes below

## 7. The simplest mental model

Think of "backend" as:

> the thing below `Termio` that supplies bytes in and carries bytes out

For `exec`, the backend says:

> I run a subprocess, I own a PTY, I read and write that PTY

For a future tmux-backed child surface, the backend would instead say:

> I do not own a fresh subprocess or fresh PTY for this pane.  
> tmux already owns those.  
> I receive pane bytes from tmux and send pane-directed commands back through
> tmux.

That is the first-principles reason the backend may change.

## 8. One careful distinction

This does **not** mean "Ghostty in tmux control mode has no subprocess or PTY
anywhere at all."

A likely design split is:

- one source surface still talks to tmux itself
- tmux-backed child pane surfaces do not each launch their own subprocess/PTy

So the "no subprocess, no PTY" idea usually applies to each tmux pane child
surface, not necessarily to the entire tmux integration as a whole.

## 9. Short conclusion

- Yes, the PTY slave is involved in ordinary Ghostty, but Ghostty does not have
  code running inside it.
- Ghostty mainly talks to the PTY master; the kernel mediates master/slave
  behavior.
- A backend exists so `Termio` stays generic and transport/process details stay
  below it.
- The exec backend owns the PTY read thread because reading the PTY is backend
  transport work.
- A tmux-backed child surface may need a different backend because tmux already
  owns the real pane subprocesses and PTYs.
- In that world, Ghostty would get pane output from tmux's control stream, not
  from a fresh per-child PTY that Ghostty created itself.
