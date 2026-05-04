# S9A Transcript Template

## Build and setup

- Ghostty build used:
- tmux version:
- Exact tmux start command:
- Exact split command used:
- Which pane did you type `l`, `s`, and Enter in:

## Breakpoint sequence

1. `Surface.zig:2765` for `l`
2. `Thread.zig:336` for `l`
3. `Exec.zig:457` for `l`
4. `Surface.zig:2765` for `s`
5. `Thread.zig:336` for `s`
6. `Exec.zig:457` for `s`
7. `Surface.zig:2765` for Enter
8. `Thread.zig:336` for Enter
9. `Exec.zig:457` for Enter

## What each stop proved

### `Surface.zig:2765`

- What was `write_req`?
- How did `write_req` differ between `l`, `s`, and Enter?
- What did this prove about app-side input handoff?

### `Thread.zig:336`

- What thread were you on?
- Did this recur once per typed key?
- What did this prove about mailbox/IO handoff?

### `Exec.zig:457`

- What bytes were queued?
- How did the queued slice differ for `l`, `s`, and Enter?
- Why is this the best Ghostty-side proof of the PTY-master write?

## One-paragraph story

Write one short paragraph that starts with:

> When I typed `l`, then `s`, then Enter in one tmux split pane, Ghostty...

and ends with:

> ...and the write-path story ends when the exec backend queues the PTY-master
> write.

## Remaining confusions

- Confusion 1:
- Confusion 2:
- Confusion 3:
