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
2. Where does the queue live?
3. What wakes the IO thread?
4. Where is the message actually handled?

## Review and corrections

- Was the producer-side stop on the app thread?
- Did `Termio.queueMessage` clearly show queue-plus-notify?
- Did the IO-thread stops happen after the notify, not before?
- Did anything print as unreadable hex or an opaque union, and if so, what
  source position or backtrace did you use instead?

## Remaining confusion

- 
