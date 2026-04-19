# Data Flow Diagrams: tmux Control Mode

## 1. iTerm2 with tmux Control Mode (Reference Implementation)

This is how data flows today in a working tmux control mode integration.

### 1.1 Startup / Session Discovery

```
User runs: tmux -CC attach -t mysession
                    │
                    ▼
            ┌──────────────┐
            │  tmux client  │  (started by the shell inside iTerm2)
            │  (-CC mode)   │
            └──────┬───────┘
                   │
                   │  connects via unix socket
                   ▼
            ┌──────────────┐
            │  tmux server  │  (already running, owns the session)
            └──────┬───────┘
                   │
                   │  stdout to iTerm2's PTY:
                   │    ESC P 1000 p          ← DCS opener
                   │    %begin 0 0 0          ← initial block
                   │    %end 0 0 0
                   │    %session-changed $0 mysession
                   │
                   ▼
            ┌──────────────────────────┐
            │  iTerm2 DCS detector     │
            │  (terminal VT parser)    │
            └──────────┬───────────────┘
                       │
                       │  recognizes ESC P 1000 p
                       │  switches to control mode
                       ▼
            ┌──────────────────────────┐
            │  iTerm2 Control Mode     │
            │  Protocol Parser         │
            │  (parses %notifications) │
            └──────────┬───────────────┘
                       │
                       │  sends commands to tmux via stdin:
                       │    list-windows -F '...'
                       │    list-panes -F '...'
                       │    capture-pane -p -e -q ...
                       ▼
            ┌──────────────────────────┐
            │  iTerm2 Session Manager  │
            │  (reconciles tmux state  │
            │   with native UI)        │
            └──────────┬───────────────┘
                       │
          ┌────────────┼────────────┐
          ▼            ▼            ▼
    ┌──────────┐ ┌──────────┐ ┌──────────┐
    │ Native   │ │ Native   │ │ Native   │
    │ Tab 1    │ │ Tab 2    │ │ Tab 3    │   ← one tab per tmux window
    │ (win @0) │ │ (win @1) │ │ (win @2) │
    └────┬─────┘ └──────────┘ └──────────┘
         │
    ┌────┼────────────┐
    ▼                  ▼
┌──────────┐    ┌──────────┐
│ Native   │    │ Native   │
│ Split A  │    │ Split B  │    ← one split per tmux pane
│ (pane %0)│    │ (pane %1)│
└──────────┘    └──────────┘
```

### 1.2 Steady-State: User Types in a Pane

```
┌─────────────┐                                              ┌──────────────┐
│  User types  │                                              │  tmux server │
│  "ls -la"    │                                              │              │
└──────┬──────┘                                              └──────┬───────┘
       │                                                            │
       │ keystrokes                                                 │
       ▼                                                            │
┌──────────────────┐                                                │
│  iTerm2 Native   │                                                │
│  Split (pane %0) │                                                │
└──────┬───────────┘                                                │
       │                                                            │
       │ iTerm2 knows this split maps to tmux pane %0               │
       │ so it sends:                                               │
       │   send-keys -t %0 'ls -la' Enter                           │
       │──────────────────────────────────────────────────────────►  │
       │                                                            │
       │                                     tmux routes keystrokes │
       │                                     to the shell in pane %0│
       │                                              │             │
       │                                              ▼             │
       │                                     ┌──────────────┐       │
       │                                     │  shell (zsh)  │       │
       │                                     │  in pane %0   │       │
       │                                     └──────┬───────┘       │
       │                                            │               │
       │                                            │ shell produces │
       │                                            │ output bytes   │
       │                                            ▼               │
       │                                     tmux captures output   │
       │                                     and sends:             │
       │   %output %0 file1.txt\015\012file2.txt\015\012...         │
       │◄──────────────────────────────────────────────────────────  │
       │                                                            │
       ▼                                                            │
┌──────────────────────────┐                                        │
│  iTerm2 Protocol Parser  │                                        │
│  1. parse %output %0     │                                        │
│  2. decode octal escapes │                                        │
│     \015 → CR, \012 → LF │                                        │
│  3. identify pane %0     │                                        │
└──────┬───────────────────┘                                        │
       │                                                            │
       │ decoded terminal bytes                                     │
       ▼                                                            │
┌──────────────────────────┐                                        │
│  iTerm2 VT Parser        │                                        │
│  (per-pane terminal      │                                        │
│   emulator instance)     │                                        │
│                          │                                        │
│  Interprets escape seqs  │                                        │
│  for TERM=tmux/screen    │                                        │
└──────┬───────────────────┘                                        │
       │                                                            │
       │ screen updates (text, colors, cursor moves)                │
       ▼                                                            │
┌──────────────────────────┐
│  iTerm2 Native Split     │
│  Renderer                │
│                          │
│  - Native scrollback     │
│  - Native selection      │
│  - Native search (Cmd+F) │
│  - GPU-accelerated       │
└──────────────────────────┘
       │
       ▼
    Screen pixels
```

