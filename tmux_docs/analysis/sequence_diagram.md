# Sequence Diagram — April 8, 2026 (Enhanced Tier 2)

All 7 source files visible including `terminal/tmux/control.zig` (tmux protocol
parser) internals and `terminal/tmux/viewer.zig` command response type identification.

## One Complete Round-Trip: All 7 Files

This shows a single command round-trip (the version query) through every component.
Every other round-trip follows the same pattern.

```
tmux         Exec.zig      Parser.zig   dcs.zig       control.zig    stream_       viewer.zig
server       (PTY read)    (VT parser)  (DCS handler)  (tmux parser)  handler.zig   (Viewer)
  │              │              │              │              │              │              │
  │              │              │              │              │              │              │
  │              │              │              │              │         [GHY:TMUX:CMD]     │
  │              │              │              │              │         "display-message    │
  │              │              │              │              │          -p '#{version}'"   │
  │              │              │              │              │              │              │
  │              │              │              │              │         messageWriter()     │
  │              │              │              │              │         → mailbox → IO      │
  │◄─────────────────────────────────────────────────────────────────── thread writes ─────│
  │  (tmux receives command on stdin, processes, sends response)       to PTY             │
  │                                                                                       │
  │  %begin 1 1 0                                                                         │
  │  3.5a                                                                                 │
  │  %end 1 1 0                                                                           │
  │              │              │              │              │              │              │
  ├─────────────►│              │              │              │              │              │
  │          [GHY:PTY:READ]    │              │              │              │              │
  │          n=115             │              │              │              │              │
  │              │              │              │              │              │              │
  │              ├─────────────►│              │              │              │              │
  │              │   (bytes fed │              │              │              │              │
  │              │    through   │              │              │              │              │
  │              │    VT parser │              │              │              │              │
  │              │    byte by   │              │              │              │              │
  │              │    byte in   │              │              │              │              │
  │              │    DCS pass- │              │              │              │              │
  │              │    through   ├─────────────►│              │              │              │
  │              │    state)    │   dcs_put    │              │              │              │
  │              │              │   per byte   ├─────────────►│              │              │
  │              │              │              │  tmux.put()  │              │              │
  │              │              │              │              │              │              │
  │              │              │              │         [GHY:TMUX:PARSE]   │              │
  │              │              │              │         notification->block│              │
  │              │              │              │         (%begin received)  │              │
  │              │              │              │              │              │              │
  │              │              │              │  (accumulates "3.5a"       │              │
  │              │              │              │   in block buffer)         │              │
  │              │              │              │              │              │              │
  │              │              │              │         [GHY:TMUX:PARSE]   │              │
  │              │              │              │         block_complete     │              │
  │              │              │              │         block->idle        │              │
  │              │              │              │         output_len=4       │              │
  │              │              │              │              │              │              │
  │              │              │              │  returns     │              │              │
  │              │              │              │  Notification│              │              │
  │              │              │              │  .block_end  │              │              │
  │              │              │         [GHY:DCS:PUT]       │              │              │
  │              │              │         notification=       │              │              │
  │              │              │         block_end           │              │              │
  │              │              │              │              │              │              │
  │              │              │              ├──── Command returned ──────►│              │
  │              │              │              │              │              │              │
  │              │              │              │              │         feeds to            │
  │              │              │              │              │         viewer.next()       │
  │              │              │              │              │              ├─────────────►│
  │              │              │              │              │              │              │
  │              │              │              │              │              │  [GHY:TMUX:VIEWER]
  │              │              │              │              │              │  processing_command
  │              │              │              │              │              │  _response
  │              │              │              │              │              │  type=tmux_version
  │              │              │              │              │              │  content_len=4
  │              │              │              │              │              │  is_err=false
  │              │              │              │              │              │              │
  │              │              │              │              │              │  stores "3.5a"
  │              │              │              │              │              │              │
  │              │              │              │              │  ◄───── returns .command ───│
  │              │              │              │              │  Action: "list-windows..."  │
  │              │              │              │              │              │              │
  │              │              │              │              │  [GHY:TMUX:CMD]             │
  │              │              │              │              │  sending_to_tmux            │
  │              │              │              │              │  text="list-windows..."     │
  │              │              │              │              │         → mailbox → IO      │
  │◄─────────────────────────────────────────────────────────────────── thread writes ─────│
  │                                                                                       │
  ▼  (next round-trip begins)                                                             ▼
```

