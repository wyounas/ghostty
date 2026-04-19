# Ghostty tmux Control Mode: Technical Diagrams

All diagrams referenced in the deep analysis (Sections 6-14). These are meant to be precise technical references for implementation work.

---

## 1. Parser State Machine (`control.zig`)

The control mode protocol parser has 4 states. Every byte from the tmux control mode stream passes through this state machine.

```
                                max_bytes exceeded
                               (from any state)
                                      │
               ┌──────────────────────┼──────────────────────────┐
               │                      ▼                          │
               │                ┌──────────┐                     │
               │    byte != '%' │          │                     │
               │   ┌───────────►│  broken  │                     │
               │   │  (emits    │          │                     │
               │   │  synthetic └──────────┘                     │
               │   │  .exit)     all further                     │
               │   │             bytes dropped                   │
               │   │                                             │
               ▼   │                                             │
          ┌────────┐    byte == '%'    ┌──────────────┐          │
  start──►│  idle  │─────────────────►│ notification │          │
          │        │   (clear buffer,  │              │          │
          └────────┘    start accum)   └──────┬───────┘          │
               ▲                              │                  │
               │                    byte == '\n'                 │
               │                              │                  │
               │                    ┌─────────▼─────────┐        │
               │                    │ parseNotification()│        │
               │                    └─────────┬─────────┘        │
               │                              │                  │
               │              ┌───────────────┼──────────┐       │
               │              │               │          │       │
               │         %begin found    other notif  unknown    │
               │              │          (emit value) (log,skip) │
               │              │               │          │       │
               │              ▼               │          │       │
               │         ┌─────────┐          │          │       │
               │         │  block  │          │          │       │
               │         │         │          │          │       │
               │         └────┬────┘          │          │       │
               │              │               │          │       │
               │         byte == '\n'         │          │       │
               │         parse last line      │          │       │
               │              │               │          │       │
               │         ┌────┴────┐          │          │       │
               │         │         │          │          │       │
               │    is valid    not a         │          │       │
               │    guard-line? guard-line    │          │       │
               │         │         │          │          │       │
               │    emit block  continue      │          │       │
               │    end/err  ◄─accumulating   │          │       │
               │         │     in buffer      │          │       │
               │         │                    │          │       │
               └─────────┴────────────────────┴──────────┘       │
                                                                 │
               ──────────────────────────────────────────────────┘
```

### State Details

| State | Entry condition | Behavior | Exit conditions |
|-------|----------------|----------|-----------------|
| `idle` | Initial state; after emitting any notification | Waits for `%` byte | `%` byte → `notification`; non-`%` byte → `broken` (emit synthetic exit) |
| `notification` | `%` byte received in idle | Accumulates bytes into buffer | `\n` → parse accumulated line, transition based on result |
| `block` | `%begin` parsed in notification | Accumulates block payload lines | `\n` + valid guard-line (`%end`/`%error` with matching format) → emit block_end/block_err → `idle` |
| `broken` | Non-`%` byte in idle, or max_bytes exceeded | Terminal state — drops all input | None (unrecoverable) |

### Guard-Line Validation (Critical for Correctness)

A line inside a `%begin`/`%end` block is only a valid guard-line if ALL of:
1. Starts with `%end` or `%error`
2. Has exactly 4 whitespace-separated tokens: `%end <timestamp> <command_number> <flags>`
3. `<timestamp>` is a valid integer
4. `<command_number>` is a valid integer
5. `<flags>` is a valid integer

This prevents false termination when shell output inside a block coincidentally starts with `%end`.

**Example of a trap:**
```
%begin 1000 5 0
The line below is NOT a guard-line:
%end of file reached
This IS the real guard-line:
%end 1000 5 0
```

---

## 2. Viewer State Machine (`viewer.zig`)

The Viewer is the "brain" that orchestrates a tmux control mode session from DCS detection through steady-state operation.

### 2.1 High-Level Lifecycle

