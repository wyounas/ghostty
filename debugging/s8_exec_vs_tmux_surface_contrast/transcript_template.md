# S8 Transcript

Date:

Build used: `macos/build/Debug/Ghostty.app`

## Ordinary exec-side notes

- `embedded.zig:1910`
- `embedded.zig:1541`
- `Surface.zig:635`
- `Exec.zig:137`

## tmux-side notes

- `viewer.zig:896`
- `stream_handler.zig:446`

## Replacement table

- subprocess launch ->
- PTY read thread ->
- backend `queueWrite` ->
- backend `resize` ->
- `Surface.init` shared plumbing ->

## Answers to success criteria

1. Which ordinary exec-surface steps would a tmux-backed surface skip?
2. Which existing Ghostty pieces could remain unchanged?
3. Why does `.windows` need an app-thread bridge before any tmux child surface exists?
4. Which thread would likely own live tmux output versus app-surface creation?

## Review and corrections

- Which ordinary stops best proved what is exec-specific rather than
  surface-generic?
- Which tmux stops best proved that structure exists before child-surface
  creation?
- Which rows of the replacement table feel solid, and which still feel
  speculative?
- What evidence convinced you that app-thread creation and live tmux-output
  handling should stay on different ownership paths?

## Remaining confusion

- 