### 1.3 Steady-State: Structural Changes (New Window, Split, Close)

```
User presses Cmd+T (new tab in iTerm2)
       │
       ▼
┌──────────────────────────┐         ┌──────────────┐
│  iTerm2 Control Mode     │         │  tmux server │
│  Manager                 │         │              │
│                          │         │              │
│  Recognizes Cmd+T as     │         │              │
│  "create new tmux window"│         │              │
│                          │         │              │
│  Sends:                  │         │              │
│    new-window            │────────►│              │
│                          │         │              │
│                          │         │  Creates new │
│                          │         │  window @3   │
│                          │         │              │
│  Receives:               │         │              │
│    %window-add @3        │◄────────│              │
│                          │         │              │
│  Queries:                │         │              │
│    list-windows -F '...' │────────►│              │
│                          │         │              │
│  Receives:               │         │              │
│    %begin ... %end       │◄────────│              │
│    (window list data)    │         │              │
│                          │         │              │
│  Creates native tab for  │         │              │
│  window @3               │         │              │
└──────────┬───────────────┘         └──────────────┘
           │
           ▼
    ┌──────────────────┐
    │  New Native Tab  │
    │  (window @3)     │
    │  with native     │
    │  split for %4    │
    └──────────────────┘


User presses Cmd+D (split pane in iTerm2)
       │
       ▼
┌──────────────────────────┐         ┌──────────────┐
│  iTerm2 Control Mode     │         │  tmux server │
│                          │         │              │
│  Sends:                  │         │              │
│    split-window -t %0    │────────►│              │
│                          │         │              │
│  Receives:               │         │              │
│    %layout-change @0 ... │◄────────│              │
│    (new layout with      │         │              │
│     two panes)           │         │              │
│                          │         │              │
│  Parses new layout tree  │         │              │
│  Detects new pane %5     │         │              │
│                          │         │              │
│  Captures content:       │         │              │
│    capture-pane ... -t %5│────────►│              │
│                          │         │              │
│  Creates native split    │         │              │
│  for pane %5             │         │              │
└──────────┬───────────────┘         └──────────────┘
           │
           ▼
    ┌────────────────────────────┐
    │  Tab (window @0)           │
    │  ┌────────┐ ┌────────┐    │
    │  │Split A │ │Split B │    │
    │  │(pane%0)│ │(pane%5)│    │
    │  └────────┘ └────────┘    │
    └────────────────────────────┘
```

### 1.4 Resize Flow