## Full Session: Condensed View Showing All Files Per Round-Trip

```
PHASE 1: DCS ENTRY
──────────────────
Exec.zig → Parser.zig → dcs.zig → stream_handler.zig
PTY:READ     VT:DCS       DCS:HOOK     VIEWER created
n=44         params=1000                state=startup_block

PHASE 2: INITIAL BLOCK
───────────────────────
control.zig → control.zig → dcs.zig → viewer.zig
PARSE:begin   PARSE:complete  DCS:PUT     state_transition
              output_len=0   block_end    startup_block→startup_session

DROPPED NOTIFICATIONS (control.zig → dcs.zig → viewer ignores):
  dcs.zig: notification=window_add       → viewer: DROPPED (wrong state)
  dcs.zig: notification=sessions_changed → viewer: DROPPED (wrong state)
  dcs.zig: notification=session_changed  → viewer: session_changed id=0 name="mvp"
                                           viewer: state_transition →command_queue

ROUND-TRIP 1: VERSION (7 files)
───────────────────────────────
stream_handler → [write path] → tmux → Exec → control → control → dcs → viewer → stream_handler
TMUX:CMD         mailbox/IO     stdin  PTY:READ PARSE:   PARSE:   DCS:PUT VIEWER:    TMUX:CMD
"display-msg"                          n=115    begin    complete  block_  processing "list-
                                                         len=4    end     tmux_ver   windows"
                                                                          len=4

ROUND-TRIP 2: LIST-WINDOWS + THE GAP (7 files)
──────────────────────────────────────────────
stream_handler → [write] → tmux → Exec → control → control → dcs → viewer → stream_handler
TMUX:CMD                          PTY:  PARSE:     PARSE:     DCS: VIEWER:   TMUX:WIN
"list-windows"                    READ  begin      complete   PUT  list_win  count=1
                                  n=54             len=28          len=28    DROPPED ◄◄◄
                                                                  terminal
                                                                  _created   TMUX:CMD
                                                                  pane=0     "capture-pane
                                                                  80x24      -t %0"

ROUND-TRIPS 3-6: CAPTURES (same 7-file pattern × 4)
───────────────────────────────────────────────────
Each: stream_handler → Exec → control → control → dcs → viewer → stream_handler
      TMUX:CMD         READ   begin     complete   PUT   processing  TMUX:CMD
      "capture-pane"   n=X              len=0            pane_hist/  (next cmd)
                                                         pane_vis

ROUND-TRIP 7: STATE SYNC
────────────────────────
stream_handler → Exec → control → control → dcs → viewer
TMUX:CMD         READ   begin     complete   PUT   processing
"list-panes"     n=50             len=90           pane_state len=90

═══════════════ COMMAND QUEUE EMPTY — VIEWER READY ═══════════════

PHASE 4: STEADY STATE (%output, no block parsing)
─────────────────────────────────────────────────
Exec.zig → dcs.zig → viewer.zig
PTY:READ    DCS:PUT    output_routed_to_terminal
n=140       output     pane_id=0 data_len=91

(Note: control.zig is NOT involved in %output — these are single-line
 notifications, not %begin/%end blocks. control.zig only logs block transitions.)

PHASE 5: SPLIT-WINDOW
─────────────────────
dcs.zig: notification=layout_change
viewer.zig: terminal_created pane_id=1 cols=80 rows=11
stream_handler.zig: TMUX:WIN count=1, id=0 80x24, DROPPED ◄◄◄
Then 5 more round-trips (4 captures + 1 list-panes) for pane %1,
each showing the full 7-file trace.
Finally: viewer.zig: output_routed_to_terminal pane_id=1 data_len=155
```

## File Activity Summary

| File | Role | When active | Log count |
|------|------|------------|-----------|
| `src/termio/Exec.zig` | PTY read | Every PTY read chunk | 27 |
| `src/terminal/Parser.zig` | VT parser | Once at DCS entry | 1 |
| `src/terminal/dcs.zig` | DCS dispatch | Every notification emitted | 47 |
| `src/terminal/tmux/control.zig` | tmux protocol parser | Every %begin and %end | 26 |
| `src/terminal/tmux/viewer.zig` | Viewer state machine | State transitions + command responses + output routing | 45 |
| `src/termio/stream_handler.zig` | Glue + actions | Commands + windows + viewer lifecycle | 19 |
| **Total** | | | **165** |