```
  tmux sends ESC P 1000 p (DCS)
       │
       │  dcs.zig detects, emits .enter
       │  stream_handler creates Viewer
       ▼
┌──────────────┐     %block_end       ┌───────────────────┐
│              │    (initial empty     │                   │
│ startup_block│───  block from  ────►│  startup_session  │
│              │     tmux startup)     │                   │
└──────┬───────┘                      └────────┬──────────┘
       │                                       │
       │ %exit at any point                    │ %session-changed $<id> <name>
       │ → emit .exit                          │ (tells us which session we're in)
       ▼                                       ▼
┌──────────┐                          ┌─────────────────────┐
│          │◄── any unrecoverable ────│                     │
│  defunct │    error from any state  │   command_queue      │
│          │                          │   (MAIN STATE)      │
└──────────┘                          │                     │
                                      └─────────┬──────────┘
                                                │
                                                │  This is where the Viewer
                                                │  spends most of its time.
                                                │  It processes:
                                                │
                                  ┌─────────────┼─────────────┐
                                  │             │             │
                             block_end/err   %output    %layout-change
                             (cmd response)  (live data) (structure change)
                                  │             │             │
                                  ▼             ▼             ▼
                             dispatch to   route to     reparse layout
                             command       pane's       sync panes
                             handler       Terminal     queue captures
```

### 2.2 Command Queue Detail

The Viewer sends one command at a time to tmux and waits for the `%begin`/`%end` response before sending the next. This is the serialized command processing flow.

```
                    command_queue state
                          │
              ┌───────────┼───────────────────────┐
              │           │                       │
         queue empty   queue has cmd        notification
         (steady       (send next,          arrives
          state,       wait for             (async)
          process      response)                │
          async                                 │
          notifs)      │                   ┌────┴────────────────┐
              │        │                   │                     │
              │        ▼                   │                     │
              │   emit .command       %output %<pid>      %layout-change
              │   action              route to pane's     %window-add
              │   (stream_handler     Terminal via         %session-changed
              │    writes to tmux     vtStream +           etc.
              │    stdin)             nextSlice()
              │        │
              │        │  wait for %begin/%end
              │        │
              │        ▼
              │   %block_end or %block_err received
              │        │
              │        ▼
              │   dispatch based on command type:
              │
              ├── tmux_version ──► store version string
              │
              ├── list_windows ──► parse window data
              │                    syncLayouts()
              │                    ├── create new panes (Terminal instances)
              │                    ├── prune removed panes
              │                    ├── emit .windows action
              │                    └── queue capture commands for new panes
              │
              ├── pane_history ──► feed captured scrollback to Terminal
              │                    (primary screen, then alternate screen)
              │
              ├── pane_visible ──► feed visible area to Terminal
              │                    (primary screen, then alternate screen)
              │
              ├── pane_state ──► parse list-panes output
              │                  apply to Terminal:
              │                  ├── cursor position, shape, visibility
              │                  ├── insert mode, autowrap, origin mode
              │                  ├── keypad mode (application vs normal)
              │                  ├── mouse modes (all variants)
              │                  ├── focus reporting, bracketed paste
              │                  ├── scroll region (top/bottom margins)
              │                  └── tab stops
              │
              └── user ──► (not yet driven by anything)
```

### 2.3 Per-Pane Initialization Sequence

When a new pane is discovered (via `list-windows`), the Viewer queues 5 commands to fully initialize it:

```
    list-windows response parsed
    new pane %<id> discovered
           │
           ▼
    ┌─────────────────────────────────────┐
    │ 1. capture-pane -p -e -q            │
    │    -S - -E -1 -t %<id>              │  ← primary screen scrollback + visible
    │    (full history, escape sequences)  │
    └──────────────┬──────────────────────┘
                   │ response fed to Terminal (primary screen)
                   ▼
    ┌─────────────────────────────────────┐
    │ 2. capture-pane -p -e -q            │
    │    -t %<id>                         │  ← primary screen visible area only
    │    (current viewport)               │
    └──────────────┬──────────────────────┘
                   │ response fed to Terminal (primary screen)
                   ▼
    ┌─────────────────────────────────────┐
    │ 3. capture-pane -p -e -q            │
    │    -S - -E -1 -t %<id>              │  ← alternate screen scrollback
    │    -T (alternate screen flag)        │
    └──────────────┬──────────────────────┘
                   │ response fed to Terminal (alternate screen)
                   ▼
    ┌─────────────────────────────────────┐
    │ 4. capture-pane -p -e -q            │
    │    -t %<id>                         │  ← alternate screen visible area
    │    -T (alternate screen flag)        │
    └──────────────┬──────────────────────┘
                   │ response fed to Terminal (alternate screen)
                   ▼
    ┌─────────────────────────────────────┐
    │ 5. list-panes -F '...'              │  ← terminal state sync
    │    -t %<id>                         │
    │    (cursor pos, shape, modes, etc.) │
    └──────────────┬──────────────────────┘
                   │ parsed, applied to Terminal
                   ▼
              PANE READY
         (processes live %output)
```

---

## 3. Data Flow: DCS Bytes to Screen Pixels

This shows the full pipeline from tmux server output through every layer of Ghostty to rendered pixels, highlighting the gap.

```
┌──────────────┐
│  tmux server │
│              │
│  Owns shells,│
│  sessions,   │
│  windows,    │
│  panes       │
└──────┬───────┘
       │
       │  Raw bytes over PTY stdout:
       │  ESC P 1000 p ... %output %0 data... %layout-change @0 ... ESC \
       │
       ▼
┌──────────────────────────────────────────────────────────────────────┐
│  termio read thread                                                  │
│  (reads PTY fd, feeds bytes to VT stream parser)                     │
└──────────────────────────────────┬───────────────────────────────────┘
                                   │
                                   │  byte-by-byte through VT parser
                                   │  until DCS sequence detected
                                   ▼
┌──────────────────────────────────────────────────────────────────────┐
│  dcs.zig — DCS Hook                                     [LAYER 1]   │
│                                                                      │
│  tryHook(): params=[1000], final='p'                                 │
│  → Creates control.zig Parser instance                               │
│  → Returns .enter notification                                       │
│                                                                      │
│  Subsequent bytes: put(byte) → delegates to Parser.put()             │
│  DCS unhook (ST): → returns .exit notification                       │
└──────────────────────────────────┬───────────────────────────────────┘
                                   │
                                   │  Notification values (tagged union)
                                   │  enter, exit, block_end, block_err,
                                   │  output, session_changed, layout_change,
                                   │  window_add, etc.
                                   ▼
┌──────────────────────────────────────────────────────────────────────┐
│  control.zig — Protocol Parser                          [LAYER 2]   │
│                                                                      │
│  State machine: idle → notification → block → idle                   │
│  Parses %begin/%end blocks, %output, all %notification types         │
│  Guard-line validation prevents false block termination              │
│  Octal escape handling for %output data                              │
│                                                                      │
│  26 unit tests                                                       │
└──────────────────────────────────┬───────────────────────────────────┘
                                   │
                                   │  Notification
                                   ▼
┌──────────────────────────────────────────────────────────────────────┐
│  stream_handler.zig — dcsCommand()                      [LAYER 3]   │
│                                                                      │
│  .enter → creates Viewer instance                                    │
│  .exit  → destroys Viewer                                            │
│  other  → viewer.next(.{ .tmux = notification })                     │
│           processes returned Actions                                 │
└──────────────────────────────────┬───────────────────────────────────┘
                                   │
                                   │  feeds notification
                                   ▼
┌──────────────────────────────────────────────────────────────────────┐
│  viewer.zig — Viewer State Machine                      [LAYER 4]   │
│                                                                      │
│  Startup handshake → command queue → steady state                    │
│  Creates Terminal instance per pane                                   │
│  Populates via capture-pane (scrollback + visible, pri + alt)        │
│  Syncs terminal state via list-panes (cursor, modes, etc.)           │
│  Routes live %output → pane Terminal via VT stream                   │
│  Handles %layout-change → sync pane structure                        │
│                                                                      │
│  Emits Actions:                                                      │
│    .command  → "send this string to tmux stdin"                      │
│    .windows  → "here are the current windows and panes"              │
│    .exit     → "tear everything down"                                │
│                                                                      │
│  Sub-parsers:                                                        │
│    layout.zig  — tree structure from layout strings (31 tests)       │
│    output.zig  — typed structs from format output (41 tests)         │
│                                                                      │
│  8 integration tests                                                 │
└──────────────────────────┬────────────────┬──────────────────────────┘
                           │                │
              .command     │                │  .windows
                           ▼                ▼
┌─────────────────────────────┐  ┌────────────────────────────────────┐
│  stream_handler.zig         │  │  stream_handler.zig:456-458        │
│                             │  │                                    │
│  Queues write to PTY stdin  │  │  .windows => {                    │
│  → tmux server receives     │  │      // TODO                      │
│    the command               │  │  },                              │
│                             │  │                                    │
│  [IMPLEMENTED]              │  │  *** THE GAP ***                  │
└─────────────────────────────┘  └───────────────┬────────────────────┘
                                                 │
                                                 │  (what must be built)
                                                 ▼
                                  ┌────────────────────────────────────┐
                                  │  apprt layer                       │
                                  │  [NOT IMPLEMENTED]                 │
                                  │                                    │
                                  │  For each tmux window:             │
                                  │    → create native Ghostty tab     │
                                  │                                    │
                                  │  For each tmux pane:               │
                                  │    → create native Ghostty split   │
                                  │    → backed by tmux Backend (new)  │
                                  │                                    │
                                  │  Requires:                         │
                                  │    backend.zig: Kind = { exec, tmux }│
                                  │    Surface without subprocess      │
                                  └───────────────┬────────────────────┘
                                                  │
                                                  │  renderer reads
                                                  │  Viewer's Terminal
                                                  ▼
                                  ┌────────────────────────────────────┐
                                  │  Ghostty GPU Renderer              │
                                  │  [EXISTS, but not connected to     │
                                  │   tmux Terminal instances]         │
                                  │                                    │
                                  │  Reads screen buffer → pixels      │
                                  │  Native scrollback, selection,     │
                                  │  search, font rendering            │
                                  └───────────────┬────────────────────┘
                                                  │
                                                  ▼
                                            Screen pixels
```

---

## 4. Command-Response Sequence Diagram

Temporal ordering of the complete startup handshake, the most fragile part of the protocol. Each arrow shows direction and content.

```
     Ghostty                                              tmux server
       │                                                       │
       │              tmux -CC sends DCS opener                │
       │◄──────────── ESC P 1000 p ───────────────────────────│
       │                                                       │
       │  dcs.zig: tryHook() → .enter                         │
       │  stream_handler: create Viewer (state=startup_block)  │
       │                                                       │
       │              Initial empty command block              │
       │◄──────────── %begin 1711000000 0 0 ──────────────────│
       │◄──────────── %end 1711000000 0 0 ────────────────────│
       │                                                       │
       │  Viewer: startup_block → startup_session              │
       │                                                       │
       │              Session identification                   │
       │◄──────────── %session-changed $0 main ───────────────│
       │                                                       │
       │  Viewer: startup_session → command_queue              │
       │  Viewer: queues tmux_version command                  │
       │                                                       │
       │  Query tmux version                                   │
       │──────────── display-message -p '#{version}' ─────────►│
       │                                                       │
       │◄──────────── %begin 1711000001 1 0 ──────────────────│
       │◄──────────── 3.5a ───────────────────────────────────│
       │◄──────────── %end 1711000001 1 0 ────────────────────│
       │                                                       │
       │  Viewer: stores version "3.5a"                        │
       │  Viewer: queues list_windows command                  │
       │                                                       │
       │  Query all windows                                    │
       │──────────── list-windows -F '<format>' ──────────────►│
       │                                                       │
       │◄──────────── %begin 1711000002 2 0 ──────────────────│
       │◄──────────── $0 @0 80 24 d962,80x24,0,0,0 ──────────│
       │◄──────────── %end 1711000002 2 0 ────────────────────│
       │                                                       │
       │  Viewer: parse window data                            │
       │  Viewer: syncLayouts() — create pane %0 (80x24)       │
       │  Viewer: create Terminal(80, 24) for pane %0          │
       │  Viewer: emit .windows action                         │
       │  Viewer: queue capture commands for pane %0           │
       │                                                       │
       │  Capture primary scrollback                           │
       │──────────── capture-pane -p -e -q -S - -E -1 -t %0 ─►│
       │                                                       │
       │◄──────────── %begin 1711000003 3 0 ──────────────────│
       │◄──────────── (scrollback content lines...) ──────────│
       │◄──────────── %end 1711000003 3 0 ────────────────────│
       │                                                       │
       │  Viewer: feed scrollback to pane %0 Terminal          │
       │                                                       │
       │  Capture primary visible                              │
       │──────────── capture-pane -p -e -q -t %0 ─────────────►│
       │                                                       │
       │◄──────────── %begin/%end (visible content) ──────────│
       │                                                       │
       │  Capture alternate scrollback                         │
       │──────────── capture-pane -p -e -q -S - -E -1 -t %0 -T►│
       │                                                       │
       │◄──────────── %begin/%end (alt scrollback) ───────────│
       │                                                       │
       │  Capture alternate visible                            │
       │──────────── capture-pane -p -e -q -t %0 -T ──────────►│
       │                                                       │
       │◄──────────── %begin/%end (alt visible) ──────────────│
       │                                                       │
       │  Query terminal state                                 │
       │──────────── list-panes -F '<state-format>' -t %0 ────►│
       │                                                       │
       │◄──────────── %begin 1711000007 7 0 ──────────────────│
       │◄──────────── (cursor_x,cursor_y,shape,modes...) ─────│
       │◄──────────── %end 1711000007 7 0 ────────────────────│
       │                                                       │
       │  Viewer: apply state to Terminal                       │
       │    - cursor position and shape                        │
       │    - insert/wrap/origin/keypad modes                  │
       │    - mouse modes (normal/button/any/sgr)              │
       │    - focus reporting, bracketed paste                 │
       │    - scroll region margins                            │
       │    - tab stops                                        │
       │                                                       │
       │  ════════════════ READY ═══════════════════           │
       │  Command queue empty. Processes async notifications.  │
       │                                                       │
       │              Live output (ongoing)                    │
       │◄──────────── %output %0 hello\015\012 ───────────────│
       │                                                       │
       │  Viewer: decode \015→CR \012→LF                       │
       │  Viewer: feed "hello\r\n" to pane %0 Terminal         │
       │                                                       │
       │              Structure change (user split)            │
       │◄──────────── %layout-change @0 <new-layout> ─────────│
       │                                                       │
       │  Viewer: reparse layout tree                          │
       │  Viewer: detect new pane %1                           │
       │  Viewer: create Terminal for %1                        │
       │  Viewer: prune removed panes (if any)                 │
       │  Viewer: emit .windows                                │
       │  Viewer: queue captures for %1                        │
       │                                                       │
       │              New window                               │
       │◄──────────── %window-add @1 ─────────────────────────│
       │                                                       │
       │  Viewer: queue list-windows to refresh                │
       │──────────── list-windows -F '<format>' ──────────────►│
       │                                                       │
```

