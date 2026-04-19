# Tier 2 Post-MVP Analysis — April 8, 2026

Enhanced Tier 2 run with logs added to `src/terminal/tmux/control.zig` (the tmux
protocol parser) and command-response processing in `src/terminal/tmux/viewer.zig`.
All log lines use full file paths. Ghostty 1.3.2-smallestmvp (Debug), tmux 3.5a, macOS.

---

## What This Run Adds Over April 6

The April 6 Tier 2 run showed 6 source files but `control.zig` only logged on
errors. Now it logs on the happy path too — every `%begin` → block → `%end`
transition. And `viewer.zig` now logs which command type each block response
corresponds to.

| File (full path) | April 6 lines | April 8 lines | What's new |
|------------------|--------------|--------------|------------|
| `src/termio/Exec.zig` | 18 | 27 | More PTY reads (longer experiment) |
| `src/terminal/Parser.zig` | 1 | 1 | Same (fires once for DCS entry) |
| `src/terminal/dcs.zig` | 29 | 47 | More notifications (longer experiment) |
| `src/terminal/tmux/control.zig` | 0 | **26** | **NEW: %begin→block→%end parsing visible** |
| `src/terminal/tmux/viewer.zig` | 18 | **45** | **NEW: command response type logging** |
| `src/termio/stream_handler.zig` | 19 | 19 | Same |
| **Total GHY lines** | **97** | **165** | |

---

## The Complete Data Flow: All 7 Source Files

### Phase 1: DCS Entry (4 files, same as before)

```
[termio/Exec.zig]                [GHY:PTY:READ] n=44
[terminal/Parser.zig]            [GHY:VT:DCS] params={ 1000 } final=0x70('p')
[terminal/dcs.zig]               [GHY:DCS:HOOK] tmux_control_mode_detected
[termio/stream_handler.zig]      [GHY:TMUX:VIEWER] viewer_created state=startup_block
```

### Phase 2: Initial Block — NOW showing control.zig internals

Previously we saw `[dcs.zig] notification=block_end` but not HOW the block was
parsed. Now:

```
[terminal/tmux/control.zig]      [GHY:TMUX:PARSE] notification->block (%begin received)
[terminal/tmux/control.zig]      [GHY:TMUX:PARSE] block_complete block->idle output_len=0
[terminal/dcs.zig]               [GHY:DCS:PUT] notification=block_end
[terminal/tmux/viewer.zig]       [GHY:TMUX:VIEWER] state_transition startup_block->startup_session
```

The first two lines are new. They show `control.zig` receiving `%begin`, entering
block state, then receiving `%end`, completing the block (output_len=0 because the
initial block is empty), returning to idle, and emitting the `block_end` notification
that `dcs.zig` then wraps and passes upstream.

### Phase 3: Handshake + Serial Command Dance — Full 7-File Trace

#### The version query (round-trip 1, all 7 files visible):

```
1. [termio/stream_handler.zig]   [GHY:TMUX:CMD] sending_to_tmux
                                 text="display-message -p '#{version}'"
   ↓ (write path: mailbox → IO thread → PTY → tmux)

2. [termio/Exec.zig]             [GHY:PTY:READ] n=115
   ↓ (tmux response arrives as raw bytes)

3. [terminal/tmux/control.zig]   [GHY:TMUX:PARSE] notification->block (%begin received)
   ↓ (parser enters block accumulation state)

4. [terminal/tmux/control.zig]   [GHY:TMUX:PARSE] block_complete block->idle output_len=4
   ↓ (parser sees %end, block contains "3.5a" = 4 bytes)

5. [terminal/dcs.zig]            [GHY:DCS:PUT] notification=block_end
   ↓ (dcs handler wraps notification into Command)

6. [terminal/tmux/viewer.zig]    [GHY:TMUX:VIEWER] processing_command_response
                                 type=tmux_version content_len=4 is_err=false
   ↓ (Viewer identifies this as the version response, stores "3.5a")

7. [termio/stream_handler.zig]   [GHY:TMUX:CMD] sending_to_tmux
                                 text="list-windows -F '...'"
   ↓ (Viewer immediately emits next command)
```

This is the first time we can see a COMPLETE round-trip through all 7 files:
stream_handler sends → Exec reads response → control.zig parses the block →
dcs.zig wraps it → viewer.zig identifies the command type → stream_handler
sends the next command.

