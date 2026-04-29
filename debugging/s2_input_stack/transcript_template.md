# S2 Transcript

Date:

Build used: `macos/build/Debug/Ghostty.app`

Characters typed:

## Stop-by-stop notes

- `embedded.zig:179`
- `Surface.zig:2604`
- `Surface.zig:2649`
- `Surface.zig:2752`
- `Surface.zig:3135`
- `Surface.zig:2765`
- `termio/Thread.zig:336`
- `Exec.zig:402`

## Answers to success criteria

1. Where does a surface key event first enter Zig?
2. What runs before Ghostty decides to write anything to the PTY?
3. Why does the shell not visibly respond until output comes back later?
4. Which function actually writes bytes toward the child process?

## Review and corrections

- Did the first stop happen in `embedded.App.keyEvent`?
- Was the keybinding-versus-encoding split visible in `Surface.keyCallback`?
- Did `Exec.queueWrite` appear only after the IO-thread dispatch stop?
- If a value printed as opaque, which source location or backtrace answered the
  question instead?

## Remaining confusion

- 