```
User drags iTerm2 window edge or split handle
       │
       ▼
┌──────────────────────────┐         ┌──────────────┐
│  iTerm2 Control Mode     │         │  tmux server │
│                          │         │              │
│  Window resized to       │         │              │
│  120x40 characters       │         │              │
│                          │         │              │
│  Sends:                  │         │              │
│    refresh-client -C     │         │              │
│    120x40                │────────►│              │
│                          │         │              │
│                          │         │  Recalculates│
│                          │         │  all pane    │
│                          │         │  dimensions  │
│                          │         │              │
│  Receives:               │         │              │
│    %layout-change @0     │◄────────│              │
│    (new layout with      │         │              │
│     updated dimensions)  │         │              │
│                          │         │              │
│  Updates all native      │         │              │
│  splits to match new     │         │              │
│  pane dimensions         │         │              │
└──────────────────────────┘         └──────────────┘
```

### 1.5 Detach / Reattach Flow

```
User closes iTerm2 (or runs detach)
       │
       ▼
┌──────────────────────────┐         ┌──────────────┐
│  iTerm2 Control Mode     │         │  tmux server │
│                          │         │              │
│  Sends empty line ("")   │────────►│              │
│  to signal detach        │         │              │
│                          │         │  Detaches    │
│  Receives:               │         │  client      │
│    %exit                 │◄────────│              │
│    ESC \ (ST)            │         │              │
│                          │         │  Server      │
│  Tears down all native   │         │  continues   │
│  tabs/splits             │         │  running     │
│  Exits control mode      │         │  with all    │
└──────────────────────────┘         │  sessions    │
                                     │  intact      │
                                     └──────┬───────┘
          Some time later...                │
                                            │ shells still running
User opens iTerm2 again                     │ scrollback preserved
runs: tmux -CC attach -t mysession          │
       │                                    │
       ▼                                    │
┌──────────────────────────┐                │
│  iTerm2 Control Mode     │                │
│                          │                │
│  Full startup handshake  │◄───────────────┘
│  (DCS, session-changed,  │
│   list-windows,          │
│   capture-pane for each) │
│                          │
│  Recreates all native    │
│  tabs/splits with        │
│  content from captures   │
│                          │
│  Exactly as before close │
└──────────────────────────┘
```

---

## 2. Ghostty with tmux Control Mode (Projected Integration)

This shows how data would flow with Ghostty once tmux control mode is fully integrated. Areas that are currently implemented are marked, and the gap is called out.

### 2.1 Startup / Session Discovery

