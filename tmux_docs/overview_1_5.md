# Ghostty Tmux Control Mode: Deep Understanding (Sections 1–5)

> **Purpose**: Build foundational understanding of tmux, tmux control mode,
> and Ghostty's current state. This is research — not a code proposal.
>
> **Evidence classification used throughout**:
> - **(doc)** = from official documentation or man pages
> - **(code)** = verified by reading Ghostty source code
> - **(issue)** = from GitHub issues, PRs, or discussions
> - **(observed)** = from runtime experiments
> - **(inferred)** = reasonable conclusion not directly confirmed — labeled explicitly

---

## Section 1: First-Principles Explanation of tmux and Control Mode

### 1.1 What is tmux?

tmux is a **terminal multiplexer**. It sits between your shell (e.g., zsh,
bash) and your terminal emulator (e.g., Ghostty, iTerm2, Terminal.app).

What it does:

- **Multiple sessions in one terminal window.** You can have many shell
  sessions — tabs, split panes — all inside one terminal window, managed
  by tmux.
- **Session persistence.** If your terminal closes (laptop lid closes,
  SSH disconnects), the tmux server keeps running. You can reattach later
  and everything is exactly where you left it.
- **Remote session survival.** When working over SSH, tmux lets you
  detach from a session and reattach from a different machine or
  connection.

tmux is a **server-client architecture**:
- The **tmux server** runs in the background. It manages windows, panes,
  and the actual shell processes.
- A **tmux client** connects to the server. A client is what you interact
  with. When you type `tmux` in your terminal, you start a client.

**(doc)** Source: tmux(1) man page.

### 1.2 How "normal tmux in a terminal" works

When you run `tmux` in a terminal like Ghostty:

1. tmux starts a server (if one isn't running) and a client.
2. The client takes over your terminal window.
3. tmux draws its own UI inside your terminal: a status bar at the bottom,
   split panes, window indicators.
4. tmux reads your keystrokes and routes them — some go to the shell
   running inside a pane, some are intercepted by tmux itself (e.g.,
   `Ctrl-b c` to create a new window).
5. tmux sends VT100/xterm escape sequences to your terminal emulator to
   draw pane content, borders, status bars, etc.

In this mode, tmux is just another program running inside the terminal.
The terminal emulator (Ghostty) has **no idea** that tmux is running —
it just sees a stream of escape sequences. Ghostty cannot:
- Know how many panes tmux has
- Provide native tabs or split views for tmux windows
- Let you use OS-level scrollback, search, or selection inside tmux panes
- Offer native window management (drag-to-resize, native keybindings)

The terminal is "dumb" with respect to tmux — it just renders whatever
bytes tmux sends.

### 1.3 What is tmux control mode?

Control mode is an **alternative client interface** to the tmux server.
Instead of tmux drawing a TUI inside your terminal, tmux sends
**structured text messages** over stdout that describe what is happening
in the session.

**(doc)** From the tmux wiki (https://github.com/tmux/tmux/wiki/Control-Mode):
> Control mode is a special mode where tmux accepts commands as lines of
> text on standard input and outputs notifications as text on standard
> output.

Key differences from normal mode:

| Aspect | Normal tmux | Control mode |
|--------|------------|--------------|
| UI drawing | tmux draws its own TUI in your terminal | tmux sends structured text messages |
| Pane borders | Drawn by tmux as box-drawing characters | Not drawn — the client decides how to display panes |
| Status bar | Drawn by tmux at the bottom | Not drawn — the client gets session/window info as data |
| Scrollback | Managed by tmux internally | Pane content sent as data to the client |
| Input routing | tmux intercepts keystrokes | The client decides what to send to tmux |
| Who's in charge | tmux controls the visual layout | The client application controls everything visible |

Control mode turns tmux from "a TUI app that takes over your terminal"
into "a session management protocol that a smart client can drive."

### 1.4 How to enter control mode

There are two flags **(doc)**:

- `tmux -C` — starts control mode with echo enabled (for human testing).
  You see what you type. Useful for debugging.
- `tmux -CC` — starts control mode with echo disabled and most terminal
  features off. This is what terminal emulators use.

You can also attach to an existing session:
```
tmux -CC attach -t mysession
tmux -CC new-session -s work
```

### 1.5 What you would see if you ran `tmux -CC`

If you open a shell and run `tmux -CC`, you would see something like:

```
%begin 1711000000 0 0
%end 1711000000 0 0
%session-changed $0 default
```

And then... nothing visible. No TUI. No status bar. The terminal just
sits there. But tmux is running, and if you type a tmux command (like
`list-windows`) and press Enter, you'd see:

```
%begin 1711000001 1 0
0: zsh* (1 panes) [80x24] [layout d962,80x24,0,0,0] @0 (active)
%end 1711000001 1 0
```

If someone types in a tmux pane, you'd see:

```
%output %0 hello\015\012
```

This is the **protocol**. Every message starts with `%`. Everything is
plain text. A program can parse this and build its own UI.

### 1.6 The control mode protocol messages

#### 1.6.1 Command blocks: %begin / %end / %error

Every command you send to tmux produces a response wrapped in guard lines.

**Successful command:**
```
%begin <timestamp> <command_number> <flags>
<output lines...>
%end <timestamp> <command_number> <flags>
```

**Failed command:**
```
%begin <timestamp> <command_number> <flags>
<error message>
%error <timestamp> <command_number> <flags>
```

- `<timestamp>` — seconds since Unix epoch (integer)
- `<command_number>` — sequential number, starting at 0
- `<flags>` — currently always 0 (reserved for future use)

The timestamp and command number on `%begin` **must match** those on the
corresponding `%end` or `%error`. This lets a client correlate responses
to commands.

**Important subtlety** **(issue)**: A line inside a block payload might
coincidentally start with `%end` or `%error` (e.g., a shell command that
outputs the literal text `%end`). A correct parser must verify the
**full guard-line format** (timestamp, command number, flags) — not just
the `%end` prefix. This was the subject of Ghostty issue #11395 and a
parser bug fix.

#### 1.6.2 %output and %extended-output

```
%output %<pane_id> <escaped_data>
%extended-output %<pane_id> <ms_behind> : <escaped_data>
```

These carry terminal output from a pane. When a program running in a
tmux pane produces output (text, escape sequences, etc.), tmux sends it
to the control mode client as `%output`.

`%extended-output` is the flow-control-aware variant (see 1.6.5 below).
It includes `<ms_behind>`, the number of milliseconds the pane's output
is behind real-time.

The `<escaped_data>` contains the raw terminal output, but with escaping
applied (see 1.6.4).

#### 1.6.3 Async notifications

These are sent by tmux without being requested — they notify the client
of state changes:

**Session notifications:**
| Message | Meaning |
|---------|---------|
| `%session-changed $<id> <name>` | Client's attached session changed |
| `%session-renamed $<id> <name>` | A session was renamed |
| `%sessions-changed` | A session was created or destroyed |
| `%session-window-changed $<id> @<wid>` | A session's current window changed |

**Window notifications:**
| Message | Meaning |
|---------|---------|
| `%window-add @<id>` | Window added to attached session |
| `%window-close @<id>` | Window closed |
| `%window-renamed @<id> <name>` | Window renamed |
| `%window-pane-changed @<wid> %<pid>` | Active pane in a window changed |
| `%layout-change @<wid> <layout> <vis_layout> <flags>` | Window layout changed (resize, split, etc.) |

**Unlinked window notifications** (windows in other sessions):
| Message | Meaning |
|---------|---------|
| `%unlinked-window-add @<id>` | Window added to another session |
| `%unlinked-window-close @<id>` | Window closed in another session |
| `%unlinked-window-renamed @<id> <name>` | Window renamed in another session |

**Client notifications:**
| Message | Meaning |
|---------|---------|
| `%client-session-changed <client> $<sid> <name>` | Another client changed session |
| `%client-detached <client>` | Another client detached |

**Paste buffer notifications:**
| Message | Meaning |
|---------|---------|
| `%paste-buffer-changed <name>` | A paste buffer changed |
| `%paste-buffer-deleted <name>` | A paste buffer deleted |

**Subscription notifications:**
| Message | Meaning |
|---------|---------|
| `%subscription-changed <name> $<sid> @<wid> <idx> %<pid> : <value>` | A subscribed format value changed |

**Flow control:**
| Message | Meaning |
|---------|---------|
| `%pause %<pane_id>` | Pane paused (output suspended) |
| `%continue %<pane_id>` | Pane resumed |

**Other:**
| Message | Meaning |
|---------|---------|
| `%pane-mode-changed %<pane_id>` | Pane entered/exited copy mode |
| `%exit [reason]` | Client exiting |

#### 1.6.4 Escaping rules

In `%output` and `%extended-output` data **(doc)**:

- Control characters (ASCII < 32) are replaced with **octal escapes**:
  `\ooo` (three octal digits). For example, newline (0x0A) → `\012`,
  carriage return (0x0D) → `\015`.
- The backslash character `\` itself → `\134`.
- All other printable characters are passed through literally.

The pane output data may contain terminal escape sequences for the
`TERM=tmux` or `TERM=screen` terminal type. The control mode client
must decode the octal escaping first, then feed the resulting bytes into
a terminal emulator (VT parser) to interpret them.

#### 1.6.5 Flow control

Flow control prevents a slow client from being disconnected when panes
produce output faster than the client can consume it **(doc)**.

**Enabling:** Send `refresh-client -f pause-after=<seconds>`

**How it works:**
1. When enabled, `%output` is replaced by `%extended-output` (which
   includes a "milliseconds behind" field).
2. When a pane's output falls behind by the specified duration, tmux
   sends `%pause %<pane_id>` and stops sending output for that pane.
3. The client resumes the pane with:
   `refresh-client -A '%<pane_id>:continue'`
4. On resume, tmux sends `%continue %<pane_id>`.

**Manual pane control:**
- `refresh-client -A '%<pid>:pause'` — manually pause
- `refresh-client -A '%<pid>:off'` — stop output entirely
- `refresh-client -A '%<pid>:on'` — re-enable

**Internal limits** (from tmux source):
- Without pause mode, a client that falls more than 300 seconds behind
  gets disconnected with `%exit` and reason "too far behind".

#### 1.6.6 ID system

tmux uses stable numeric IDs with sigils **(doc)**:
- Sessions: `$<id>` (e.g., `$0`)
- Windows: `@<id>` (e.g., `@1`)
- Panes: `%<id>` (e.g., `%0`)

These are globally unique and stable (unlike names or indices).

#### 1.6.7 DCS framing

When using `-CC`, the entire control mode session is wrapped in a DCS
(Device Control String) escape sequence **(doc, code)**:

- **Entry**: tmux sends `ESC P 1000 p` (DCS with parameter 1000,
  final byte `p`). A terminal emulator can detect this to know control
  mode has started.
- **Exit**: tmux sends `%exit [reason]` followed by `ESC \` (ST,
  String Terminator).

This DCS framing is what allows a terminal emulator to distinguish
control mode traffic from normal terminal output.

### 1.7 Comparison: three ways to use tmux

**1. Normal tmux usage in a terminal:**
```
You type → Terminal → tmux client → tmux server → shell
Shell output → tmux server → tmux client → (draws TUI) → Terminal → screen
```
The terminal is a dumb display. tmux draws everything.

**2. tmux control mode as protocol:**
```
You type → Control client → (sends commands) → tmux server → shell
Shell output → tmux server → (sends %output) → Control client → ???
```
The control client receives structured data. It must decide what to do
with it. There is no TUI.

**3. What Ghostty could provide on top of control mode:**
```
You type → Ghostty → (sends keys to tmux) → tmux server → shell
Shell output → tmux server → %output → Ghostty parser → Ghostty terminal emulator
tmux panes → native Ghostty tabs/splits
tmux windows → native Ghostty windows
Scrollback → native Ghostty scrollback
Selection → native Ghostty selection/clipboard
Search → native Ghostty search
```
Ghostty would replace the tmux TUI with native OS-level UI elements.
The user would never see tmux's TUI — they'd get the persistence and
remote benefits of tmux with the native look, feel, and integration of
Ghostty.

### 1.8 Product perspective: what the user experience would be

If this were fully implemented:

1. User opens Ghostty and runs `tmux -CC attach` (or Ghostty starts it
   automatically).
2. Each tmux window appears as a native Ghostty tab.
3. Each tmux pane appears as a native Ghostty split.
4. The user can scroll with the native Ghostty scrollbar.
5. The user can search pane content with Ghostty's search.
6. The user can select and copy with native selection.
7. Closing a Ghostty tab closes the tmux window.
8. Opening a new tab creates a new tmux window.
9. Splitting a pane creates a new tmux pane.
10. If the user closes Ghostty and reopens, they can reattach and
    everything is back — because tmux kept the session alive.

This is exactly what iTerm2 provides today with `tmux -CC`.

---

## Section 2: How People Use tmux Control Mode Today

### 2.1 Which terminals/tools support it?

**iTerm2** (macOS): The most mature implementation. George Nachman
(iTerm2's author) co-designed the control mode protocol with the tmux
developers. This is the reference implementation. **(doc)**

**WezTerm**: Has a working implementation merged in PR #6602. Treats
tmux as a "multiplexer domain" and renders native windows/tabs/panes.
Still has some known issues (SSH hangs, WSL issues). **(issue)**

**No other major terminals** currently support it. Not Alacritty, not
kitty, not Windows Terminal (which has open feature requests but no
implementation). **(inferred from web search)**

### 2.2 Common use cases

1. **SSH workflow with native UI**: You SSH to a remote server. You
   run `tmux -CC attach`. Your remote tmux sessions appear as native
   tabs and splits in iTerm2. You get native scrollback, search, and
   copy-paste — all for remote sessions.

2. **Session persistence with native feel**: You close your laptop.
   Tomorrow, you open iTerm2 and run `tmux -CC attach`. Everything is
   back — same tabs, same panes, same content — but it all looks and
   feels like native iTerm2.

3. **Multi-window development**: You have a complex dev setup — editor
   pane, build pane, log pane, REPL pane. With control mode, each is a
   native split in your terminal emulator. You can resize with your
   mouse naturally, use native keyboard shortcuts, etc.

### 2.3 Step-by-step: how a user uses this today in iTerm2

1. Open iTerm2.
2. Type: `tmux -CC new-session -s work`
3. iTerm2 detects the DCS sequence and activates control mode.
4. A notification bar appears: "tmux integration active."
5. The current tmux window appears as a native iTerm2 tab.
6. Press Cmd+T — iTerm2 creates a new tmux window (sends
   `new-window` command to tmux).
7. Press Cmd+D — iTerm2 creates a new tmux pane (sends
   `split-window` command to tmux).
8. You work normally. Everything looks native.
9. Close iTerm2.
10. Open iTerm2 again. Type: `tmux -CC attach -t work`
11. All your tabs and panes reappear, with content intact.

### 2.4 Why choose control mode over normal tmux?

- **Native UI**: No box-drawing pane borders, no tmux status bar. Real
  OS-native tabs, splits, scrollback.
- **Native keybindings**: Cmd+C to copy, Cmd+V to paste, Cmd+F to
  search. No need to learn tmux's key bindings.
- **OS integration**: Proper font rendering, native resize handles,
  accessibility support, system clipboard integration.
- **Scrollback**: Native terminal scrollback instead of tmux's copy mode.
- **Still get persistence**: All the benefits of tmux (session survival,
  remote reattach) without the TUI tradeoffs.

---

## Section 3: User Story / Product Perspective

### 3.1 Who is this feature for?

1. **Remote developers** who SSH into servers and want session
   persistence with a native feel. **(issue #1935 — explicitly
   requested)**
2. **iTerm2 refugees** who use tmux -CC today and want the same
   experience in Ghostty. **(issue #1935 — dtenenba confirmed this)**
3. **Power users** who want tmux's session management but dislike its
   TUI aesthetics and keybinding conflicts.
4. **AI/agent workflows** that use tmux for multi-pane execution and
   want native terminal integration. **(issue #1935 — findepi
   mentioned Claude agent teams)**

### 3.2 What problem does it solve?

Today, using tmux in Ghostty means:
- You lose native Ghostty features inside tmux (scrollback, search,
  selection behavior).
- tmux draws its own UI — borders, status bar — which looks different
  from Ghostty's native UI.
- Keyboard shortcuts conflict (Ghostty keybindings vs tmux prefix keys).
- Scrolling behavior is different inside tmux.
- No OS-level integration for tmux's windows and panes.

Control mode integration would eliminate these frictions entirely.

### 3.3 What would a successful workflow look like?

**(inferred from iTerm2 behavior and issue #1935 discussion)**

1. User configures Ghostty to auto-start with `tmux -CC attach` (or
   triggers it manually).
2. Ghostty detects the DCS `ESC P 1000p` sequence.
3. Ghostty reads tmux's initial session state (windows, panes, layouts).
4. Each tmux window appears as a Ghostty tab.
5. Each tmux pane appears as a Ghostty split.
6. Content in each pane is populated from tmux (scrollback + visible area).
7. Ongoing output (`%output`) is routed to the correct pane's terminal.
8. User actions (new tab, close tab, resize, split) are sent as tmux
   commands.
9. Tmux notifications update Ghostty's UI accordingly.
10. Detaching or closing Ghostty leaves the tmux session running.
11. Reattaching restores everything.

### 3.4 What "native integration" means

- **Native tabs** = tmux windows → Ghostty tabs (macOS native tab bar)
- **Native splits** = tmux panes → Ghostty split views
- **Native scrollback** = Ghostty manages scrollback per pane, populated
  from tmux history
- **Native search** = Cmd+F searches the Ghostty-managed buffer
- **Native selection** = click-and-drag, Cmd+C, Cmd+V
- **Native resize** = drag split handles, resizes both Ghostty view and
  tmux pane

### 3.5 Evidence vs inference

| Claim | Basis |
|-------|-------|
| Users want this feature | **(issue)** #1935, 50+ participants |
| iTerm2 provides this today | **(doc)** iTerm2 documentation |
| WezTerm is implementing it | **(issue)** wezterm PR #6602 |
| It would eliminate tmux TUI friction | **(inferred)** from how control mode works |
| Ghostty tabs would map to tmux windows | **(inferred)** from iTerm2's approach, but Ghostty's exact UI is not documented |
| It would improve remote SSH workflows | **(issue)** explicitly mentioned in #1935 |

---

## Section 4: Protocol Checklist

This checklist covers what a serious control mode client needs to handle.

### 4.1 Connection lifecycle

| Element | Meaning | Priority | Client must... |
|---------|---------|----------|----------------|
| DCS `ESC P 1000p` detection | Entry to control mode | **Essential** | Detect DCS, switch to control mode parsing |
| `%exit [reason]` | Client exiting | **Essential** | Clean up, optionally show reason to user |
| ST (`ESC \`) after exit | DCS termination | **Essential** | Exit control mode parsing |
| `wait-exit` flag | tmux waits for empty line before exiting | **Useful** | Optionally send empty line after cleanup |
| Sending empty line to detach | Voluntary detach | **Essential** | Support user-initiated detach |

### 4.2 Command/response blocks

| Element | Meaning | Priority | Client must... |
|---------|---------|----------|----------------|
| `%begin <ts> <cmd> <flags>` | Start of command response | **Essential** | Track block start, record command number |
| `%end <ts> <cmd> <flags>` | Successful command end | **Essential** | Correlate with begin, process block content |
| `%error <ts> <cmd> <flags>` | Failed command end | **Essential** | Correlate with begin, handle error |
| Block payload parsing | Content between begin/end | **Essential** | Parse command-specific output |
| Guard-line validation | Verify full `%end`/`%error` format | **Essential** | Avoid false termination on payload lines starting with `%end` |

### 4.3 Pane output

| Element | Meaning | Priority | Client must... |
|---------|---------|----------|----------------|
| `%output %<pid> <data>` | Pane terminal output | **Essential** | Decode octal escaping, feed to VT parser for that pane |
| `%extended-output` | Flow-controlled pane output | **Useful** | Same as %output, also track latency |
| Octal escape decoding | `\ooo` for control chars, `\134` for `\` | **Essential** | Correctly decode all escaped bytes |
| `%pane-mode-changed %<pid>` | Pane entered/exited copy mode | **Situational** | Optionally adjust UI |

### 4.4 Session notifications

| Element | Meaning | Priority | Client must... |
|---------|---------|----------|----------------|
| `%session-changed $<id> <name>` | Attached session changed | **Essential** | Update session state, refresh all windows |
| `%session-renamed` | Session renamed | **Useful** | Update displayed session name |
| `%sessions-changed` | Session created/destroyed | **Useful** | Update session list if exposed in UI |

### 4.5 Window notifications

| Element | Meaning | Priority | Client must... |
|---------|---------|----------|----------------|
| `%window-add @<id>` | Window added | **Essential** | Create new tab/window |
| `%window-close @<id>` | Window closed | **Essential** | Close tab/window |
| `%window-renamed @<id> <name>` | Window renamed | **Useful** | Update tab/window title |
| `%layout-change @<wid> ...` | Layout changed | **Essential** | Reparse layout, resize/add/remove panes |
| `%window-pane-changed @<wid> %<pid>` | Active pane changed | **Useful** | Update focus |
| `%session-window-changed $<sid> @<wid>` | Current window changed | **Useful** | Switch active tab |

### 4.6 Client notifications

| Element | Meaning | Priority | Client must... |
|---------|---------|----------|----------------|
| `%client-session-changed` | Another client changed session | **Situational** | Informational only |
| `%client-detached` | Another client detached | **Situational** | Informational only |

### 4.7 Paste buffer notifications

| Element | Meaning | Priority | Client must... |
|---------|---------|----------|----------------|
| `%paste-buffer-changed` | Paste buffer changed | **Optional** | Optionally sync with system clipboard |
| `%paste-buffer-deleted` | Paste buffer deleted | **Optional** | Optionally update clipboard state |

### 4.8 Flow control

| Element | Meaning | Priority | Client must... |
|---------|---------|----------|----------------|
| `refresh-client -f pause-after=N` | Enable flow control | **Useful** | Send at startup for robustness |
| `%pause %<pid>` | Pane paused | **Useful** | Track paused state |
| `%continue %<pid>` | Pane resumed | **Useful** | Track resumed state |
| `refresh-client -A '%<pid>:continue'` | Resume pane | **Useful** | Send when ready to receive more |

### 4.9 Subscriptions

| Element | Meaning | Priority | Client must... |
|---------|---------|----------|----------------|
| `refresh-client -B '...'` | Subscribe to format changes | **Optional** | Use for monitoring without polling |
| `%subscription-changed` | Subscribed value changed | **Optional** | Process if using subscriptions |

### 4.10 Commands the client sends

| Command | Purpose | Priority |
|---------|---------|----------|
| `list-windows -F '...'` | Get all windows and layouts | **Essential** |
| `list-panes -F '...'` | Get pane state (cursor, modes) | **Essential** |
| `capture-pane -p -e -q ...` | Get pane content (scrollback + visible) | **Essential** |
| `display-message -p '...'` | Get server info (version, etc.) | **Useful** |
| `new-window` | Create window | **Essential** (for full integration) |
| `kill-window -t @<id>` | Close window | **Essential** |
| `split-window` | Create pane | **Essential** |
| `kill-pane -t %<id>` | Close pane | **Essential** |
| `resize-pane -t %<id> -x W -y H` | Resize pane | **Essential** |
| `send-keys -t %<id> ...` | Send input to pane | **Essential** |
| `refresh-client -C WxH` | Set client size | **Essential** |
| `select-window -t @<id>` | Switch active window | **Useful** |
| `select-pane -t %<id>` | Switch active pane | **Useful** |

### 4.11 Layout string parsing

| Element | Meaning | Priority | Client must... |
|---------|---------|----------|----------------|
| Layout format (e.g. `80x24,0,0,42`) | Pane tree description | **Essential** | Parse to determine pane arrangement |
| Checksum (4-char hex prefix) | Layout integrity check | **Useful** | Validate checksum matches |
| Nested `{}`/`[]` | Horizontal/vertical splits | **Essential** | Parse recursive tree structure |

---

## Section 5: Ghostty's Current tmux Story

### 5.1 Normal tmux usage in Ghostty (as a regular terminal)

Ghostty is a fully capable terminal emulator. You can run tmux inside
Ghostty the same way you'd run it in any terminal:

```
tmux new-session -s work
```

This works today. tmux takes over the Ghostty window and draws its TUI.
You get:
- tmux's pane borders, status bar, key bindings
- tmux's internal scrollback (via copy mode)
- tmux's session persistence

**Known issue** **(issue #10227, closed)**: Ghostty's scrollbar and search
could previously access tmux's off-screen history (the alternate screen
buffer), which should be invisible since tmux is an alternate-screen
application. This was partially fixed in PR #10229.

### 5.2 tmux control mode support: what exists in the code

Ghostty has **substantial but incomplete** tmux control mode support.
Here is what the code contains, verified from source **(code)**:

#### 5.2.1 Build-level feature flag

tmux control mode is gated behind a build option `tmux_control_mode`,
which is `true` when the Oniguruma regex library is available (which it
is in standard builds).
**Source:** `src/terminal/build_options.zig:46`

#### 5.2.2 DCS detection (working)

The DCS handler in `src/terminal/dcs.zig` detects `ESC P 1000 p` and
routes bytes to the tmux control parser.
**Source:** `src/terminal/dcs.zig:52-58`

#### 5.2.3 Control mode protocol parser (working, well-tested)

`src/terminal/tmux/control.zig` — 839 lines. A state machine that
parses tmux control mode output byte-by-byte. It handles:

- Block begin/end/error with guard-line validation
- All major notification types: `%output`, `%session-changed`,
  `%sessions-changed`, `%layout-change`, `%window-add`,
  `%window-renamed`, `%window-pane-changed`, `%client-detached`,
  `%client-session-changed`
- State transitions: idle → notification → block → idle
- Memory limits and broken-state handling

**26 tests** covering notification parsing, block handling, edge cases.

**Known limitation** **(code, issue #11395)**: The parser had a bug where
payload lines starting with `%end` or `%error` could prematurely
terminate a block. This was fixed (the fix required checking the full
guard-line format). You contributed to this fix.

**Missing from parser** **(inferred)**:
- `%window-close` — not seen in Notification union
- `%session-renamed` — not seen in Notification union
- `%session-window-changed` — not seen
- `%pane-mode-changed` — not seen
- `%paste-buffer-changed` / `%paste-buffer-deleted` — not seen
- `%subscription-changed` — not seen
- `%pause` / `%continue` — not seen
- `%extended-output` — not seen
- `%unlinked-window-*` — not seen

These omissions may be intentional (not all are needed for a first
implementation) but represent protocol coverage gaps.

#### 5.2.4 Layout parser (working, well-tested)

`src/terminal/tmux/layout.zig` — 638 lines. Parses tmux layout strings
(e.g., `80x24,0,0{40x24,0,0,1,40x24,40,0,2}`) into a tree structure.
Includes CRC16 checksum validation.

**31 tests** covering single panes, splits, nesting, error cases,
checksums.

#### 5.2.5 Command output parser (working, well-tested)

`src/terminal/tmux/output.zig` — 590 lines. Parses tmux format-string
output from commands like `list-windows` and `list-panes` into typed
structs. Supports 31 tmux variables covering cursor state, terminal
modes, mouse modes, scroll regions, IDs, etc.

**41 tests.**

#### 5.2.6 Viewer / reconciliation loop (working, no GUI connection)

`src/terminal/tmux/viewer.zig` — 2283 lines. A state machine that:

1. Handles the startup handshake (initial block → session-changed →
   command queue).
2. Queries tmux for windows, panes, and state.
3. Creates local `Terminal` instances for each pane.
4. Populates pane content using `capture-pane`.
5. Syncs terminal modes (cursor, mouse, insert, wrap, etc.).
6. Handles live `%output` by routing to the correct pane's terminal.
7. Handles `%layout-change` by re-syncing pane structure.
8. Handles `%window-add` by refreshing window list.

This is the core cross-platform business logic. **(issue, PR #9860)**:
Mitchell's comment: "This sucked. The control mode protocol is
difficult."

**Limitations noted in code** **(code)**:
- TODO: Startup robustness — session and block can happen out of order
  (viewer.zig:19)
- TODO: Ignore `%output` for panes not yet initialized (viewer.zig:21)
- TODO: Track active window pane for initial focus (viewer.zig:23)
- NOTE: Notification order assumptions based on tmux source as of Dec
  2025 — fragile (viewer.zig:26-35)

#### 5.2.7 Stream handler integration (partially working)

`src/termio/stream_handler.zig` handles the connection from DCS parsing
to the Viewer:

- `.enter` → creates a Viewer instance (line 396-404)
- `.exit` → destroys the Viewer (line 407-413)
- Other notifications → passed to `viewer.next()`, actions processed
- `.command` actions → queued as write requests back to tmux (line 447-454)
- **`.windows` action → `// TODO` — NOT IMPLEMENTED** (line 456-458)

This `// TODO` is **the critical missing piece at the integration layer**.
When the Viewer determines which windows/panes exist, it emits a
`.windows` action — but the stream handler does nothing with it. This is
where the GUI glue would need to create native Ghostty tabs and splits.

### 5.3 What works today

| Capability | Status | Evidence |
|------------|--------|----------|
| Normal tmux usage in Ghostty | **Works** | Standard terminal emulation |
| DCS `ESC P 1000p` detection | **Works** | code: dcs.zig |
| Control mode protocol parsing | **Works** (major notifications) | code: control.zig, 26 tests |
| Layout string parsing | **Works** | code: layout.zig, 31 tests |
| Command output parsing | **Works** | code: output.zig, 41 tests |
| Session state machine | **Works** (internally) | code: viewer.zig |
| Pane content capture | **Works** (internally) | code: viewer.zig |
| Send commands back to tmux | **Works** | code: stream_handler.zig |
| **Create native tabs/splits from tmux state** | **NOT IMPLEMENTED** | code: stream_handler.zig:456-458, `// TODO` |
| Apprt API for non-exec surfaces | **NOT IMPLEMENTED** | issue #1935 checklist |

### 5.4 What does NOT work today

1. **No visible output from control mode.** If you run `tmux -CC` in
   Ghostty today, the Viewer runs internally and syncs state, but
   nothing appears on screen. The `.windows` action is silently dropped.
   **(code)**

2. **No native tabs/splits.** The fundamental missing piece: Ghostty
   cannot yet create surfaces (tabs, splits) that are backed by tmux
   panes rather than local shell processes. Mitchell identified this as
   "the ability to create new apprt things (windows/splits/tabs) that
   aren't attached to a normal exec-based termio. Which is pretty
   fundamentally hard." **(issue #1935, 00-kat quoting Mitchell)**

3. **No user input routing.** Even if windows were displayed, there's
   no mechanism to capture keystrokes from a tmux-backed surface and
   send them to tmux via `send-keys`. **(inferred)**

4. **No resize handling.** No code sends `refresh-client -C WxH` when
   Ghostty is resized. **(inferred from code inspection)**

5. **Several notification types not parsed.** See 5.2.3 above.

6. **No flow control.** No support for `%pause`, `%continue`,
   `%extended-output`, or `refresh-client -f pause-after=N`.
   **(code — not in Notification union)**

### 5.5 Summary of current state

The **protocol/parsing layer is substantial and well-tested**. The
**reconciliation/state machine is implemented**. The **GUI integration
layer is the major gap** — specifically:

- The "apprt" (application runtime) layer needs to support creating
  surfaces that aren't backed by a subprocess.
- The stream handler needs to process `.windows` actions and create
  real UI elements.
- Input routing, resize handling, and various user interactions need
  to be wired up.

The maintainer's characterization that support is "decent" is accurate
for the protocol and state management layers. The characterization that
"some missing work may not be parser work, but app/GUI glue work" is
strongly confirmed by the code — **the GUI glue is the primary remaining
challenge**.

### 5.6 Maintainer's checklist status (from issue #1935)

| Item | Status | PR |
|------|--------|----|
| Control Mode DCS Parser | **Done** | #1946 (merged 2024-07-12) |
| Termio non-subprocess support | **Partial** | #1948 (merged 2024-07-15) |
| Apprt API for non-subprocess surfaces | **Not started** | — |
| Termio hooks for tmux notifications | **Partial** | #9860 (merged 2025-12-10) |
| Parser for tmux command output | **Done** | #9803 (merged 2025-12-04) |
| Reconciliation loop | **Done** | #9860 (merged 2025-12-10) |

The two unchecked items — **Apprt API changes** and **full Termio
non-subprocess support** — are the architectural work that would connect
the working internal state machine to visible UI.

---

## What's Next

Sections 6–14 (in the second pass) will cover:
- Detailed code inspection with guided reading route
- Protocol coverage gap table
- First engineering problem identification
- Smallest meaningful work slice
- How to study the code yourself
- Diagrams
- Local experiments
- Testing strategy
- Maintainer summary
