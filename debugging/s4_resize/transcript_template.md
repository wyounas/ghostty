# S4 Transcript

Date:

Build used: `macos/build/Debug/Ghostty.app`

Resize action used:

## Stop-by-stop notes

- `Surface.zig:2440`
- `Surface.zig:2460`
- `termio/Thread.zig:321`
- `termio/Thread.zig:376`
- `termio/Thread.zig:430`
- `Termio.zig:478`
- `Exec.zig:260`

## Answers to success criteria

1. Where does a surface turn a size change into a termio message?
2. Why does the IO thread not resize immediately on every tiny drag?
3. Which function resizes the backend?
4. Which function resizes the logical terminal grid?

## Review and corrections

- Did the resize start on the surface side and only later reach the IO side?
- Was the coalescing step visible before `Termio.resize`?
- Did the exec backend stop show PTY-oriented resize, not logical terminal
  policy?
- Which stop best separated "backend resize" from "terminal grid resize"?

## Remaining confusion

- 