---

## 5. Layout Tree Examples

tmux describes pane arrangement as a layout string. The layout parser (`layout.zig`) turns these into a tree.

### 5.1 Single Pane

```
Layout string: "d962,80x24,0,0,0"
Checksum: d962 (CRC16 of "80x24,0,0,0")

Tree:
┌──────────────────────────────┐
│  Layout                      │
│  width: 80, height: 24      │
│  x: 0, y: 0                 │
│  content: .pane { id: 0 }   │
└──────────────────────────────┘
```

### 5.2 Horizontal Split (side by side)

```
Layout string: "a]b2,80x24,0,0{40x24,0,0,1,40x24,41,0,2}"
                                  ▲           ▲           ▲
                                  │           │           │
                            container    left pane   right pane

Tree:
                    ┌─────────────────────────────┐
                    │  Layout (horizontal)         │
                    │  80x24 at (0,0)              │
                    │  content: .horizontal        │
                    └──────────┬──────────────────┘
                               │
                    ┌──────────┴──────────┐
                    ▼                     ▼
          ┌──────────────────┐  ┌──────────────────┐
          │  Layout          │  │  Layout          │
          │  40x24 at (0,0)  │  │  40x24 at (41,0) │
          │  .pane { id: 1 } │  │  .pane { id: 2 } │
          └──────────────────┘  └──────────────────┘
```

