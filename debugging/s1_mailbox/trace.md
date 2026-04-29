# S1 Trace: Typing `x` and Watching the Mailbox Path

This trace explains the LLDB session where a Ghostty window finally opened,
you typed `x`, and the mailbox walk began.

The central story is:

1. the app thread handles the key event
2. `Surface.keyCallback` turns it into a write request
3. the surface forwards that request to `Termio`
4. `Termio` pushes it into the mailbox and notifies the IO thread
5. the IO thread wakes, drains the mailbox, and sees a `write_small` message

After that, the log contains some extra traffic too. Those later stops are
useful, but they are not all part of the single clean "`x` was typed" story.

## First important point: breakpoint `1` had two locations

You saw:

- breakpoint `1.1` at `Surface.zig:2765:21`
- breakpoint `1.2` at `Surface.zig:2765:30`

This happened because LLDB resolved the same source line to two instruction
locations on that line. That is normal for an expression like:

```zig
self.queueIo(switch (write_req) { ... }, .unlocked);
```

So this does **not** mean the code ran twice for two different keypresses. It
means LLDB found two stoppable machine-code locations on the same source line.

## The main story

### 1. `Surface.keyCallback` reached the write handoff

First stop:

- thread: `#1`, `com.apple.main-thread`
- location: `Surface.keyCallback` at `Surface.zig:2765`

What this means:

- Ghostty already received your key event on the app thread.
- Binding checks and encoding already happened earlier in `keyCallback`.
- By this point, Ghostty has decided that `x` should be sent to the terminal.

This line:

```zig
self.queueIo(switch (write_req) { ... }, .unlocked);
```

is the handoff from "surface key handling" to "IO/message pipeline."

### 2. The generic producer funnel ran

Next stop:

- thread: `#1`, `com.apple.main-thread`
- location: `Surface.queueIo` at `Surface.zig:860`

This is the generic surface-to-termio producer funnel:

```zig
self.io.queueMessage(msg, mutex);
```

What this means:

- `keyCallback` converted the key into a `termio.Message`
- the surface is now forwarding that message into `Termio`

### 3. `print msg` showed a union, not a struct with all fields valid at once

At `Surface.queueIo`, `print msg` showed:

- `tag = write_small`
- `write_small.data = "x..."`
- `write_small.len = 1`

That is the important part.

Almost everything else in the printed union looked like `0xaaaaaaaa...` or
other nonsense values. That is expected for a tagged union dump. Only the field
selected by the active tag is meaningful.

So the right reading is:

- the message is a `write_small`
- the payload contains the byte for `x`
- the other union arms are garbage for this stop and must be ignored

This is one of the main LLDB lessons for Zig in these sessions:

- trust the active `tag`
- only read the union member that matches that tag

### 4. `Termio.queueMessage` did the "send + notify" work

Then you stopped in:

- thread: `#1`, `com.apple.main-thread`
- location: `Termio.queueMessage` at `Termio.zig:404`

Stepping showed:

- first, `self.mailbox.send(...)`
- later, `self.mailbox.notify()`

That is the exact queue-plus-wakeup pattern the session is trying to teach.

One subtle detail:

At the first prologue stop, LLDB briefly showed:

- `self = 0xaaaaaaaaaaaaaaaa`
- `mutex = locked`

Then after one `next`, the values became sensible:

- `self = 0x00000001046d7a10`
- `mutex = unlocked`

This is normal debugger noise around function-entry/prologue points. The later
values are the trustworthy ones. The important stable facts are:

- the thread is still the app thread
- the message is still `write_small`
- `mutex` for this path is `unlocked`

### 5. `Mailbox.send` pushed into the SPSC queue

Next stop:

- thread: `#1`, `com.apple.main-thread`
- location: `mailbox.zig:65`

Stepping showed:

- `switch (self.*)`
- then the `.spsc` path
- then `mb.queue.push(msg, .{ .instant = {} })`

This means:

- the mailbox implementation for this path is the single-producer,
  single-consumer queue
- the producer is trying the fast path first
- your message is being enqueued on the app thread

Again, one line showed a bogus old-looking pointer before stepping. After one
step, `self` became sensible. That is the same function-entry/prologue issue as
above, not a Ghostty bug.

### 6. `Mailbox.notify` woke the IO thread

Next stop:

- thread: `#1`, `com.apple.main-thread`
- location: `mailbox.zig:99`

This is the second half of the producer-side protocol:

- queue first
- notify second

That matters because Ghostty is not polling the queue all the time. The
producer explicitly wakes the consumer thread after enqueueing the message.

