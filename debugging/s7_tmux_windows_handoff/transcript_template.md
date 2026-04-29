# S7 Transcript

Date:

Build used: `macos/build/Debug/Ghostty.app`

tmux attach command used:

## Stop-by-stop notes

- `viewer.zig:845`
- `viewer.zig:1145`
- `viewer.zig:896`
- `stream_handler.zig:427`
- `stream_handler.zig:446`

## Answers to success criteria

1. Where does `Viewer` build the `.windows` action?
2. What pane state already exists before Ghostty reaches the `TODO`?
3. Where would app-thread surface creation need to begin?
4. Why is this a thread-ownership problem rather than a parsing problem?

## Review and corrections

- Which stop best proved that `Viewer` had already parsed real window structure?
- Which stop best proved that per-pane state existed before the dead end?
- Did the final stop clearly show `.windows` reaching `stream_handler.zig`?
- What exactly made it clear that the next missing step belongs on the app
  thread rather than in `Viewer` parsing?

## Remaining confusion

- 
