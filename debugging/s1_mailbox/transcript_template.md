# S1 Transcript

Date:

Build used: `macos/build/Debug/Ghostty.app`

Letter typed:

## Stop-by-stop notes

- `Surface.zig:2765`
- `Surface.zig:860`
- `Termio.zig:400`
- `mailbox.zig:61`
- `mailbox.zig:99`
- `termio/Thread.zig:440`
- `termio/Thread.zig:308`

## Answers to success criteria

1. Who pushes the termio message?

The first producer for this specific typed-key path is the surface code on the
app thread.

More precisely:

- `Surface.keyCallback` creates a `write_req`
- `Surface.queueIo` forwards the resulting `termio.Message`
- `Termio.queueMessage` then pushes that message into the termio mailbox

So the most accurate short answer is:

- the app-thread surface path is the producer
- `Termio.queueMessage` is the helper that actually performs the mailbox
  `send(...)`

2. Where does the queue live?

The queue lives in the termio mailbox, not in `Termio` as a vague concept.

More precisely:

- `Termio` owns a `mailbox`
- the queue implementation is inside `termio.mailbox.Mailbox`
- in this path, the mailbox uses the `.spsc` queue variant

So the accurate answer is:

- the queue lives inside `Termio.mailbox`

3. What wakes the IO thread?

`Mailbox.notify()` wakes the IO thread.

The producer-side order is:

1. `Mailbox.send(...)`
2. `Mailbox.notify()`
3. later, on the IO thread, `wakeupCallback`
4. then `drainMailbox`

So the accurate short answer is:

- `Mailbox.notify()` requests the IO-thread wakeup

4. Where is the message actually handled?

The message is actually handled on the IO thread, inside
`termio.Thread.drainMailbox`.

More precisely:

- `wakeupCallback` is only the wakeup entrypoint
- `drainMailbox` pops the message
- the `switch (message)` inside `drainMailbox` dispatches it

For the typed `x` case, the popped message was `write_small`.

## Review and corrections

- Was the producer-side stop on the app thread?
  Yes. The typed-key path began on thread `#1`, the macOS main thread.

- Did `Termio.queueMessage` clearly show queue-plus-notify?
  Yes. The code at `Termio.zig:405-409` shows `mailbox.send(...)` first and
  `mailbox.notify()` second.

- Did the IO-thread stops happen after the notify, not before?
  Yes. The trace showed the producer-side path on thread `#1` first, then later
  the IO thread stopped in `wakeupCallback`, then later in `drainMailbox`.

- Did anything print as unreadable hex or an opaque union, and if so, what
  source position or backtrace did you use instead?
  Yes. The union dumps showed many garbage-looking inactive arms, but the active
  `tag` was `write_small`, so only that arm was meaningful. A few function-entry
  prints also showed bogus values like `0xaaaaaaaa...`; in those cases the later
  stabilized values after one `next`, plus source position and thread identity,
  were the trustworthy evidence.

## Remaining confusion

- 
