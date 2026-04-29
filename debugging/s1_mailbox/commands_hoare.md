# S1 Hoare-Style Commands

This companion file treats the `s1_mailbox` walkthrough as a sequence of
preconditions and postconditions in the spirit of Hoare logic:

```text
{ precondition } line executes { postcondition }
```

The goal is not to "prove" Ghostty mathematically. The goal is to use LLDB in a
disciplined way so that each stop teaches one precise architectural fact and
does **not** accidentally teach a wrong mental model.

## Ground rules

Before you start, keep these rules in mind:

1. Only assert what this session can really observe.
   This session can prove:
   - thread identity
   - control flow
   - active tagged-union arm
   - relative ordering between enqueue, notify, wakeup, and drain

   This session cannot directly prove:
   - exact queue length
   - exact async-delivery timing
   - the contents of inactive tagged-union arms

2. Trust the active union tag, not the garbage in the inactive arms.
   If `msg.tag == write_small`, only `msg.write_small` is meaningful. Ignore the
   `0xaaaaaaaa...` noise in the other arms.

3. Be careful at function-entry stops.
   LLDB sometimes shows nonsense argument values at the very first prologue
   stop. If that happens, use one `next` to let the frame settle before you
   trust the values.

4. Some breakpoints have more than one location on the same source line.
   That does not mean the code path happened twice. It means LLDB found more
   than one machine-code location mapped to the same source line.

## Setup

Run:

```bash
sh debugging/s1_mailbox/run.sh
```

At the LLDB prompt:

```lldb
run
```

Then click inside Ghostty and type one letter, for example `x`.

Recommended baseline commands at every stop:

```lldb
frame info
source list
thread backtrace
frame variable --show-types
```

## Stop 1: `Surface.keyCallback` at `Surface.zig:2765`

Source:

```zig
self.queueIo(switch (write_req) { ... }, .unlocked);
```

### Preconditions

Before this line executes, the following must already be true:

- you are on the main thread
- `Surface.keyCallback` has already decided this keypress should produce
  terminal input
- `encodeKey(...)` has already succeeded, because the code is inside the
  `if (...) |write_req|` success branch
- `self.child_exited == false`, because the earlier `child_exited` check would
  have closed the surface and returned before this line
- `write_req` exists

### Validate the preconditions

Run:

```lldb
thread backtrace
source list -l 2765
frame variable --show-types write_req
frame variable --show-types self.child_exited
```

What you should see:

- thread `#1`, `com.apple.main-thread`
- source location at `Surface.zig:2765`
- a real `write_req`
- `self.child_exited = false`

### Postcondition

After this line is executed, Ghostty must have constructed a `termio.Message`
from `write_req` and entered the generic surface-to-termio funnel.

### Validate the postcondition

Use:

```lldb
continue
```

Then confirm the next relevant stop is `Surface.queueIo` at `Surface.zig:860`.

That proves:

- the typed-key path did not stop at some other special case
- the encoded write was forwarded into the generic producer funnel

## Stop 2: `Surface.queueIo` at `Surface.zig:860`

Source:

```zig
self.io.queueMessage(msg, mutex);
```

### Preconditions

Before this line executes, the following must be true:

- you are still on the main thread
- the `write_req` has already been converted into a `termio.Message`
- for the typed `x` path, `msg.tag == write_small`
- because `msg` is a write message and control reached line 860, the readonly
  guard did **not** return early
- for this specific path, `self.readonly == false`

### Validate the preconditions

Run:

```lldb
thread backtrace
source list -l 860
frame variable --show-types msg
frame variable --show-types self.readonly
```

What you should conclude:

- the active tag is `write_small`
- the byte payload is the typed `x`
- `self.readonly` is false

### Postcondition

After this line executes, the same `msg` must be handed to `Termio.queueMessage`
on the main thread.

### Validate the postcondition

Use:

```lldb
continue
```

Then confirm the next relevant stop is `Termio.queueMessage`.

## Stop 3: `Termio.queueMessage` at `Termio.zig:404`

Source:

```zig
self.mailbox.send(msg, switch (mutex) {
    .locked => self.renderer_state.mutex,
    .unlocked => null,
});
self.mailbox.notify();
```

### Preconditions

Before line 405 executes, the following must be true:

- you are still on the main thread
- `msg` is still the same `write_small`
- for the key-input path, `mutex == .unlocked`
- `mailbox.send(...)` has not executed yet
- `mailbox.notify()` has not executed yet

### Validate the preconditions

Run:

```lldb
thread backtrace
source list -l 404
frame variable --show-types msg
frame variable --show-types mutex
```

If `self` or `mutex` looks bogus at the very first stop, use:

```lldb
next
frame variable --show-types self
frame variable --show-types mutex
```

The stable value for this path should be:

- `mutex = unlocked`

### Postcondition A

After stepping over line 405, `mailbox.send(...)` has returned, but
`mailbox.notify()` has not yet run.

### Validate postcondition A

Use:

```lldb
next
source list -l 409
```

If control is now at line 409, that proves:

- `mailbox.send(...)` returned
- `mailbox.notify()` is the next action

### Postcondition B

After line 409 executes, Ghostty has attempted to notify the IO thread.

### Validate postcondition B

Use:

```lldb
continue
```

Later evidence for this postcondition appears when the IO thread stops in
`wakeupCallback`.

Do **not** assert that the IO thread has already drained the mailbox at the
moment `notify()` returns. Delivery is asynchronous.