```
User runs: tmux -CC attach -t mysession  (in a Ghostty surface)
                    │
                    ▼
            ┌──────────────┐
            │  tmux client  │  (subprocess in Ghostty's PTY)
            │  (-CC mode)   │
            └──────┬───────┘
                   │
                   │  stdout to Ghostty's PTY read thread:
                   │    ESC P 1000 p
                   │    %begin 0 0 0 / %end 0 0 0
                   │    %session-changed $0 mysession
                   │
                   ▼
            ┌──────────────────────────┐
            │  Ghostty VT Stream       │  [IMPLEMENTED]
            │  Parser (src/terminal/)  │
            │                          │
            │  Detects DCS param=1000  │
            │  final='p'               │
            └──────────┬───────────────┘
                       │
                       │  hooks into DCS handler
                       ▼
            ┌──────────────────────────┐
            │  dcs.zig Handler         │  [IMPLEMENTED]
            │                          │
            │  Creates ControlParser   │
            │  Emits .enter            │
            │  Routes bytes via put()  │
            └──────────┬───────────────┘
                       │
                       │  byte-by-byte to control parser
                       ▼
            ┌──────────────────────────┐
            │  control.zig Parser      │  [IMPLEMENTED - 26 tests]
            │                          │
            │  State machine:          │
            │  idle → notification     │
            │      → block → idle      │
            │                          │
            │  Emits Notification      │
            │  tagged union values     │
            └──────────┬───────────────┘
                       │
                       │  Notification values
                       ▼
            ┌──────────────────────────┐
            │  stream_handler.zig      │  [IMPLEMENTED]
            │  dcsCommand()            │
            │                          │
            │  .enter → create Viewer  │
            │  other  → viewer.next()  │
            └──────────┬───────────────┘
                       │
                       │  feeds notifications to Viewer
                       ▼
            ┌──────────────────────────────────────────────┐
            │  viewer.zig Viewer                           │  [IMPLEMENTED - 8 tests]
            │                                              │
            │  State machine:                              │
            │  startup_block → startup_session             │
            │       → command_queue (main operating state) │
            │                                              │
            │  Sends commands to tmux:                     │
            │    display-message (version)                 │
            │    list-windows -F '...'                     │
            │    capture-pane -p -e -q ... (per pane)      │
            │    list-panes -F '...' (terminal state)      │
            │                                              │
            │  Creates Terminal instance per pane           │
            │  Populates with captured scrollback+visible  │
            │  Syncs cursor, modes, mouse, scroll region   │
            │                                              │
            │  Emits Actions:                              │
            │    .command → send to tmux stdin              │
            │    .windows → here are the windows/panes     │
            │    .exit    → tear down                       │
            └──────────┬──────────────────┬────────────────┘
                       │                  │
          .command     │                  │  .windows
          [IMPLEMENTED]│                  │  [NOT IMPLEMENTED <<<]
                       ▼                  ▼
            ┌──────────────┐    ┌─────────────────────────────────┐
            │ queue write  │    │  stream_handler.zig:456-458     │
            │ to tmux PTY  │    │                                 │
            │ stdin        │    │  .windows => {                  │
            └──────────────┘    │      // TODO                    │
                                │  },                             │
                                │                                 │
                                │  *** THIS IS THE GAP ***        │
                                └─────────────────────────────────┘
                                           │
                                           │ (what SHOULD happen)
                                           ▼
                                ┌─────────────────────────────────┐
                                │  apprt layer                    │
                                │  (NOT YET IMPLEMENTED)          │
                                │                                 │
                                │  Create native tabs for each    │
                                │  tmux window                    │
                                │                                 │
                                │  Create native splits for each  │
                                │  tmux pane                      │
                                │                                 │
                                │  Each surface backed by a tmux  │
                                │  backend (not exec/PTY)         │
                                │                                 │
                                │  Requires:                      │
                                │  - New Backend Kind (not exec)  │
                                │  - Surface without subprocess   │
                                │  - Renderer reads Viewer's      │
                                │    Terminal instances            │
                                └─────────────────────────────────┘
```

### 2.2 Steady-State: User Types in a Pane (Projected)

```
┌─────────────┐
│  User types  │
│  "ls -la"    │
└──────┬──────┘
       │
       │ keystrokes (macOS key events)
       ▼
┌──────────────────────────┐
│  Ghostty apprt surface   │
│  (native split for %0)   │  [NOT YET IMPLEMENTED]
│                          │
│  Surface knows it maps   │
│  to tmux pane %0         │
└──────┬───────────────────┘
       │
       │  translates keystrokes to tmux command:
       │    send-keys -t %0 'l' 's' ' ' '-' 'l' 'a' Enter
       │                                                        [NOT YET IMPLEMENTED]
       ▼
┌──────────────────────────┐         ┌──────────────┐
│  stream_handler.zig      │         │  tmux server │
│  queue write             │────────►│              │
│  (already works for      │  stdin  │  routes keys │
│   .command actions)      │         │  to shell    │
└──────────────────────────┘         └──────┬───────┘
                                            │
                                            │ shell output
                                            ▼
                                     ┌──────────────┐
                                     │  tmux server │
                                     │  sends:      │
                                     │  %output %0  │
                                     │  <escaped>   │
                                     └──────┬───────┘
                                            │
                                            │ bytes through PTY
                                            ▼
┌──────────────────────────┐
│  control.zig Parser      │  [IMPLEMENTED]
│  parses %output %0       │
│  extracts pane ID + data │
└──────────┬───────────────┘
           │
           │ Notification::output
           ▼
┌──────────────────────────┐
│  viewer.zig Viewer       │  [IMPLEMENTED]
│                          │
│  1. Looks up pane %0     │
│  2. Decodes octal escapes│
│  3. Feeds decoded bytes  │
│     to pane's Terminal   │
│     via VT stream        │
│                          │
│  Terminal instance now   │
│  has updated screen      │
│  content                 │
└──────────┬───────────────┘
           │
           │ Terminal screen state updated
           ▼
┌──────────────────────────┐
│  Ghostty renderer        │  [NOT YET CONNECTED]
│  (per-surface)           │
│                          │
│  Reads Terminal screen   │
│  buffer                  │
│  Renders with GPU        │
│                          │
│  Native features:        │
│  - Scrollback (from      │
│    capture-pane history) │
│  - Selection (native)    │
│  - Search (Cmd+F)        │
│  - Font rendering        │
└──────────────────────────┘
       │
       ▼
    Screen pixels
```