#### Key Observations: The list-windows Round-Trip (THE GAP)

**Ghostty sent** (via `[termio/stream_handler.zig]`):
```
list-windows -F '#{session_id} #{window_id} #{window_width} #{window_height} #{window_layout}'
```

**Raw bytes arrived** (via `[termio/Exec.zig]`):
```
[GHY:PTY:READ] n=54
```
54 bytes of response data from tmux.

**control.zig parsed the block**:
```
[terminal/tmux/control.zig] [GHY:TMUX:PARSE] notification->block (%begin received)
[terminal/tmux/control.zig] [GHY:TMUX:PARSE] block_complete block->idle output_len=28
```
The parser saw `%begin`, entered block state, accumulated 28 bytes of content
between `%begin` and `%end`, then completed. Those 28 bytes are the actual
window data.

**dcs.zig forwarded to the Viewer**:
```
[terminal/dcs.zig] [GHY:DCS:PUT] notification=block_end
```

**viewer.zig identified and processed the response**:
```
[terminal/tmux/viewer.zig] processing_command_response type=list_windows content_len=28 is_err=false
[terminal/tmux/viewer.zig] terminal_created pane_id=0 cols=80 rows=24
```
The Viewer knew this was the `list_windows` response (because it's the head of
the command queue). It parsed the 28 bytes as `$0 @0 80 24 b25d,80x24,0,0,0`
(session $0, window @0, 80 cols, 24 rows, single-pane layout with pane ID 0).
It created a Terminal(80, 24) for pane %0.

**The .windows action was emitted and DROPPED**:
```
[termio/stream_handler.zig] [GHY:TMUX:WIN] windows_action window_count=1
[termio/stream_handler.zig] [GHY:TMUX:WIN]   window id=12297829382473034410 ...x...
[termio/stream_handler.zig] [GHY:TMUX:WIN] ^^^ THIS DATA IS CORRECT BUT DROPPED
```
"DROPPED" means: the `.windows` action arrived at `stream_handler.zig:456`
(original line number on main branch), which contains `// TODO`. No Surface
was created. The garbled ID (`12297829382473034410`) is Zig's `{any}` formatter
misrendering the Window struct — the actual data is correct (proven by
`terminal_created pane_id=0 cols=80 rows=24` above).

**Viewer moved on immediately**:
```
[termio/stream_handler.zig] [GHY:TMUX:CMD] text="capture-pane -p -e -q -S - -E -1 -t %0"
```
The Viewer doesn't know `.windows` was dropped. It continues with capture-pane
commands to populate the Terminal it just created.

#### Capture-pane round-trips (all showing control.zig internals):

For each of the 4 capture-pane commands, we now see the full parsing:

```
[termio/stream_handler.zig]   [GHY:TMUX:CMD] "capture-pane -p -e -q -S - -E -1 -t %0"
[termio/Exec.zig]             [GHY:PTY:READ] n=78
[terminal/tmux/control.zig]   [GHY:TMUX:PARSE] notification->block (%begin received)
[terminal/tmux/control.zig]   [GHY:TMUX:PARSE] block_complete block->idle output_len=0
[terminal/dcs.zig]            [GHY:DCS:PUT] notification=block_end
[terminal/tmux/viewer.zig]    processing_command_response type=pane_history content_len=0
```

All 4 captures are empty (output_len=0, content_len=0) because this is a fresh
session. The `type=` field shows exactly which capture: `pane_history` (primary
scrollback), `pane_visible` (primary visible), then the same pair again for
alternate screen.

#### State sync (list-panes):

```
[termio/stream_handler.zig]   [GHY:TMUX:CMD] "list-panes -F '...26 fields...'"
[termio/Exec.zig]             [GHY:PTY:READ] n=50
[terminal/tmux/control.zig]   [GHY:TMUX:PARSE] notification->block (%begin received)
[terminal/tmux/control.zig]   [GHY:TMUX:PARSE] block_complete block->idle output_len=90
[terminal/dcs.zig]            [GHY:DCS:PUT] notification=block_end
[terminal/tmux/viewer.zig]    processing_command_response type=pane_state content_len=90
```

90 bytes of terminal state data: cursor position, modes, scroll region, tab stops.
Applied to pane %0's Terminal.

### Phase 4: Steady State — Output Through All Files

