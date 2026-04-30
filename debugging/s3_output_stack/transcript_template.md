# S3 Transcript

Date:

Build used: `macos/build/Debug/Ghostty.app`

Command run:

## Stop-by-stop notes

- `Surface.zig:2765`
- `Exec.zig:457`
- `Exec.zig:1248`
- `Exec.zig:1298`
- `Termio.zig:678`
- `Termio.zig:687`
- `Termio.zig:728`
- `renderer/Thread.zig:596`
- `renderer/generic.zig:1173`

## Answers to success criteria

1. Where does Ghostty hand the typed command byte toward the PTY on the app
   side?
2. Where is the closest useful Ghostty-side proof of the PTY-master write?
3. Which thread reads bytes from the PTY?
4. What is the closest Ghostty-side proof that the slave/program side emitted
   bytes?
5. Which function first processes those bytes inside Ghostty?
6. When is the renderer mutex held?
7. Which path causes the renderer to update and draw?

## Review and corrections

- Did the app-side handoff and PTY-master write stops make the write boundary
  clear before the read-side walkthrough began?
- Once the session crossed to the output side, did the first output-side stop
  happen on the PTY read thread?
- Did the read-thread stop make the "closest observable proof of slave/program
  output" idea clear?
- Did `Termio.processOutput` clearly appear before the renderer stops?
- Was the renderer side separate from the output-processing side?
- Which stop best proved the lock-protected handoff into renderer-visible
  state?

## Remaining confusion

- 