### 2.3 Steady-State: Structural Changes (Projected)

```
User presses Cmd+T (Ghostty new tab keybinding)
       │
       ▼
┌──────────────────────────┐         ┌──────────────┐
│  Ghostty apprt           │         │  tmux server │
│  [NOT YET IMPLEMENTED]   │         │              │
│                          │         │              │
│  Recognizes Cmd+T in     │         │              │
│  tmux control mode       │         │              │
│                          │         │              │
│  Sends via Viewer:       │         │              │
│    new-window            │────────►│              │
│                          │         │              │
│                          │         │  Creates @3  │
│  Receives:               │         │              │
│    %window-add @3        │◄────────│              │
│                          │   [IMPLEMENTED in      │
│  Viewer re-queries       │    control.zig and     │
│  list-windows            │    viewer.zig]         │
│  Emits .windows action   │         │              │
│                          │         │              │
│  apprt creates native    │         │              │
│  tab for @3              │         │              │
│  [NOT YET IMPLEMENTED]   │         │              │
└──────────────────────────┘         └──────────────┘
```

### 2.4 Architecture Comparison: What Changes

```
TODAY (Ghostty normal terminal with tmux):
──────────────────────────────────────────

┌─────────────────────────────────────────────────┐
│  Ghostty Surface                                │
│  ┌──────────────────────────────────────────┐   │
│  │  termio.Exec backend                     │   │
│  │  (PTY subprocess)                        │   │
│  │                                          │   │
│  │  tmux client ──► tmux draws its own TUI  │   │
│  │  inside the PTY ──► Ghostty just renders │   │
│  │  whatever bytes come out                 │   │
│  └──────────────────────────────────────────┘   │
│                                                 │
│  One surface. tmux owns the layout.             │
│  Ghostty sees pane borders as characters.       │
│  No native tabs, splits, scrollback, search.    │
└─────────────────────────────────────────────────┘


PROJECTED (Ghostty with tmux control mode):
───────────────────────────────────────────

┌─────────────────────────────────────────────────┐
│  Parent Surface (hidden or status-only)         │
│  ┌──────────────────────────────────────────┐   │
│  │  termio.Exec backend (PTY)               │   │
│  │  tmux -CC client runs here               │   │
│  │  DCS detected → control.zig → viewer.zig │   │
│  └──────────────────────────────────────────┘   │
└───────────────────────┬─────────────────────────┘
                        │
        .windows action │ (viewer emits window/pane data)
        .command action │ (send-keys, new-window, etc.)
                        │
    ┌───────────────────┼───────────────────┐
    ▼                   ▼                   ▼
┌──────────┐     ┌──────────┐        ┌──────────┐
│ Native   │     │ Native   │        │ Native   │
│ Tab 1    │     │ Tab 2    │        │ Tab 3    │
│ (win @0) │     │ (win @1) │        │ (win @2) │
│          │     │          │        │          │
│┌────┬───┐│     │┌────────┐│        │┌────────┐│
││Spl │Spl││     ││ Split  ││        ││ Split  ││
││ A  │ B ││     ││ (pane  ││        ││ (pane  ││
││%0  │%1 ││     ││  %2)   ││        ││  %3)   ││
│└────┴───┘│     │└────────┘│        │└────────┘│
└──────────┘     └──────────┘        └──────────┘

Each split is backed by a tmux Backend (not exec).
Each split's renderer reads the Viewer's Terminal for that pane.
Keystrokes in a split → send-keys -t %<id> → tmux server.
Resize → refresh-client -C WxH → tmux recalculates layout.
```