### 5.3 Vertical Split (stacked)

```
Layout string: "2f5e,80x24,0,0[80x12,0,0,1,80x12,0,13,2]"
                                  ▲           ▲           ▲
                                  │           │           │
                            container    top pane    bottom pane

Tree:
                    ┌─────────────────────────────┐
                    │  Layout (vertical)           │
                    │  80x24 at (0,0)              │
                    │  content: .vertical          │
                    └──────────┬──────────────────┘
                               │
                    ┌──────────┴──────────┐
                    ▼                     ▼
          ┌──────────────────┐  ┌──────────────────┐
          │  Layout          │  │  Layout          │
          │  80x12 at (0,0)  │  │  80x12 at (0,13) │
          │  .pane { id: 1 } │  │  .pane { id: 2 } │
          └──────────────────┘  └──────────────────┘
```

### 5.4 Complex Nested Layout

```
Layout string: "8901,160x48,0,0{80x48,0,0,1,80x48,81,0[80x24,81,0,2,80x24,81,25,3]}"

Meaning: left pane full-height, right side split top/bottom

Tree:
                    ┌───────────────────────────┐
                    │  Layout (horizontal)       │
                    │  160x48 at (0,0)           │
                    └──────────┬────────────────┘
                               │
                    ┌──────────┴──────────────────┐
                    ▼                              ▼
          ┌──────────────────┐          ┌───────────────────────┐
          │  Layout          │          │  Layout (vertical)    │
          │  80x48 at (0,0)  │          │  80x48 at (81,0)      │
          │  .pane { id: 1 } │          └──────────┬────────────┘
          └──────────────────┘                     │
                                        ┌──────────┴──────────┐
                                        ▼                     ▼
                              ┌──────────────────┐  ┌──────────────────┐
                              │  Layout          │  │  Layout          │
                              │  80x24 at (81,0) │  │  80x24 at (81,25)│
                              │  .pane { id: 2 } │  │  .pane { id: 3 } │
                              └──────────────────┘  └──────────────────┘

Visual representation:
┌────────────────────┬────────────────────┐
│                    │                    │
│                    │     pane %2        │
│     pane %1        │     80x24         │
│     80x48          │                    │
│                    ├────────────────────┤
│                    │                    │
│                    │     pane %3        │
│                    │     80x24         │
│                    │                    │
└────────────────────┴────────────────────┘
```

---

## 6. Protocol Trace Timeline

A sample timeline for debugging, showing the temporal ordering of events with states.

```
Time        Event                                    Viewer State          Action Emitted
──────────  ─────────────────────────────────────    ──────────────────    ──────────────────
T+0.000     DCS hook: params=[1000] final=p          (not created yet)     —
T+0.000     Notification: .enter                     —                     create Viewer
T+0.001     Viewer created                           startup_block         —
T+0.012     Notification: .block_end("")             startup_block         —
T+0.012     State transition                         startup_session       —
T+0.018     Notification: .session_changed($0,main)  startup_session       —
T+0.018     State transition                         command_queue         .command("display-message...")
T+0.025     Notification: .block_end("3.5a")         command_queue         .command("list-windows...")
T+0.032     Notification: .block_end("$0 @0 80 ...")  command_queue        .windows([{@0, 80x24, [%0]}])
            ↳ syncLayouts: create pane %0                                  .command("capture-pane...")
T+0.040     Notification: .block_end(<scrollback>)   command_queue         .command("capture-pane...")
            ↳ receivedPaneHistory: feed to Terminal
T+0.048     Notification: .block_end(<visible>)      command_queue         .command("capture-pane -T...")
            ↳ receivedPaneVisible: feed to Terminal
T+0.055     Notification: .block_end(<alt scroll>)   command_queue         .command("capture-pane -T...")
            ↳ receivedPaneHistory (alt screen)
T+0.062     Notification: .block_end(<alt visible>)  command_queue         .command("list-panes...")
            ↳ receivedPaneVisible (alt screen)
T+0.070     Notification: .block_end(<state>)        command_queue         —
            ↳ receivedPaneState: apply cursor,
              modes, scroll region, tabs
T+0.070     Command queue empty                      command_queue         — (READY)
            ═══════════════════════════════════════════════════════════════════════════
T+1.500     Notification: .output(%0, "$ ls\r\n")   command_queue         —
            ↳ receivedOutput: feed to pane %0 Term
T+3.200     Notification: .layout_change(@0, ...)    command_queue         .windows([{@0,...[%0,%1]}])
            ↳ layoutChanged: new pane %1 found                            .command("capture-pane...")
T+3.210     Notification: .block_end(<pane1 hist>)   command_queue         .command("capture-pane...")
            ... (4 captures + state for pane %1)
T+5.000     Notification: .window_add(@1)            command_queue         .command("list-windows...")
            ↳ queues list_windows refresh
T+5.010     Notification: .block_end(<windows>)      command_queue         .windows([{@0,...},{@1,...}])
            ↳ syncLayouts for both windows                                .command("capture-pane...")
```