## Stop 4: `Mailbox.send` at `mailbox.zig:65`

Source:

```zig
switch (self.*) {
    .spsc => |*mb| send: {
        if (mb.queue.push(msg, .{ .instant = {} }) > 0) break :send;
        ...
    },
}
```

### Preconditions

Before the queue push runs, the following must be true:

- you are still on the main thread
- the message is still `write_small`
- the mailbox implementation for this path should resolve to `.spsc`
- for the typed-key path, the stabilized `mutex` value should be `null`
  because `Termio.queueMessage` passed `.unlocked`

### Validate the preconditions

Run:

```lldb
thread backtrace
source list -l 65
frame variable --show-types msg
frame variable --show-types mutex
```

If the very first `self` or `mutex` print is nonsense, use:

```lldb
next
frame variable --show-types self
frame variable --show-types mutex
```

### Postcondition on the common fast path

If `mb.queue.push(...)` succeeds immediately, the function should leave via the
fast path without:

- waking the writer from inside `send`
- unlocking/relocking a mutex
- taking the slow retry path

### Validate the postcondition

Run:

```lldb
next
next
```

Then watch the control flow:

- if stepping over line 70 causes the function to return to the caller instead
  of moving down to line 72, the fast path succeeded
- that is the normal, intended result for this session

Do **not** claim that you know the exact queue length. The session only proves
that the immediate push succeeded on the fast path.

## Stop 5: `Mailbox.notify` at `mailbox.zig:99`

Source:

```zig
switch (self.*) {
    .spsc => |*v| v.wakeup.notify() catch |err| { ... },
}
```

### Preconditions

Before this line executes, the following must be true:

- `Mailbox.send` has already returned
- the producer has finished the enqueue step
- this function is now performing only the wakeup half of the protocol

### Validate the preconditions

Run:

```lldb
thread backtrace
source list -l 99
```

### Postcondition

After this line executes, the app thread has attempted to signal the IO thread
wakeup mechanism.

### Validate the postcondition

Use:

```lldb
continue
```

Later evidence is the IO-thread stop in `wakeupCallback`.

Again, do **not** over-claim:

- the postcondition is "notify was attempted"
- not "the IO thread has already drained the mailbox"

## Stop 6: `wakeupCallback` at `termio/Thread.zig:440`

Source:

```zig
const cb = cb_ orelse return .rearm;
cb.self.drainMailbox(cb) catch |err| ...
```

### Preconditions

Before this callback executes, the following must be true:

- you are now on the IO thread
- an async wakeup event has been delivered to that thread
- the mailbox has not yet been drained by this callback invocation

### Validate the preconditions

Run:

```lldb
thread list
thread backtrace
source list -l 440
```

What you should see:

- thread name `io`
- control in `wakeupCallback`

### Postcondition

After the callback runs, it will invoke `drainMailbox`.

### Validate the postcondition

Use:

```lldb
continue
```

Then confirm the next relevant stop is `termio.Thread.drainMailbox`.

## Stop 7: `drainMailbox` at `termio/Thread.zig:308`

Source:

```zig
while (mailbox.pop()) |message| {
    redraw = true;
    log.debug("mailbox message={s}", .{@tagName(message)});
    switch (message) { ... }
}
```

### Preconditions

At the meaningful stop on this line, the following must be true:

- you are on the IO thread
- `mailbox.pop()` has succeeded
- `message` is now bound to one real mailbox message
- dispatch has not happened yet

### Validate the preconditions

Run:

```lldb
thread list
thread backtrace
source list -l 308
frame variable --show-types message
```

For the clean typed-key path, the important fact is:

- `message.tag == write_small`

### Postcondition A

After one `next`, `redraw` becomes `true`.

### Validate postcondition A

Use:

```lldb
next
frame variable --show-types redraw
```

You should see:

- `redraw = true`

### Postcondition B

The IO thread now owns a concrete `write_small` message and is about to dispatch
it through the switch.

### Validate postcondition B

Run:

```lldb
frame variable --show-types message
continue
```

Then watch for the log line:

```text
mailbox message=write_small
```

That is the cleanest confirmation that the drained message really is the typed
input message you followed from the app thread.

## Assertions you should explicitly avoid

To avoid building the wrong mental model, do **not** make these claims from
this session:

- "I know the exact mailbox queue length."
- "Inactive tagged-union arms contain meaningful data."
- "The IO thread drains synchronously inside `notify()`."
- "A bogus `0xaaaaaaaa...` argument at function entry means memory corruption."
- "Two breakpoint locations on the same line mean two distinct user keypresses."

## Condensed Hoare story

The clean `x` path can be summarized like this:

```text
{ key was encoded; child not exited; on main thread }
Surface.keyCallback line 2765
{ a termio.Message will be forwarded into the generic IO funnel }

{ msg.tag == write_small; not readonly; on main thread }
Surface.queueIo line 860
{ Termio.queueMessage will receive the same message }

{ msg.tag == write_small; mutex == unlocked; on main thread }
Termio.queueMessage
{ send happens before notify }

{ message enqueued on fast path }
Mailbox.notify
{ IO-thread wakeup is requested asynchronously }

{ on IO thread; wakeup delivered }
wakeupCallback
{ drainMailbox will run }

{ mailbox.pop() succeeded; message.tag == write_small }
drainMailbox
{ IO thread is about to dispatch the typed input message }
```

That is the architectural lesson `s1` is meant to teach.