### 2.5 The Integration Gap (Current State)

```
                    IMPLEMENTED                          NOT IMPLEMENTED
              ◄────────────────────►              ◄──────────────────────►

 tmux      DCS       control.zig    viewer.zig    stream_     apprt     Screen
 server    handler   Parser         Viewer        handler

   │          │          │              │            │           │          │
   │──bytes──►│          │              │            │           │          │
   │          │──put()──►│              │            │           │          │
   │          │          │──Notif──────►│            │           │          │
   │          │          │              │──Action───►│           │          │
   │          │          │              │            │           │          │
   │          │          │              │  .command  │           │          │
   │◄─────────┼──────────┼──────────────┼───stdin────│           │          │
   │          │          │              │            │           │          │
   │          │          │              │  .windows  │           │          │
   │          │          │              │──Action───►│           │          │
   │          │          │              │            │──// TODO─►│          │
   │          │          │              │            │    ▲      │          │
   │          │          │              │            │    │      │          │
   │          │          │              │            │  THE GAP  │          │
   │          │          │              │            │    │      │          │
   │          │          │              │            │    ▼      │          │
   │          │          │              │            │  Nothing  │          │
   │          │          │              │            │  happens  │          │
   │          │          │              │            │  here     │          │
   │          │          │              │            │           │          │

What needs to happen at THE GAP:
1. .windows action → create/update native tabs and splits
2. Each surface gets a tmux Backend (new Kind, not exec)
3. Renderer thread reads Viewer's Terminal for that pane
4. Input thread sends send-keys for that pane
5. Resize events send refresh-client -C WxH
```

### 2.6 Flow Control (Projected)

```
Fast-producing pane (e.g., `find / -name '*.log'`)

tmux server                    Ghostty
    │                              │
    │  At startup, Ghostty sends:  │
    │    refresh-client -f         │
    │    pause-after=1             │
    │◄─────────────────────────────│  [NOT YET IMPLEMENTED]
    │                              │
    │  %extended-output %0 0 :     │
    │  <data>                      │  [NOT YET IMPLEMENTED -
    │──────────────────────────────►│   %extended-output not
    │                              │   in Notification union]
    │  %extended-output %0 150 :   │
    │  <data>                      │  (150ms behind real-time)
    │──────────────────────────────►│
    │                              │
    │  %extended-output %0 800 :   │
    │  <data>                      │  (800ms behind)
    │──────────────────────────────►│
    │                              │
    │  Exceeds pause-after=1s:     │
    │  %pause %0                   │
    │──────────────────────────────►│  [NOT YET IMPLEMENTED]
    │                              │
    │  (tmux stops sending %output │
    │   for pane %0)               │
    │                              │
    │  Ghostty catches up,         │
    │  renders buffered output,    │
    │  then sends:                 │
    │    refresh-client -A         │
    │    '%0:continue'             │
    │◄─────────────────────────────│  [NOT YET IMPLEMENTED]
    │                              │
    │  %continue %0                │
    │──────────────────────────────►│
    │                              │
    │  Output resumes normally     │
    │                              │

Without flow control (current state):
- If client falls >300 seconds behind, tmux disconnects with:
  %exit "too far behind"
- This is a real risk for fast-producing commands
```