---

## 7. Notification Type Coverage Map

Which protocol notifications are handled at each layer.

```
Protocol Message          Parser    Viewer     stream_handler    GUI
                         (control)  (viewer)   (glue)           (apprt)
────────────────────     ────────   ────────   ──────────────   ────────
%begin/%end/%error         YES        YES        YES              —
%output                    YES        YES        (via viewer)     —
%extended-output            NO         —          —               —
%session-changed           YES        YES        (via viewer)     —
%session-renamed            NO         —          —               —
%sessions-changed          YES       IGNORED      —               —
%session-window-changed     NO         —          —               —
%window-add                YES        YES        (via viewer)     —
%window-close               NO         —          —               —
%window-renamed            YES       IGNORED      —               —
%window-pane-changed       YES       IGNORED      —               —
%layout-change             YES        YES        (via viewer)     —
%client-detached           YES       IGNORED      —               —
%client-session-changed    YES       IGNORED      —               —
%paste-buffer-changed       NO         —          —               —
%paste-buffer-deleted       NO         —          —               —
%pane-mode-changed          NO         —          —               —
%pause                      NO         —          —               —
%continue                   NO         —          —               —
%subscription-changed       NO         —          —               —
%unlinked-window-*          NO         —          —               —
%exit                      YES        YES        YES              —

Commands Sent             Parser    Viewer     stream_handler    GUI
────────────────────     ────────   ────────   ──────────────   ────────
display-message            —         YES        YES (writes)     —
list-windows               —         YES        YES (writes)     —
list-panes                 —         YES        YES (writes)     —
capture-pane               —         YES        YES (writes)     —
send-keys                  —          NO         —             NOT IMPL
refresh-client -C          —          NO         —             NOT IMPL
new-window                 —          NO         —             NOT IMPL
split-window               —          NO         —             NOT IMPL
kill-window                —          NO         —             NOT IMPL
kill-pane                  —          NO         —             NOT IMPL
resize-pane                —          NO         —             NOT IMPL
select-window              —          NO         —             NOT IMPL
select-pane                —          NO         —             NOT IMPL
refresh-client -f          —          NO         —             NOT IMPL
```

---

## 8. Architecture Layer Map

How the source files organize into layers.