### 7. `Surface.keyCallback` kept running after the mailbox handoff

After that, you stepped through a few later lines in `Surface.keyCallback`:

- `2778`
- `2779`
- `2782`
- `2783`
- `2785`
- `2788`

These lines are **after** the mailbox handoff. They are UI/terminal-state
cleanup work still happening on the app thread:

- selection clearing
- scroll-to-bottom behavior
- renderer-related state changes

This is useful because it shows the app thread does not block waiting for the
IO thread to finish the write. It queues the message, wakes the IO thread, and
then continues its own local follow-up work.

### 8. The IO thread woke and drained the mailbox

Then the story moved to:

- thread: `#10`, name = `io`
- location: `termio.Thread.wakeupCallback`

This is the consumer-side wakeup.

Then:

- thread: `#10`, name = `io`
- location: `termio.Thread.drainMailbox` at `Thread.zig:308`

This is the consumer-side drain.

The important proof is:

- producer-side work happened on thread `#1`
- consumer-side work happened later on thread `#10`

That is exactly the architectural point of the session.

### 9. The drained message was the same `write_small`

At `drainMailbox`, `print message` showed:

- `tag = write_small`
- `write_small.data = "x..."`
- `write_small.len = 1`

So the message that came out of the mailbox on the IO thread is the same kind
of message that went in on the app thread.

Then the log said:

```text
mailbox message=write_small
```

That is the cleanest single confirmation in the whole trace.

It tells the story in one line:

- the mailbox entry being handled by the IO thread is the `write_small` message
  for your typed `x`

## The extra noise after the main story

After the clean path above, the trace contains more stops. These should be read
carefully so they do not create the wrong mental model.

### A. The later `mailbox.notify` stop on thread `#11` is not the original typed-key producer path

You later hit:

- thread `#11`, name = `io-reader`
- `mailbox.notify` at `mailbox.zig:99`

That is **not** the original app-thread "typed `x`" producer path.

It is later traffic from another thread.

Most likely explanation:

- typing `x` into a normal shell/PTY often causes echoed terminal output
- the read side sees bytes and some downstream handling eventually causes
  another mailbox notification

So this later stop is real, but it belongs to a different sub-story:

- read/output-side activity after the typed input

It should not be confused with the earlier app-thread enqueue+notify path.

### B. Later `drainMailbox` hits may be unrelated follow-up messages

You also saw more later stops in `drainMailbox`, and log lines like:

- renderer thread mailbox messages
- visible-state messages
- save-window-state messages

Those later stops prove that the same mailbox machinery is reused for many
purposes, not just typed input.

That is valuable, but it also means:

- once the generic breakpoints are enabled, the session becomes noisy
- not every later hit is "the `x` message"

The clean educational stopping point for `s1` is the first time the IO thread
drains and logs `write_small`.

## Condensed story

If we strip away the noise, the mailbox story for typing `x` is:

1. app thread is in `Surface.keyCallback`
2. Ghostty already encoded `x`
3. app thread forwards `write_small("x")` into `queueIo`
4. `Termio.queueMessage` calls `mailbox.send`
5. `Termio.queueMessage` calls `mailbox.notify`
6. IO thread wakes in `wakeupCallback`
7. IO thread drains the mailbox
8. IO thread sees `message=write_small`

That is the exact teaching goal of `s1`.

## What the weird prints mean

Two debugger behaviors in this trace are worth remembering:

### 1. Tagged union dumps

When `print msg` or `print message` shows many union arms:

- only the arm named by `tag` is valid
- ignore the nonsense values in the inactive arms

Here:

- `tag = write_small`
- therefore `write_small` is the only meaningful payload

### 2. Entry-point/prologue garbage

At a few function-entry stops, LLDB briefly showed bogus pointer values such as
`0xaaaaaaaaaaaaaaaa`.

That did **not** mean Ghostty corrupted memory.

It meant:

- LLDB stopped at a function-entry/prologue location
- the debugger had not yet reconstructed the final argument locations cleanly

After one `next`, the real values appeared.

So for these sessions:

- trust the stabilized values after one step
- trust source location and thread identity more than the very first raw pointer
  print at function entry

## Final conclusion

This trace successfully proved the `s1` lesson:

- a typed key becomes a `write_small` mailbox message on the app thread
- Ghostty enqueues it and explicitly notifies the IO thread
- the IO thread wakes later and drains that exact message

The later extra stops are real, but they are follow-up traffic, not the core
typed-`x` mailbox story.
