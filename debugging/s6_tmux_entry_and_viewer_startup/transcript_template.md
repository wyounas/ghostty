# S6 Transcript

Date:

Build used: `macos/build/Debug/Ghostty.app`

tmux attach command used:

## Stop-by-stop notes

- `stream_handler.zig:358`
- `dcs.zig:60`
- `stream_handler.zig:385`
- `viewer.zig:372`
- `viewer.zig:390`
- `stream_handler.zig:437`

## Answers to success criteria

1. Where is tmux control mode first recognized?
2. Where is the `Viewer` created?
3. What moves the `Viewer` from startup into command-queue mode?
4. Which tmux commands does Ghostty queue first?

## Review and corrections

- Did the DCS path clearly start as ordinary terminal parsing?
- Which stop best proved the exact tmux-recognition point?
- Did `Viewer` appear before any window-creation logic?
- Which command queue stop best showed that Ghostty first asks tmux for
  metadata?

## Remaining confusion

- 