```
┌───────────────────────────────────────────────────────────────────────┐
│                        USER-FACING UI                                 │
│                                                                       │
│  src/apprt/ (GTK, macOS AppKit)                                      │
│    Surface.init() → always creates termio.Exec today                 │
│    Action: new_window, new_tab, new_split, close, resize             │
│    Message: carries events between termio and UI                     │
│                                                        [NOT CONNECTED│
│                                                         TO TMUX]     │
├───────────────────────────────────────────────────────────────────────┤
│                     TERMINAL I/O LAYER                                │
│                                                                       │
│  src/termio/backend.zig                                              │
│    Kind = enum { exec }  ← needs { exec, tmux }                     │
│    Backend = union(Kind) { exec: Exec }                              │
│                                                                       │
│  src/termio/Exec.zig                                                 │
│    PTY subprocess management (the only backend today)                │
│                                                                       │
│  src/termio/stream_handler.zig                                       │
│    dcsCommand() — bridges DCS events to Viewer                       │
│    .windows => { // TODO }  ← THE GAP                                │
│                                                                       │
├───────────────────────────────────────────────────────────────────────┤
│                   TMUX SEMANTICS LAYER                                │
│                                                                       │
│  src/terminal/tmux/viewer.zig (2284 lines)                           │
│    State machine, reconciliation loop, Terminal management            │
│    Action emission (.command, .windows, .exit)                        │
│                                                                       │
│  src/terminal/tmux/output.zig (591 lines)                            │
│    Format variable parsing, typed struct generation                   │
│                                                                       │
├───────────────────────────────────────────────────────────────────────┤
│                   TMUX PROTOCOL LAYER                                 │
│                                                                       │
│  src/terminal/tmux/control.zig (840 lines)                           │
│    Byte-by-byte state machine parser                                 │
│    Notification tagged union (12 variants)                            │
│                                                                       │
│  src/terminal/tmux/layout.zig (639 lines)                            │
│    Layout string → tree parser, CRC16 checksum                       │
│                                                                       │
├───────────────────────────────────────────────────────────────────────┤
│                   VT / DCS LAYER                                      │
│                                                                       │
│  src/terminal/dcs.zig (431 lines)                                    │
│    DCS hook: detects ESC P 1000 p, routes to control parser          │
│                                                                       │
│  src/terminal/main.zig                                               │
│    Conditional export: tmux module enabled when oniguruma available   │
│                                                                       │
│  src/terminal/build_options.zig                                      │
│    tmux_control_mode = oniguruma (build flag)                        │
│                                                                       │
├───────────────────────────────────────────────────────────────────────┤
│                   RE-EXPORT / MODULE LAYER                            │
│                                                                       │
│  src/terminal/tmux.zig (14 lines)                                    │
│    Re-exports: ControlParser, ControlNotification, Layout, Viewer    │
└───────────────────────────────────────────────────────────────────────┘
```

---

## 9. Debugging Decision Tree

When something goes wrong, use this to identify which layer to investigate.

```
Symptom: tmux -CC produces no visible output in Ghostty
                              │
                              ▼
                    Are there any tmux-related log lines?
                    (run Ghostty from terminal, grep tmux)
                              │
                    ┌─────────┴──────────┐
                    │ NO                 │ YES
                    ▼                    ▼
           DCS not detected.       Do you see "Notification: enter"?
           Check:                         │
           - Is tmux sending          ┌───┴────┐
             ESC P 1000 p?            │NO      │YES
           - Is dcs.zig               ▼        ▼
             tryHook() being    Viewer not    Do you see "action=...windows"?
             called?            created.           │
           - Is tmux_control_   Check stream  ┌────┴─────┐
             mode build flag    _handler      │NO        │YES
             enabled?           .enter path   ▼          ▼
                                           Viewer     .windows action
                                           not        exists but
                                           reaching   // TODO drops it.
                                           command_   This is THE GAP.
                                           queue.
                                           Check:
                                           - startup_block
                                             → startup_session
                                             transition
                                           - Is %session-
                                             changed arriving?
                                           - Is Viewer going
                                             to defunct?
                                             (check logs for
                                              error messages)

Symptom: Wrong pane content
                              │
                              ▼
                    Is %output being received for this pane?
                              │
                    ┌─────────┴──────────┐
                    │ NO                 │ YES
                    ▼                    ▼
           Check pane ID.          Is the octal decoding correct?
           Is the pane in               │
           the Viewer's            ┌────┴─────┐
           panes map?              │NO        │YES
           Was it initialized?     ▼          ▼
           (capture-pane      Check control  Is the VT parser
            completed?)       .zig escape    interpreting
                              handling       correctly for
                                             TERM=tmux/screen?

Symptom: Viewer enters defunct state
                              │
                              ▼
                    Check the error logged at viewer.zig defunct().
                    Common causes:
                    - Parse error in list-windows output
                    - Parse error in capture-pane output
                    - Parse error in list-panes output
                    - Unexpected notification during startup
                    - @intCast overflow (large dimensions)
```
