# S9 Transcript Template

## Build and setup

- Ghostty build used:
- tmux version:
- Exact tmux start command:
- Exact split command used:
- Which pane did you type `ls` in:
- How many Ghostty PTY pairs were involved:

## Improved session framing

Write, in 3-5 sentences, why this session was framed as:

- ordinary tmux inside one exec-backed Ghostty surface
- not native Ghostty tmux integration
- positive proof of the normal PTY path
- negative proof that `Viewer` did not run

## Breakpoint sequence

Record the order you observed:

1. `Surface.zig:2765`
2. `Thread.zig:336`
3. `Exec.zig:457`
4. `Exec.zig:1326`
5. `Termio.zig:728`
6. `renderer/generic.zig:1173`

## What each stop proved

### `Surface.zig:2765`

- What was `write_req`?
- What did this prove about Ghostty's knowledge of tmux panes?

### `Thread.zig:336`

- What thread were you on?
- What did this prove about mailbox/IO handoff?

### `Exec.zig:457`

- What bytes were queued?
- Why is this the best Ghostty-side proof of the PTY-master write?

### `Exec.zig:1326`

- What thread were you on?
- What did this prove about the read path?
- Why does this not tell Ghostty which tmux pane produced the bytes?

### `Termio.zig:728`

- What did this prove about parsing?
- Why is this still ordinary terminal parsing rather than tmux control-mode
  parsing?

### `renderer/generic.zig:1173`

- What did this prove about rendering?
- Why is the renderer drawing terminal state rather than a first-class tmux
  pane object?

## Negative proof

- Hit count for `stream_handler.zig:427`:
- Hit count for `viewer.zig:845`:

Explain why those `0` hit counts matter.

## The one-paragraph story

Write one short paragraph that starts with:

> When I typed `ls` in one tmux split pane, Ghostty...

and ends with:

> ...so current Ghostty treats ordinary tmux as one PTY byte stream, not as
> native pane objects.

## Remaining confusions

- Confusion 1:
- Confusion 2:
- Confusion 3:
