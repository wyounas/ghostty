# S1: Mailbox Mechanics in Isolation

## Learning objectives

- Watch one small write message move from `Surface` to the termio mailbox.
- See the queue-plus-wakeup pattern clearly.
- Separate enqueue/send from actual message handling.

## Success criteria

After this session, you should be able to answer:

1. Who pushes the termio message?
2. Where does the queue live?
3. What wakes the IO thread?
4. Where is the message actually handled?

## Prerequisites

- Build the Debug macOS app first.
- Launch this session from a clean app start.

## Expected duration

15-25 minutes.

## Run

1. Run:
   `sh debugging/s1_mailbox/run.sh`
2. In LLDB, run:
   `breakpoint list`
3. Confirm the staged setup before launching:
   - breakpoint `1` at `Surface.zig:2765` should be enabled
   - the later generic mailbox breakpoints should exist but be disabled
4. In LLDB, run:
   `run`
5. Wait until Ghostty is visibly usable, then click inside the terminal and type a single letter,
   for example `x`.
6. Ignore shell semantics. This session is only about queueing and wakeup.
7. Use these LLDB commands as you move through the stops:
   - `continue` or `c`: run until the next breakpoint
   - `next` or `n`: step over the current source line
   - `step` or `s`: step into the called function on the current line
   - `finish`: run until the current function returns
   - `thread backtrace`: show how the current frame was reached
   - `thread list`: show all threads
   - `frame variable`: inspect locals
   - `frame variable --show-types <name>`: inspect one value with its type
   - `source list -l <line>`: show source around an important line
8. If you want a Hoare-style walkthrough with explicit preconditions and
   postconditions at each stop, use:
   `debugging/s1_mailbox/commands_hoare.md`

## How to think about LLDB output in this session

For mailbox work, LLDB often shows:

- an address such as `0x0000...` for a pointer
- a union payload that is hard to pretty-print
- a mailbox or queue object that is more useful as a control-flow checkpoint
  than as a full data dump

Do not try to decode the whole queue internals. Instead, validate the mailbox
story in three simpler ways:

1. Use source position.
   If you stop in `Surface.queueIo`, you are still on the producer side. If you
   stop in `termio/Thread.zig`, you are already on the consumer side.

2. Use thread identity.
   The producer-side stops happen on the app thread. The wakeup and drain stops
   happen on the IO thread.

3. Use the queue-then-notify pattern.
   The key fact is not the exact bytes inside the union. The key fact is:
   `send(msg)` happens first, then `notify()`, then the IO thread wakes and
   drains the mailbox.

## Important note about startup noise

`queueIo` is a generic surface helper. Ghostty uses it during ordinary startup
too, especially for initial resize work in `Surface.init()`.

That means a breakpoint on the generic `queueIo` function can stop **before the
first window is even usable**. That is exactly the wrong behavior for this
session, because you need a visible terminal so you can type one letter.

So this session deliberately starts at the **key-specific callsite** in
[Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:2765), where a
typed key has already been encoded into a write request and is about to be
forwarded into the generic IO funnel.

To make that reliable, this session uses a **staged breakpoint setup**:

- at launch, only the typed-key breakpoint is enabled
- when that breakpoint is hit, the generic mailbox breakpoints are enabled
- this avoids startup resize and other unrelated early traffic

If you see any generic mailbox breakpoint fire before Ghostty is usable and
before you typed a letter, stop and restart the session. That means the staged
setup was not the active one.

## What to watch for

- the typed-key path reaches the generic producer funnel at `Surface.queueIo`
- `Termio.queueMessage` sends and notifies.
- `termio.Mailbox` owns the queue and the `xev.Async` wakeup handle.
- The IO thread does not act until `wakeupCallback -> drainMailbox`.

## How to validate what to watch for

### 1. Validate the producer-side funnel

At the stops in
[Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:2765) and
[Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:860):

- run `thread backtrace`
- run `source list -l 2765`
- run `frame variable --show-types write_req`
- continue
- run `source list -l 860`
- run `frame variable --show-types msg`
- optionally run `source list -l 843`

What this proves:

- a typed key has already been encoded into a write request
- the surface is now forwarding that write into the generic producer-side IO
  funnel
- no mailbox wakeup or drain has happened yet

### 2. Validate the combined send-and-notify wrapper

At the stop in [Termio.zig](/Users/waqas/code/ghostty_forked/src/termio/Termio.zig:400):

- run `source list -l 400`
- run `frame variable --show-types msg`
- use `next` once or twice

What this proves:

- `Termio.queueMessage` is the common wrapper used by producer-side callers
- this wrapper does two things together:
  put the message into the mailbox and wake the IO thread

### 3. Validate the queue push and wakeup notify as separate steps

At the stops in [mailbox.zig](/Users/waqas/code/ghostty_forked/src/termio/mailbox.zig:61)
and [mailbox.zig](/Users/waqas/code/ghostty_forked/src/termio/mailbox.zig:99):

- run `source list -l 61`
- run `frame variable --show-types msg`
- continue to line 99
- run `source list -l 99`
- run `thread backtrace`

What this proves:

- the queue insertion and the wakeup are related but distinct operations
- Ghostty does not rely on polling; it explicitly wakes the IO thread

### 4. Validate that wakeup and drain happen on the IO thread

At the stops in
[termio/Thread.zig](/Users/waqas/code/ghostty_forked/src/termio/Thread.zig:440)
and [termio/Thread.zig](/Users/waqas/code/ghostty_forked/src/termio/Thread.zig:308):

- run `thread list`
- run `thread backtrace`
- run `source list -l 440`
- continue
- run `source list -l 308`
- run `frame variable --show-types message`

What this proves:

- the consumer-side wakeup happens on the IO thread
- the mailbox is drained later, not at the original producer call site
- the actual message handling is decoupled from the original app-thread input
  path

## What this session does not cover

- Keybinding logic in detail
- PTY output and rendering
- tmux control mode