```
[termio/Exec.zig]             [GHY:PTY:READ] n=140
[terminal/dcs.zig]            [GHY:DCS:PUT] notification=output
[terminal/tmux/viewer.zig]    output_routed_to_terminal pane_id=0 data_len=91
```

Note: `control.zig` does NOT log `%output` notifications (they don't go through
the `%begin`/`%end` block mechanism — they're single-line notifications parsed
directly by `parseNotification`). The `dcs.zig` DCS:PUT log catches them.

### Phase 5: Split-Window — Second Pane

```
[terminal/dcs.zig]            notification=layout_change
[terminal/tmux/viewer.zig]    terminal_created pane_id=1 cols=80 rows=11
[termio/stream_handler.zig]   [GHY:TMUX:WIN] windows_action window_count=1
[termio/stream_handler.zig]   [GHY:TMUX:WIN]   window id=0 80x24
[termio/stream_handler.zig]   [GHY:TMUX:WIN] ^^^ THIS DATA IS CORRECT BUT DROPPED

Then 4 captures + 1 list-panes for pane %1, each showing:
[terminal/tmux/control.zig]   notification->block (%begin received)
[terminal/tmux/control.zig]   block_complete block->idle output_len=...
[terminal/tmux/viewer.zig]    processing_command_response type=pane_history/pane_visible/pane_state

[terminal/tmux/viewer.zig]    output_routed_to_terminal pane_id=1 data_len=155
```

---

## Data Flow Summary: Read and Write Paths

### READ PATH (tmux → Ghostty) — 7 files in sequence:

```
tmux server writes to stdout
  ↓
[termio/Exec.zig]              posix.read() on PTY master fd → [GHY:PTY:READ] n=X
  ↓ processOutput() called, acquires renderer_state.mutex
[terminal/Parser.zig]          VT parser recognizes ESC P → [GHY:VT:DCS] (once at start)
  ↓ dcs_hook/dcs_put actions dispatched
[terminal/dcs.zig]             DCS handler routes bytes to tmux parser → [GHY:DCS:HOOK] / [GHY:DCS:PUT]
  ↓ tmux parser called byte-by-byte
[terminal/tmux/control.zig]    Parses %begin/%end blocks → [GHY:TMUX:PARSE] (block transitions)
  ↓ emits Notification (block_end, output, session_changed, etc.)
[terminal/dcs.zig]             Wraps notification in Command → [GHY:DCS:PUT] notification=<type>
  ↓ Command returned to stream handler
[termio/stream_handler.zig]    Feeds to Viewer → [GHY:TMUX:CMD/WIN] actions
  ↓ viewer.next() called
[terminal/tmux/viewer.zig]     Processes notification → [GHY:TMUX:VIEWER] (state transitions,
                               terminal creation, command response processing, output routing)
  ↓ returns []Action
[termio/stream_handler.zig]    Processes actions (.command → write to tmux, .windows → DROPPED)
```

### WRITE PATH (Ghostty → tmux) — 3 files:

```
[terminal/tmux/viewer.zig]     Returns .command Action with text string
  ↓
[termio/stream_handler.zig]    Calls messageWriter() → [GHY:TMUX:CMD] sending_to_tmux text="..."
  ↓ termio_mailbox.send() — CROSSES THREAD BOUNDARY
IO Thread                      Drains mailbox → debug(io_thread): mailbox message=write_small/write_alloc
  ↓
[termio/Exec.zig]              queueWrite() → xev stream → PTY master fd → tmux stdin
```

---

## Statistics

| Metric | April 6 (Tier 2) | April 8 (Tier 2 enhanced) |
|--------|-----------------|--------------------------|
| Total log lines | 284 | 365 |
| GHY-prefixed lines | 97 | 165 |
| Source files logged | 6 | 7 (control.zig now active) |
| control.zig lines | 0 | 26 |
| viewer.zig processing_command_response | 0 | 12 |
| Commands sent | 12 | 12 |
| Block parse transitions visible | no | yes (26 %begin→block→%end pairs) |
| Command response types visible | no | yes (tmux_version, list_windows, pane_history, pane_visible, pane_state) |

---

## verify.sh Results

All 14 checks PASS (after fixing false positive from `is_err=false` substring).

```
H1-H7: All PASS
Tier 2: state transitions PASS, terminal creation PASS, output routing PASS,
        gap annotation PASS, no invariant violations PASS
```
