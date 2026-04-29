# S3 Transcript

Date:

Build used: `macos/build/Debug/Ghostty.app`

Command run:

## Stop-by-stop notes

- `Exec.zig:1248`
- `Exec.zig:1298`
- `Termio.zig:678`
- `Termio.zig:687`
- `renderer/Thread.zig:596`
- `renderer/generic.zig:1173`

## Answers to success criteria

1. Which thread reads bytes from the PTY?
2. Which function first processes those bytes inside Ghostty?
3. When is the renderer mutex held?
4. Which path causes the renderer to update and draw?

## Review and corrections

- Did the first output-side stop happen on the PTY read thread?
- Did `Termio.processOutput` clearly appear before the renderer stops?
- Was the renderer side separate from the output-processing side?
- Which stop best proved the lock-protected handoff into renderer-visible
  state?

## Remaining confusion

- 
