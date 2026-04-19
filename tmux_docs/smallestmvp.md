# Smallest MVP: tmux Control Mode Observability Experiment

---

## 0. What You Will Understand After Running This

> [PEDAGOGICAL-REVIEW] This section was added to front-load the learning goals.
> The original document opened with tables of file paths and line numbers — a
> reference for someone who already understands the system, not a guide for
> someone building a mental model for the first time.

After running this experiment and reading the logs, you will concretely understand
five things that you cannot learn from reading code alone:

**1. The full data path, from tmux's bytes to a dead end.**
You'll see: tmux writes `ESC P 1000 p` → Ghostty's VT parser detects a DCS sequence →
DCS handler creates a tmux control parser → bytes flow through the parser, producing
structured Notifications → stream handler feeds Notifications to the Viewer → Viewer
sends commands back to tmux and receives responses → Viewer assembles window/pane state →
Viewer emits a `.windows` action → **stream handler drops it (// TODO)** → nothing renders.
You will see this as a real log trace, not a description.

**2. The Viewer's request-response dance.**
The hardest thing to reason about without seeing it: the Viewer sends one command to tmux
(like `list-windows`), then waits for the `%begin`/`%end` response block, then sends the
next command. It's a serialized protocol. The logs will show you the exact sequence:
`display-message` → response → `list-windows` → response → `capture-pane` (×4) → responses →
`list-panes` → response → done. This serial dance is why the command queue exists.

**3. What the Viewer actually builds.**
The Viewer creates a real `Terminal` instance (a complete terminal emulator) for each tmux
pane. It captures scrollback history and visible content into that Terminal. When live
`%output` arrives, it feeds the decoded bytes into the pane's Terminal. After this experiment,
you'll see log lines showing Terminal creation with dimensions, and %output being routed to
specific panes — proving the Viewer holds real, renderable state.

**4. Where the system breaks and why.**
The `.windows` action is emitted with correct window/pane data. But the stream handler has
`// TODO` where it should create native Ghostty tabs and splits. This is not a parsing
problem — the data is there. It's an architecture problem: Ghostty's `Backend` only has
`Kind = enum { exec }`, meaning every surface must be backed by a subprocess PTY. tmux panes
need a different kind of Backend that reads from the Viewer's Terminal instances instead.

**5. The threading model.**
The PTY read thread reads bytes from tmux. Those bytes are processed under a mutex lock
(`renderer_state.mutex`) through the VT parser, DCS handler, tmux parser, stream handler,
and Viewer — all synchronously on the read thread. Commands going back to tmux are queued
via a mailbox to the IO thread. Understanding which code runs on which thread matters for
the eventual apprt integration.

### What you will NOT understand (and will need next)

- How to create a non-exec Surface (the actual apprt API change needed)
- Whether the Viewer's Terminal content renders correctly (requires connecting a renderer)
- How to route keystrokes from a tmux-backed Surface back to tmux
- How resize propagation should work

---

## 0.1 The System at a Glance

Before reading logs or code, internalize this picture:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         READ THREAD                                     │
│                                                                         │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌─────────────────┐   │
│  │ PTY read │    │ VT Parser│    │ DCS      │    │ tmux control    │   │
│  │ loop     │───►│ (byte by │───►│ Handler  │───►│ Parser          │   │
│  │          │    │  byte)   │    │          │    │ (byte by byte)  │   │
│  │ 1024-byte│    │          │    │ detects  │    │                 │   │
│  │ chunks   │    │ detects  │    │ param    │    │ accumulates     │   │
│  │ from fd  │    │ ESC P    │    │ 1000,    │    │ lines, parses   │   │
│  └──────────┘    │ → DCS    │    │ creates  │    │ %begin/%end/    │   │
│                  │   entry  │    │ tmux     │    │ %output/etc     │   │
│                  └──────────┘    │ parser   │    │                 │   │
│                                 └──────────┘    │ emits Notif-    │   │
│                                                 │ ications        │   │
│  ALL of this runs under renderer_state.mutex    └────────┬────────┘   │
│                                                          │            │
│  ┌───────────────────────────────────────────────────────┘            │
│  │                                                                    │
│  ▼                                                                    │
│  ┌──────────────────────────┐     ┌──────────────────────────────┐   │
│  │ Stream Handler           │     │ Viewer                       │   │
│  │ (dcsCommand)             │     │                              │   │
│  │                          │     │ State machine:               │   │
│  │ .enter → create Viewer ──┼────►│ startup_block                │   │
│  │ .exit  → destroy Viewer  │     │   → startup_session          │   │
│  │ other  → viewer.next() ──┼────►│     → command_queue ◄─┐     │   │
│  │                          │     │                        │     │   │
│  │ action loop:             │◄────┤ Returns []Action:      │     │   │
│  │  .command → send to tmux │     │  .command (send text)──┘     │   │
│  │  .windows → // TODO ◄◄◄ │     │  .windows (pane data)        │   │
│  │  .exit    → (ignored)    │     │  .exit    (done)             │   │
│  └─────────┬────────────────┘     │                              │   │
│            │                      │ Owns per-pane Terminal        │   │
│            │ .command text        │ instances (full emulator      │   │
│            ▼                      │ state with screen buffers)    │   │
│  ┌──────────────────┐             └──────────────────────────────┘   │
│  │ messageWriter()  │                                                │
│  │ (queues to       │                                                │
│  │  IO thread       │                                                │
│  │  mailbox)        │                                                │
│  └────────┬─────────┘                                                │
│           │                                                          │
└───────────┼──────────────────────────────────────────────────────────┘
            │
            ▼
┌───────────────────────┐     ┌──────────────┐
│ IO THREAD             │     │ tmux server  │
│                       │     │              │
│ drains mailbox,       │────►│ receives     │
│ writes to PTY master  │     │ commands on  │
│ fd via xev stream     │     │ stdin        │
│                       │     │              │
│                       │◄────│ sends        │
│                       │     │ responses    │
└───────────────────────┘     │ on stdout    │
                              └──────────────┘

◄◄◄ THE GAP: .windows arrives with correct data but nothing creates
    native tabs/splits. The missing piece is a non-exec Backend kind
    that connects the Viewer's Terminal instances to Ghostty Surfaces.
```

### Architectural claims this experiment will test

> "The Viewer's reconciliation loop works correctly — it creates local Terminal
> instances, populates them, routes live output." — overview_6_14.md §8.1

> "The stream handler silently drops `.windows` actions with `// TODO`."
> — overview_6_14.md §8.1

The experiment will confirm or deny both of these by making them visible in logs.

## 0.2 Codebase Recon Summary

### 0.2 Source Files Containing tmux Logic

| File | Purpose | Log Scope | Existing Log Levels |
|------|---------|-----------|-------------------|
| `src/terminal/dcs.zig` | DCS handler; detects `ESC P 1000 p`, routes bytes to tmux Parser | `.terminal_dcs` | `debug`, `info` |
| `src/terminal/tmux/control.zig` | Byte-by-byte protocol parser; emits `Notification` values | `.terminal_tmux` | `warn` |
| `src/terminal/tmux/viewer.zig` | State machine; orchestrates session lifecycle, emits `Action` values | `.terminal_tmux_viewer` | `info`, `warn` |
| `src/terminal/tmux/layout.zig` | Parses tmux layout strings into pane trees | (none) | (none) |
| `src/terminal/tmux/output.zig` | Parses `list-windows`/`list-panes` format output into typed structs | (none) | (none) |
| `src/terminal/tmux.zig` | Module re-exports: `ControlParser`, `ControlNotification`, `Layout`, `Viewer` | — | — |
| `src/termio/stream_handler.zig` | Glue: feeds DCS events to Viewer, sends commands back to tmux PTY | `.io_handler` | `info`, `warn`, `err`, `debug` |
| `src/terminal/build_options.zig` | Ties `tmux_control_mode` to Oniguruma availability (line 46) | — | — |
| `src/terminal/main.zig` | Conditional tmux export (line 26): `if (options.tmux_control_mode)` | — | — |

### 0.3 VT/DCS Parser Entry Path

| Step | File | Lines | What Happens |
|------|------|-------|-------------|
| 1 | `src/terminal/Parser.zig` | 15-30 | VT parser `State` enum includes `dcs_entry`, `dcs_param`, `dcs_intermediate`, `dcs_passthrough`, `dcs_ignore` |
| 2 | `src/terminal/parse_table.zig` | ~149 | From `escape` state, byte `0x50` ('P') transitions to `dcs_entry` |
| 3 | `src/terminal/Parser.zig` | 291-305 | Transition to `dcs_passthrough` emits `dcs_hook` action with `intermediates`, `params`, `final` |
| 4 | `src/terminal/Parser.zig` | 404 | In `dcs_passthrough`, `.put` action emits `dcs_put` with the byte |
| 5 | `src/terminal/Parser.zig` | 274 | Exit from `dcs_passthrough` emits `dcs_unhook` |
| 6 | `src/terminal/stream.zig` | ~737-739 | `Stream.process()` dispatches: `.dcs_hook` → `handler.vt(.dcs_hook, dcs)`, `.dcs_put` → `handler.vt(.dcs_put, byte)`, `.dcs_unhook` → `handler.vt(.dcs_unhook, {})` |
| 7 | `src/termio/stream_handler.zig` | 368-384 | `dcsHook()`, `dcsPut()`, `dcsUnhook()` delegate to `dcs.Handler` methods, then call `dcsCommand()` |
| 8 | `src/terminal/dcs.zig` | 50-75 | `tryHook()`: if `dcs.final == 'p'` and `dcs.params[0] == 1000` → creates tmux `Parser`, returns `.{ .tmux = .enter }` |
| 9 | `src/terminal/dcs.zig` | 130-134 | `tryPut()`: delegates byte to `tmux.put(byte)`, wraps result in `.{ .tmux = notification }` |
| 10 | `src/terminal/dcs.zig` | 168-171 | `unhook()`: deinits tmux state, returns `.{ .tmux = .exit }` |

### 0.4 PTY / Subprocess Layer

| Component | File | Lines | Function | Details |
|-----------|------|-------|----------|---------|
| PTY creation | `src/pty.zig` | 134-186 | `PosixPty.open()` | Calls `openpty()`, sets CLOEXEC, enables UTF-8 |
| Fork/exec | `src/Command.zig` | 175-258 | `startPosix()` | `fork()` → child redirects stdio to PTY slave → `execvpeZ()` |
| Subprocess start | `src/termio/Exec.zig` | 885-1070 | `Subprocess.start()` | Opens PTY, creates Command, starts subprocess |
| Thread entry | `src/termio/Exec.zig` | 85-193 | `threadEnter()` | Starts subprocess, spawns read thread, registers xev watchers |
| **Read loop** | `src/termio/Exec.zig` | 1257-1357 | `ReadThread.threadMainPosix()` | `posix.read(fd, &buf)` → `Termio.processOutput(io, buf[0..n])` in tight poll loop; 1024-byte buffer |
| Write queue | `src/termio/Exec.zig` | 403-468 | `queueWrite()` | Queues bytes to xev stream on PTY master fd |
| Process output | `src/termio/Termio.zig` | — | `processOutput()` | Calls `StreamHandler.nextSlice()` which feeds bytes to VT parser |

### 0.5 Recent Git Activity

```
12458e3ac blp and glsl files are source files, not binary (#11906)
b8b089632 ci: add full zig test suite for Windows (#11839)
a1370d9bd windows: initialize MSVC C runtime in DLL mode (#11856)
e90eebea9 ci: switch to namespace image
6057f8d2b terminal: redo trailing state capture in OSC parser (#11873)
```

No recent changes to tmux, DCS, or stream_handler files. The tmux subsystem was last significantly modified in PR #9860 (merged 2025-12-10).

---

## 1. The Experiment in One Paragraph

Configure Ghostty to launch `tmux -CC new-session -s mvp` as its shell command, then read its log output. **This requires zero code changes.** Ghostty already logs every tmux notification it receives and every action the Viewer emits (stream_handler.zig lines 393 and 438). By grepping these existing logs, you will see the complete tmux control mode handshake: DCS detection → Viewer startup → serial command-response dance with tmux → `.windows` action emitted and silently dropped. For deeper visibility (Viewer state transitions, Terminal creation per pane, `%output` routing to Terminals), optional log additions are specified in §4 — but start without them.

---

## 2. Subsystem Inventory

| # | Subsystem | Source File(s) | Entry Point | Exit Point | Core Invariants |
|---|-----------|---------------|-------------|------------|-----------------|
| 1 | **PTY Read** | `src/termio/Exec.zig` | `ReadThread.threadMainPosix()` line 1257 | `Termio.processOutput()` line 1335 | Read returns `n > 0` bytes or `WouldBlock`; `n` never exceeds 1024 (buffer size) |
| 2 | **VT Parser** | `src/terminal/Parser.zig` | `next()` line 251 | Returns `[3]?Action` | Transition to `dcs_passthrough` must emit a `dcs_hook` action with `params` and `final` populated; `dcs_unhook` must be emitted when leaving `dcs_passthrough`; no second `dcs_hook` can fire while already in `dcs_passthrough` (DCS sequences do not nest) |
| 3 | **DCS Handler** | `src/terminal/dcs.zig` | `hook()` line 25 / `put()` line 114 / `unhook()` line 157 | Returns `?Command` | `hook()` must be called with `state == .inactive`; after `hook()` with tmux params, state must be `.tmux`; `unhook()` must reset state to `.inactive` |
| 4 | **Stream Handler (DCS dispatch)** | `src/termio/stream_handler.zig` | `dcsHook()` line 368 / `dcsPut()` line 374 / `dcsUnhook()` line 380 | `dcsCommand()` line 386 | `dcsHook` → `dcsCommand` with `.tmux = .enter`; `dcsPut` → `dcsCommand` with `.tmux = <notification>` (when parser emits one); `dcsUnhook` → `dcsCommand` with `.tmux = .exit` |
| 5 | **tmux Control Parser** | `src/terminal/tmux/control.zig` | `Parser.put()` line 64 | Returns `?Notification` | In `.idle` state, first byte must be `%` or parser enters `.broken`; after `%begin <ts> <cmd> <flags>`, next framing line must be `%end <ts> <cmd> <flags>` or `%error <ts> <cmd> <flags>` with matching token structure; buffer never exceeds `max_bytes` (1 MiB) |
| 6 | **Stream Handler (Viewer glue)** | `src/termio/stream_handler.zig` | `dcsCommand()` line 386, `.tmux` branch | `viewer.next()` line 437, action loop lines 439-460 | On `.enter`, `tmux_viewer` must be `null` before and non-null after; on `.exit`, `tmux_viewer` becomes `null`; for all other notifications, `tmux_viewer` must be non-null; `.command` actions must have `len > 0` and end with `\n` |
| 7 | **Viewer** | `src/terminal/tmux/viewer.zig` | `Viewer.next()` line 314 → `nextTmux()` line 323 | Returns `[]const Action` | In `startup_block`, only `block_end`/`block_err`/`exit` cause transitions; in `startup_session`, only `session_changed`/`exit` cause transitions; in `command_queue`, the first item in `command_queue` determines expected response type; `defunct` state never emits non-empty actions |
| 8 | **PTY Write** | `src/termio/Exec.zig` via mailbox | `messageWriter()` (stream_handler.zig line 138) | `queueWrite()` (Exec.zig line 403) | `.command` action text must have `len > 0` and end with `\n` (asserted at stream_handler.zig:448-449) |

---

## 3. Log Prefix Schema

```
[GHY:PTY:READ]     — raw bytes arriving from tmux on PTY master fd (Exec read thread)
[GHY:PTY:WRITE]    — command bytes queued for tmux on PTY master fd (Exec write path)
[GHY:VT:DCS]       — VT parser DCS-related state transitions
[GHY:DCS:HOOK]     — DCS handler hook/unhook lifecycle
[GHY:DCS:PUT]      — DCS handler byte routing (sampled, not every byte)
[GHY:TMUX:PARSE]   — tmux control parser state changes and notification emissions
[GHY:TMUX:VIEWER]  — Viewer state transitions and action emissions
[GHY:TMUX:CMD]     — commands sent from Viewer to tmux (the text of the command)
[GHY:TMUX:WIN]     — .windows action details (window IDs, pane counts, dimensions)
[INV:WARN]         — condition that may or may not indicate a problem (e.g., defunct on clean exit)
[INV:FAIL]         — invariant violated — should never appear in a healthy run
```

These prefixes are embedded in the log format string, not in the scope name. The scope names remain unchanged (`.io_exec`, `.terminal_dcs`, `.terminal_tmux`, `.io_handler`, `.terminal_tmux_viewer`) to stay consistent with the existing codebase. The `[GHY:*]` prefix is a grep handle inside the message.

---

## 4. Log Placement Specification

### Log 1: PTY Read — Raw Bytes from tmux

**File:** `src/termio/Exec.zig`
**Location:** `ReadThread.threadMainPosix()`, after line 1335 (after `processOutput` call)
**Existing scope:** `.io_exec`
**What is logged:** Byte count on each read chunk
**Invariant checked:** `n > 0` (implicit — we only reach this line if read succeeded with n > 0)

> [ZIG-REVIEW FIX] The Ghostty developers had `log.info("DATA: {d}", .{n})` at
> exactly this location and **intentionally commented it out** (line 1334). This is
> inside the tightest inner loop in the terminal: the PTY read loop iterates
> hundreds of times per second during `capture-pane` and heavy output. Each
> `log.info` call acquires a global mutex (`std.debug.lockStderrWriter`), performs
> a `write` syscall to stderr, and a `flush` — blocking syscalls inside the hot
> path that feeds the VT parser.
>
> **Fix:** Use `log.debug` instead. In non-Debug builds (`std_options.log_level = .info`),
> `log.debug` calls are **compiled out entirely** by the Zig standard library — zero
> runtime cost. The log only fires in Debug builds, where you've already accepted the
> performance penalty. This matches the codebase convention: the commented-out line
> was `log.info`, but by using `log.debug` we get the observability in Debug builds
> without needing to remember to comment it out again.

**Log call:**
```zig
log.debug("[GHY:PTY:READ] n={d}", .{n});
```
**Insert after line 1335**, immediately following the `processOutput` call:
```zig
@call(.always_inline, termio.Termio.processOutput, .{ io, buf[0..n] });
// === BEGIN MVP LOG ===
log.debug("[GHY:PTY:READ] n={d}", .{n});
// === END MVP LOG ===
```

> **Consequence for success criteria:** Criterion #1 (`grep "[GHY:PTY:READ]"`) will
> only produce output in a Debug build. In a release build, this log is absent. This
> is an acceptable tradeoff — the PTY layer is the most well-tested part of Ghostty,
> and the downstream `[GHY:VT:DCS]` log (which fires once, not per-read) is sufficient
> to confirm bytes reached the VT parser.

### Log 2: VT Parser — DCS Entry Detection

**File:** `src/terminal/Parser.zig`
**Location:** `next()` function, inside the entry-action block for `dcs_passthrough` (line 291-305)
**Existing scope:** `.parser`
**What is logged:** DCS params and final byte when transitioning to `dcs_passthrough`
**Invariant checked:** `dcs_hook` action is non-null on `dcs_passthrough` entry
**Log call:**
```zig
// [ZIG-REVIEW NOTE] Using {any} on the params []u16 slice. In Zig 0.15,
// {any} on []u16 prints decimal integers like "{ 1000 }". This is stable
// enough for our diagnostic purpose. We avoid logging individual params
// in a loop to keep the hot-path-adjacent code simple (this fires once
// per DCS sequence, not per byte, so it's not a performance concern).
log.info("[GHY:VT:DCS] dcs_passthrough_entry params={any} final=0x{x:0>2}('{c}')", .{
    self.params[0..self.params_idx],
    c,
    if (c >= 0x20 and c < 0x7f) c else '.',
});
```
**Insert at line 298**, just before `break :dcs_hook`:
```zig
.dcs_passthrough => dcs_hook: {
    if (self.params_idx >= MAX_PARAMS) break :dcs_hook null;
    if (self.param_acc_idx > 0) {
        self.params[self.params_idx] = self.param_acc;
        self.params_idx += 1;
    }
    // === BEGIN MVP LOG ===
    log.info("[GHY:VT:DCS] dcs_passthrough_entry params={any} final=0x{x:0>2}('{c}')", .{
        self.params[0..self.params_idx],
        c,
        if (c >= 0x20 and c < 0x7f) c else '.',
    });
    // === END MVP LOG ===
    break :dcs_hook .{
```

### Log 3: DCS Handler — tmux Hook Detection

**File:** `src/terminal/dcs.zig`
**Location:** `tryHook()`, inside the tmux branch (line 63-74)
**Existing scope:** `.terminal_dcs`
**What is logged:** Confirmation of tmux control mode detection with DCS params
**Invariant checked:** `dcs.params.len == 1 and dcs.params[0] == 1000`
**Log call:**
```zig
log.info("[GHY:DCS:HOOK] tmux_control_mode_detected params={any} final='{c}'", .{
    dcs.params,
    dcs.final,
});
```
> [PEDAGOGICAL-REVIEW] Removed `[INV:OK]` line. If the log says `params={1000}`, the
> invariant "params[0]==1000" is tautologically satisfied. [INV:OK] lines doubled the
> log volume without adding information. Kept [INV:FAIL] and [INV:WARN] which signal
> genuinely unexpected states.

**Insert at line 63**, just before `break :tmux .{`:
```zig
// === BEGIN MVP LOG ===
log.info("[GHY:DCS:HOOK] tmux_control_mode_detected params={any} final='{c}'", .{
    dcs.params,
    dcs.final,
});
// === END MVP LOG ===
break :tmux .{
```

### Log 4: DCS Handler — tmux Unhook

**File:** `src/terminal/dcs.zig`
**Location:** `unhook()`, inside the `.tmux` branch (line 168-171)
**Existing scope:** `.terminal_dcs`
**What is logged:** Control mode exit
**Invariant checked:** State was `.tmux` before unhook
**Log call:**
```zig
log.info("[GHY:DCS:HOOK] tmux_control_mode_exited", .{});
```
**Insert at line 168**, at the start of the `.tmux` unhook branch:
```zig
.tmux => if (comptime build_options.tmux_control_mode) tmux: {
    // === BEGIN MVP LOG ===
    log.info("[GHY:DCS:HOOK] tmux_control_mode_exited", .{});
    // === END MVP LOG ===
    self.state.deinit();
```

### Log 5: DCS Handler — Byte Put (Sampled)

**File:** `src/terminal/dcs.zig`
**Location:** `tryPut()`, inside the `.tmux` branch (line 130-134)
**Existing scope:** `.terminal_dcs`
**What is logged:** When the tmux parser emits a notification (not every byte — only when result is non-null)
**Log call:**
```zig
// Only log when the tmux parser returns a notification
const notif = (try tmux.put(byte)) orelse return null;
log.info("[GHY:DCS:PUT] tmux_parser_emitted notification={s}", .{@tagName(notif)});
return .{ .tmux = notif };
```
**Replace lines 131-133** with:
```zig
.tmux => |*tmux| if (comptime build_options.tmux_control_mode) {
    const notif = (try tmux.put(byte)) orelse return null;
    // === BEGIN MVP LOG ===
    log.info("[GHY:DCS:PUT] tmux_parser_emitted notification={s}", .{@tagName(notif)});
    // === END MVP LOG ===
    return .{ .tmux = notif };
} else unreachable,
```

### Log 6: tmux Control Parser — State Transitions

**File:** `src/terminal/tmux/control.zig`
**Location:** `put()` method, at each state transition point
**Existing scope:** `.terminal_tmux`

**6a. Idle → Notification (line 84-90):**

> [REVIEW FIX] The original plan logged every `idle → notification` transition.
> This fires on EVERY `%` that starts a tmux notification — including every
> `%output` line during steady state. At high output rates (e.g., `find /` in a
> pane), this produces thousands of log lines per second and buries the signal.
>
> **Fix:** Remove this log entirely. The `[GHY:DCS:PUT]` log (Log 5) already
> fires when the parser emits a complete notification, which is the meaningful
> event. The per-`%`-byte transition is a parser implementation detail, not
> a system comprehension event.

**(No log inserted here — removed for noise reduction.)**

**6b. Notification → parse result (line 95-100):**
The `parseNotification()` call is at line 97. Insert just before the return on successful parse. However, since `parseNotification` is complex and we want minimal intrusion, we instead add a single log at the `dcsCommand` entry point in stream_handler.zig (see Log 7 below — the existing `log.info("tmux control mode event cmd={f}", .{tmux})` at line 393 already covers this).

**6c. Block state — `%begin` detected:**
We need to find where `%begin` causes a transition to `.block` state. In `parseNotification()`, search for the block state transition:

**File:** `src/terminal/tmux/control.zig`
**Location:** Within `parseNotification()` — where the parser identifies `%begin` and sets `self.state = .block`

After examining the code, block detection happens when the notification buffer starts with `%begin`. Let me trace this precisely:

<IMPORTANT: After reading the actual parseNotification flow, the `%begin` → `.block` transition happens within `parseNotification()`. Rather than instrumenting deep inside that function, we rely on the existing stream_handler log at line 393 which logs every notification emitted, and add a state-transition log in `put()` at the state changes.>

**6d. Instead, add a single log at the top of `put()` (line 64):**
```zig
pub fn put(self: *Parser, byte: u8) Allocator.Error!?Notification {
    if (self.state == .broken) return null;

    if (self.buffer.written().len >= self.max_bytes) {
        // === BEGIN MVP LOG ===
        log.info("[INV:FAIL] tmux parser buffer exceeded max_bytes={d}", .{self.max_bytes});
        // === END MVP LOG ===
        self.broken();
        return error.OutOfMemory;
    }
```
**Insert at line 71**, before the existing `self.broken()` call. This replaces the default error-only path with a visible invariant violation log.

### Log 7: Stream Handler — Viewer Enter/Exit

**File:** `src/termio/stream_handler.zig`
**Location:** `dcsCommand()`, `.enter` branch (line 396-404) and `.exit` branch (line 407-418)
**Existing scope:** `.io_handler`

Note: Line 393 already has `log.info("tmux control mode event cmd={f}", .{tmux});` which logs every notification. We augment the `.enter` and `.exit` handlers.

**7a. Enter (after line 403, `self.tmux_viewer = viewer`):**
```zig
self.tmux_viewer = viewer;
// === BEGIN MVP LOG ===
log.info("[GHY:TMUX:VIEWER] viewer_created state=startup_block", .{});
// === END MVP LOG ===
break :tmux;
```

**7b. Exit (inside the `if (self.tmux_viewer)` block, after `self.tmux_viewer = null`):**
```zig
self.tmux_viewer = null;
// === BEGIN MVP LOG ===
log.info("[GHY:TMUX:VIEWER] viewer_destroyed", .{});
// === END MVP LOG ===
```

### Log 8: Stream Handler — Viewer Actions

**File:** `src/termio/stream_handler.zig`
**Location:** Action processing loop (lines 439-460)
**Existing scope:** `.io_handler`

Note: Line 438 already has `log.info("tmux viewer action={f}", .{action});` which logs every action. We add detail for `.command` and `.windows`.

**8a. Command action (line 447-454):**
Insert after the `assert` on line 449:
```zig
.command => |command| {
    assert(command.len > 0);
    assert(command[command.len - 1] == '\n');
    // === BEGIN MVP LOG ===
    log.info("[GHY:TMUX:CMD] sending_to_tmux len={d} text=\"{s}\"", .{
        command.len,
        std.mem.trimRight(u8, command, "\n"),
    });
    // === END MVP LOG ===
    self.messageWriter(try termio.Message.writeReq(
```

**8b. Windows action (line 456-458) — replace the TODO:**
```zig
.windows => |windows| {
    // === BEGIN MVP LOG ===
    log.info("[GHY:TMUX:WIN] windows_action window_count={d}", .{windows.len});
    for (windows) |w| {
        log.info("[GHY:TMUX:WIN]   window id={d} {d}x{d}", .{ w.id, w.width, w.height });
    }
    // [PEDAGOGICAL-REVIEW] This is THE GAP. The data is here — window IDs,
    // dimensions, pane layout. Nothing happens with it. The next phase of
    // work starts here: creating a non-exec Backend kind that connects
    // these windows to native Ghostty Surfaces.
    log.info("[GHY:TMUX:WIN] ^^^ THIS DATA IS CORRECT BUT DROPPED — no apprt integration yet", .{});
    // === END MVP LOG ===
},
```

### Log 9: Viewer — State Transitions

**File:** `src/terminal/tmux/viewer.zig`
**Existing scope:** `.terminal_tmux_viewer`

**9a. startup_block → startup_session (line 360-362):**
In `nextStartupBlock`, after `.block_end, .block_err =>` handler, before `return`:
```zig
.block_end, .block_err => {
    self.state = .startup_session;
    // === BEGIN MVP LOG ===
    log.info("[GHY:TMUX:VIEWER] state_transition startup_block->startup_session", .{});
    // === END MVP LOG ===
    return &.{};
},
```

**9b. startup_session → command_queue (inside `nextStartupSession`, line 383-396):**

> [REVIEW-R2 FIX] The original placed this log at line 384, BEFORE `enterCommandQueue`
> is called at line 390. But `enterCommandQueue` is what actually sets
> `self.state = .command_queue` (at viewer.zig:1185). If `enterCommandQueue` fails
> with OOM, the viewer goes to `defunct` instead — meaning the log would falsely
> claim `->command_queue` when the real transition was `->defunct`.
>
> **Fix:** Move the log into `enterCommandQueue` itself, after the state change at
> line 1185. This is the single source of truth for this transition.

In `enterCommandQueue`, after line 1185 (`self.state = .command_queue`):
```zig
    // Move into the command queue state
    self.state = .command_queue;
    // === BEGIN MVP LOG ===
    log.info("[GHY:TMUX:VIEWER] state_transition ->command_queue", .{});
    // === END MVP LOG ===

    return self.singleAction(action);
```

Additionally, add a log at the top of `nextStartupSession`'s `session_changed` handler
for the session info (which is still valuable), but without claiming a state transition:
```zig
.session_changed => |info| {
    self.session_id = info.id;
    // === BEGIN MVP LOG ===
    log.info("[GHY:TMUX:VIEWER] session_changed received session_id={d} name=\"{s}\"", .{
        info.id,
        info.name,
    });
    // === END MVP LOG ===
```

**9c. Terminal creation for a pane — `fn initLayout` at line 1137:**

> [PEDAGOGICAL-REVIEW] This is one of the most important logs for building a mental
> model. The Viewer creates a real Terminal (complete emulator with screen buffers)
> for each tmux pane. This is the fact that makes the apprt integration hard: the
> Viewer already has renderable state, but no Surface to render it into.

In `initLayout`, after line 1155 (after `Terminal.init` succeeds):
```zig
            var t: Terminal = try .init(gpa_alloc, .{
                .cols = @intCast(layout.width),
                .rows = @intCast(layout.height),
            });
            errdefer t.deinit(gpa_alloc);
            // === BEGIN MVP LOG ===
            log.info("[GHY:TMUX:VIEWER] terminal_created pane_id={d} cols={d} rows={d}", .{
                id,
                layout.width,
                layout.height,
            });
            // === END MVP LOG ===
```

**9d. %output routed to a pane's Terminal — `fn receivedOutput` at line 1100:**

> [PEDAGOGICAL-REVIEW] This is the steady-state data path. When the user types in a
> tmux pane, the output flows through the entire pipeline and arrives here. This log
> proves that live data reaches a real Terminal instance.

In `receivedOutput`, after line 1109 (after pane lookup succeeds), before `vtStream`:
```zig
    fn receivedOutput(
        self: *Viewer,
        id: usize,
        data: []const u8,
    ) !void {
        const entry = self.panes.getEntry(id) orelse {
            log.info("received output for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr;
        const t: *Terminal = &pane.terminal;
        // === BEGIN MVP LOG ===
        log.info("[GHY:TMUX:VIEWER] output_routed_to_terminal pane_id={d} data_len={d}", .{
            id,
            data.len,
        });
        // === END MVP LOG ===

        var stream = t.vtStream();
```

**9e. defunct transition — `fn defunct` at line 1215:**

```zig
fn defunct(self: *Viewer) []const Action {
    // === BEGIN MVP LOG ===
    // [REVIEW FIX] The log MUST be before `self.state = .defunct` on line 1216,
    // otherwise @tagName(self.state) always prints "defunct", losing the
    // information about which state we came FROM.
    log.info("[GHY:TMUX:VIEWER] state_transition {s}->defunct", .{@tagName(self.state)});
    // [REVIEW FIX] Changed from [INV:FAIL] to [INV:WARN]. Reaching defunct
    // is expected on clean session exit (tmux sends %exit → Viewer calls
    // defunct()). Using [INV:FAIL] here would cause false positives in
    // success criterion #9. Reserve [INV:FAIL] for conditions that are
    // never legitimate.
    log.info("[INV:WARN] viewer entered defunct state from {s} — check if expected (clean exit) or unexpected (error)", .{@tagName(self.state)});
    // === END MVP LOG ===
    self.state = .defunct;
```

---

## 5. The Control Mode Handshake — Annotated Trace

When Ghostty launches with `command = tmux -CC new-session -s mvp`, the following
sequence occurs. Each phase shows the **Tier 1 log lines** (existing, no code changes)
that you will see, plus the **Tier 2 lines** (from §4 additions) in [brackets].

> **Reading guide:** Lines starting with `→ info(io_handler):` are Tier 1 — they appear
> in any Ghostty build. Lines starting with `→ [GHY:...]` are Tier 2 — they require
> the log additions from §4.

### Phase 1: DCS Detection

```
tmux writes to PTY stdout: \x1bP1000p  (ESC P 1 0 0 0 p — 7 bytes total)
  (0x1b=ESC, 0x50='P', 0x31='1', 0x30='0', 0x30='0', 0x30='0', 0x70='p')

  → [GHY:PTY:READ] n=<7 or more — depends on PTY buffering>  (DEBUG BUILD ONLY)
     The DCS sequence is 7 bytes: ESC(1) + P(1) + "1000"(4) + "p"(1).
     May arrive in one read or split across multiple. The VT parser
     processes byte-by-byte regardless, so chunking doesn't affect correctness.
     NOTE: This log uses log.debug and is compiled out in release builds.

  VT Parser processes byte-by-byte:
  → [GHY:VT:DCS] dcs_passthrough_entry params={ 1000 } final=0x70('p')
     (VT parser collected param 1000, final byte 'p', transitioning to dcs_passthrough)

  DCS Handler hook() called:
  → [GHY:DCS:HOOK] tmux_control_mode_detected params={ 1000 } final='p'

  Stream handler receives .tmux = .enter:
  → info(io_handler): tmux control mode event cmd=terminal_tmux.Notification{ .enter }
  → [GHY:TMUX:VIEWER] viewer_created state=startup_block
```

### Phase 2: Initial Block

```
tmux sends: %begin 1711000000 0 0\n
tmux sends: %end 1711000000 0 0\n

  → [GHY:PTY:READ] n=<varies>

  tmux Parser processes bytes, emits .block_end:
  [REVIEW FIX] Removed the [GHY:TMUX:PARSE] idle->notification line — that log
  was removed in §4 review (too noisy). The DCS:PUT log is sufficient.
  → [GHY:DCS:PUT] tmux_parser_emitted notification=block_end
     (the %begin triggers notification parsing, then block state, then %end causes block_end)

  Stream handler receives .block_end:
  → info(io_handler): tmux control mode event cmd=terminal_tmux.Notification{ .block_end = "" }

  Viewer processes in startup_block state:
  → [GHY:TMUX:VIEWER] state_transition startup_block->startup_session
```

### Phase 3: Session Changed

```
tmux sends: %session-changed $0 mvp\n

  → [GHY:PTY:READ] n=<varies>

  tmux Parser emits .session_changed:
  → [GHY:DCS:PUT] tmux_parser_emitted notification=session_changed

  Stream handler passes to Viewer:
  → info(io_handler): tmux control mode event cmd=terminal_tmux.Notification{ .session_changed ... }

  Viewer receives session info and enters command_queue:
  → [GHY:TMUX:VIEWER] session_changed received session_id=0 name="mvp"
  → [GHY:TMUX:VIEWER] state_transition ->command_queue

  Viewer queues commands and emits first .command action:
  → info(io_handler): tmux viewer action=Viewer.Action{ .command = "display-message -p '#{version}'" }
  → [GHY:TMUX:CMD] sending_to_tmux len=<N> text="display-message -p '#{version}'"
     ↑ This is the FIRST command in the serial protocol. The Viewer will not send
       the next command until it receives the %begin/%end response for this one.
```

### Phase 4: Version Query Response

```
tmux sends: %begin 1711000001 1 0\n
tmux sends: 3.5a\n
tmux sends: %end 1711000001 1 0\n

  → [GHY:PTY:READ] n=<varies>
  → [GHY:DCS:PUT] tmux_parser_emitted notification=block_end

  Viewer processes version response, queues list-windows:
  → info(io_handler): tmux viewer action=Viewer.Action{ .command = "list-windows -F '...'" }
  → [GHY:TMUX:CMD] sending_to_tmux len=<N> text="list-windows -F '...'"
     ↑ Response received → Viewer immediately sends next command. This is the serial dance.
```

### Phase 5: Window List Response

```
tmux sends: %begin 1711000002 2 0\n
tmux sends: $0\t@0\t80\t24\td962,80x24,0,0,0\n
tmux sends: %end 1711000002 2 0\n

  → [GHY:DCS:PUT] tmux_parser_emitted notification=block_end

  Viewer parses window data, emits .windows action:
  → info(io_handler): tmux viewer action=Viewer.Action{ .windows = ... }
  → [GHY:TMUX:WIN] windows_action window_count=1
  → [GHY:TMUX:WIN]   window id=0 80x24
  → [GHY:TMUX:WIN] ^^^ THIS DATA IS CORRECT BUT DROPPED — no apprt integration yet
     ↑ This is THE GAP. The Viewer has the data. Nothing renders it.

  Viewer queues capture-pane commands:
  → [GHY:TMUX:CMD] sending_to_tmux len=<N> text="capture-pane -p -e -q -S - -E -1 -t %0"
```

### Phase 5.5: Terminal Creation

```
Before capture begins, the Viewer already created a Terminal for pane %0:

  → [GHY:TMUX:VIEWER] terminal_created pane_id=0 cols=80 rows=24
     ↑ This is the key insight: the Viewer owns a real Terminal emulator per pane.
       This Terminal has screen buffers, cursor state, mode flags — everything
       needed for rendering. The missing piece is a Surface to render it into.
```

### Phase 6: Capture Sequence (4 captures per pane + state)

```
For each capture-pane response (4 total: primary history, primary visible,
alternate history, alternate visible):
  → [GHY:DCS:PUT] tmux_parser_emitted notification=block_end
  → [GHY:TMUX:CMD] sending_to_tmux len=<N> text="capture-pane ..."
     ↑ Each response feeds captured content into the pane's Terminal instance.
       The Terminal now contains the pane's scrollback + visible area.

Then list-panes for terminal state:
  → [GHY:TMUX:CMD] sending_to_tmux len=<N> text="list-panes -F '...'"
     ↑ Final step: sync cursor position, terminal modes, scroll region, etc.

After state sync completes, command queue empties. The Viewer is READY.
```

### Phase 7: Steady State (Live Output)

```
User types in attached tmux session → tmux sends: %output %0 hello\015\012\n

  → [GHY:PTY:READ] n=<varies>
  → [GHY:DCS:PUT] tmux_parser_emitted notification=output
  → info(io_handler): tmux control mode event cmd=terminal_tmux.Notification{ .output ... }
  → [GHY:TMUX:VIEWER] output_routed_to_terminal pane_id=0 data_len=<N>
     ↑ This is the live data path. The decoded %output bytes are fed into
       pane 0's Terminal via its VT stream parser. The Terminal's screen buffer
       updates. If a Surface were connected, this would render immediately.
  (no [GHY:TMUX:CMD] because %output doesn't generate commands)
```

---

## 6. Setup and Run

This experiment has two tiers. **Tier 1 requires zero code changes** and works with
any installed Ghostty. Start here. Tier 2 adds the MVP log lines from §4 for deeper
visibility — only do this if you need more detail than Tier 1 provides.

### Prerequisites

- macOS with Ghostty installed (either from a release download or a prior build)
- tmux installed: `brew install tmux` (verify: `tmux -V`)

### Tier 1: Zero Code Changes (start here)

Ghostty already has two log lines that show the entire tmux control mode pipeline.
They are compiled into every release build:

- **`stream_handler.zig:393`** — `info(io_handler): tmux control mode event cmd={f}`
  Fires for every tmux Notification: `.enter`, `.exit`, `.block_end`, `.session_changed`,
  `.output`, `.layout_change`, `.window_add`, etc.

- **`stream_handler.zig:438`** — `info(io_handler): tmux viewer action={f}`
  Fires for every Viewer Action: `.command` (text sent to tmux), `.windows` (pane data),
  `.exit`.

Together, these two lines show every notification arriving from tmux AND every action
the Viewer emits in response. This is enough to see the full handshake, the serial
command-response dance, and the `.windows` action being emitted (and silently dropped).

---

#### Tier 1 — Option A: Fully Automated (recommended)

When asking for Tier 1 implementation, the implementation should automate the entire
flow end-to-end with **zero manual steps**:

1. **Config**: Create/back up Ghostty config, add `command = tmux -CC new-session -s mvp`
2. **Clean**: Kill any existing tmux sessions (`tmux kill-server`)
3. **Launch**: Start Ghostty with `GHOSTTY_LOG=stderr` in background, stderr captured to `ghostty.log`
4. **Wait**: Poll the log (or sleep) until the handshake completes (`.windows` action appears)
5. **Interact**: Use `tmux send-keys` to generate `%output` in the session
6. **Stop**: Kill the Ghostty process
7. **Verify**: Run `./smallestmvp/verify.sh ghostty.log` and display results
8. **Cleanup**: Restore original Ghostty config, kill tmux server

The `smallestmvp/verify.sh` script handles step 7 — it tests all 7 hypotheses from §9
against the captured log and prints a PASS/FAIL report. Everything else is standard
shell scripting around the installed Ghostty.app binary.

**Key timing consideration:** The handshake (steps 3-4) takes 1-3 seconds for a
single-pane session on a local machine. A robust implementation should poll the log
for the `.windows` action rather than using a fixed sleep, but a 5-second sleep is
acceptable for an experiment.

---

#### Tier 1 — Option B: Manual Run (if you want to watch it happen yourself)

If you prefer to run the experiment manually — to observe the Ghostty window going
blank, attach to the tmux session yourself, type commands and see the effect in the
logs in real time — follow these steps:

**Step 1: Configure Ghostty to launch tmux in control mode**

```bash
mkdir -p ~/.config/ghostty
# Back up existing config if you have one
cp ~/.config/ghostty/config ~/.config/ghostty/config.bak 2>/dev/null
# Add tmux control mode as the shell command
echo 'command = tmux -CC new-session -s mvp' >> ~/.config/ghostty/config
```

**Step 2: Kill any existing tmux sessions**

```bash
tmux kill-server 2>/dev/null
```

**Step 3: Launch Ghostty from a terminal, capturing stderr**

```bash
# From Terminal.app, iTerm2, or any other terminal (not Ghostty itself):
# CRITICAL: GHOSTTY_LOG=stderr is REQUIRED on macOS. Without it, the log file
# will be empty. The macOS Ghostty.app is built in lib mode (app_runtime=.none),
# which disables stderr logging by default. GHOSTTY_LOG=stderr re-enables it.
# (See src/global.zig:42-49 — Logging.stderr defaults to false for lib mode.)
GHOSTTY_LOG=stderr /Applications/Ghostty.app/Contents/MacOS/ghostty 2>ghostty.log
```

A Ghostty window will open and appear blank — this is expected. The tmux control mode
pipeline is running internally but nothing renders because `.windows` is dropped.

**Step 4: In a separate terminal, interact with the tmux session**

```bash
# Attach to the session tmux created
tmux attach -t mvp

# Type commands to generate %output
echo "hello from mvp"

# Split a pane to trigger %layout-change
tmux split-window

# Create a new window to trigger %window-add
tmux new-window
```

**Step 5: Close Ghostty (Cmd+Q) and examine the logs**

You can examine the logs manually with grep commands, or run the verification script,
or both:

```bash
# --- Option 1: Automated verification ---
./smallestmvp/verify.sh ghostty.log

# --- Option 2: Manual grep exploration ---

# See the full handshake — every notification and every action:
grep 'io_handler.*tmux' ghostty.log | head -40

# See only the Viewer's actions (commands sent, windows emitted):
grep 'tmux viewer action' ghostty.log

# See the serial command dance (commands sent to tmux):
grep 'tmux viewer action.*command' ghostty.log

# See the .windows action (the gap — data arrives, nothing renders):
grep 'tmux viewer action.*windows' ghostty.log

# See live %output notifications:
grep 'tmux control mode event.*output' ghostty.log
```

**Step 6: Clean up**

```bash
# IMPORTANT: Remove the command override or Ghostty will always start in tmux mode
# Restore your backup, or edit the config to remove the 'command = ...' line
cp ~/.config/ghostty/config.bak ~/.config/ghostty/config 2>/dev/null \
  || sed -i '' '/command = tmux/d' ~/.config/ghostty/config
tmux kill-server 2>/dev/null
```

---

#### What you'll see in the Tier 1 logs

Whether you run automated (Option A) or manual (Option B), the log output will
contain lines like:
```
info(io_handler): tmux control mode event cmd=...Notification{ .enter }
info(io_handler): tmux control mode event cmd=...Notification{ .block_end = "" }
info(io_handler): tmux control mode event cmd=...Notification{ .session_changed ... }
info(io_handler): tmux viewer action=...Action{ .command = "display-message -p ..." }
info(io_handler): tmux control mode event cmd=...Notification{ .block_end = "3.5a" }
info(io_handler): tmux viewer action=...Action{ .command = "list-windows -F ..." }
info(io_handler): tmux control mode event cmd=...Notification{ .block_end = "$0\t@0\t..." }
info(io_handler): tmux viewer action=...Action{ .windows = ... }
info(io_handler): tmux viewer action=...Action{ .command = "capture-pane ..." }
  ... (4 more capture-pane round-trips) ...
info(io_handler): tmux viewer action=...Action{ .command = "list-panes -F ..." }
  ... (steady state — %output notifications for each keypress) ...
```

Read these top-to-bottom. You can see the serial dance: notification arrives →
Viewer emits command action → notification arrives (response) → Viewer emits next
command → ... → finally `.windows` action is emitted (and silently dropped).

---

#### Reproducibility: Complete Copy-Paste Script

To reproduce the entire Tier 1 experiment from scratch in one go, copy and paste this
into any terminal (Terminal.app, iTerm2, or any non-Ghostty terminal). This was
validated on macOS with Ghostty 1.3.1, tmux 3.5a, on 2026-04-03.

```bash
#!/usr/bin/env bash
# Tier 1 Reproduction Script — run from any terminal that is NOT Ghostty
# Prerequisites: Ghostty.app installed, tmux installed (brew install tmux)

set -uo pipefail
LOG="$(pwd)/ghostty.log"

echo "=== Step 1: Config ==="
mkdir -p ~/.config/ghostty
cp ~/.config/ghostty/config ~/.config/ghostty/config.bak 2>/dev/null || true
echo 'command = tmux -CC new-session -s mvp' > ~/.config/ghostty/config

echo "=== Step 2: Clean ==="
tmux kill-server 2>/dev/null || true
rm -f "$LOG"

echo "=== Step 3: Launch Ghostty ==="
GHOSTTY_LOG=stderr /Applications/Ghostty.app/Contents/MacOS/ghostty 2>"$LOG" &
PID=$!
echo "Ghostty PID=$PID, logging to $LOG"

echo "=== Step 4: Wait for handshake ==="
for i in $(seq 1 30); do
    grep -q 'tmux viewer action.*\.windows' "$LOG" 2>/dev/null && break
    [ "$i" -eq 30 ] && echo "WARNING: handshake timed out after 30s"
    sleep 1
done
echo "Handshake done (or timed out)"

echo "=== Step 5: Interact ==="
sleep 1
tmux send-keys -t mvp "echo hello-from-smallestmvp" Enter
sleep 2

echo "=== Step 6: Stop Ghostty ==="
kill "$PID" 2>/dev/null
sleep 2
kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null

echo "=== Step 7: Restore config ==="
if [ -f ~/.config/ghostty/config.bak ]; then
    cp ~/.config/ghostty/config.bak ~/.config/ghostty/config
    rm ~/.config/ghostty/config.bak
else
    rm -f ~/.config/ghostty/config
    rmdir ~/.config/ghostty 2>/dev/null || true
fi
tmux kill-server 2>/dev/null || true

echo ""
echo "=== Results ==="
echo "Log file: $LOG ($(wc -l < "$LOG") lines)"
echo "Tmux lines: $(grep -c 'io_handler.*tmux' "$LOG" 2>/dev/null || echo 0)"
echo ""
echo "To validate manually:"
echo "  grep 'io_handler.*tmux' $LOG | head -40"
echo ""
echo "To validate with verify.sh:"
echo "  ./smallestmvp/verify.sh $LOG"
```

**What this produces:** A `ghostty.log` file in the current directory containing the
full tmux control mode handshake. The file is self-contained evidence — it can be
shared, diffed, or re-analyzed at any time.

---

### Tier 2: MVP Log Additions (optional, for deeper visibility)

If Tier 1 doesn't give you enough detail — specifically, if you want to see:
- Viewer state transitions (`startup_block → startup_session → command_queue`)
- Terminal creation per pane (proving the Viewer holds renderable state)
- `%output` bytes reaching a specific pane's Terminal
- The gap explicitly annotated with "THIS DATA IS CORRECT BUT DROPPED"

Then apply the log changes from §4 and rebuild. This requires a build environment:

**On macOS:** Ghostty is built via Xcode (`macos/Ghostty.xcodeproj`). A `zig build`
alone produces only the library, not a runnable app. If you have a working Xcode
setup, build the `Ghostty` scheme. If you don't, Tier 1 is your path.

**On Linux:** `zig build` produces `zig-out/bin/ghostty` directly.

```bash
# Linux only:
cd /path/to/ghostty
git checkout -b smallestmvp
# Apply log changes from §4
zig build
./zig-out/bin/ghostty 2>ghostty.log
```

The Tier 2 logs use `[GHY:*]` prefixes for grep filtering:
```bash
grep -E '\[GHY:' ghostty.log | head -40
```

---

## 7. Success Criteria — Observable & Grep-Verified

### Tier 1 Criteria (zero code changes, using installed Ghostty.app)

- [ ] **1. Pipeline is active — notifications arrive**
  `grep 'tmux control mode event' ghostty.log | head -5`
  → Shows at least: `.enter`, `.block_end`, `.session_changed`

- [ ] **2. Viewer emits commands to tmux**
  `grep 'tmux viewer action.*command' ghostty.log | head -5`
  → Shows at least: `display-message`, `list-windows`, `capture-pane`

- [ ] **3. The serial request-response dance is visible**
  `grep 'io_handler.*tmux' ghostty.log | head -30`
  → Read top-to-bottom. You should see alternating: `event cmd=...block_end` then
  `viewer action=...command` then `event cmd=...block_end` then `viewer action=...command`.
  This proves the Viewer sends one command, waits for the response, sends the next.

- [ ] **4. .windows action is emitted (and silently dropped)**
  `grep 'tmux viewer action.*windows' ghostty.log`
  → At least 1 match. This proves the Viewer assembled window/pane data. The fact
  that nothing renders proves the gap exists.

- [ ] **5. Live %output is received** (requires Step 4 from §6)
  `grep 'tmux control mode event.*output' ghostty.log | head -5`
  → At least 1 match after typing in the attached tmux session.

- [ ] **6. No errors in the tmux pipeline**
  `grep -i 'err\|fail\|broken' ghostty.log | grep -i tmux`
  → Zero results (or only expected messages like "unknown notification" for unhandled types).

### Tier 2 Criteria (with MVP log additions from §4)

All Tier 1 criteria, plus:

- [ ] **7. Viewer state transitions visible**
  `grep '\[GHY:TMUX:VIEWER\].*state_transition\|session_changed received' ghostty.log`
  → Shows (in order): `startup_block->startup_session`, `session_changed received`, `->command_queue`

- [ ] **8. Terminal instances created for panes**
  `grep '\[GHY:TMUX:VIEWER\].*terminal_created' ghostty.log`
  → At least 1 match showing `pane_id=0` with dimensions

- [ ] **9. Live %output reaches a Terminal**
  `grep '\[GHY:TMUX:VIEWER\].*output_routed_to_terminal' ghostty.log`
  → At least 1 match showing `pane_id=0` and `data_len>0`

- [ ] **10. The gap is explicitly annotated**
  `grep 'DROPPED' ghostty.log`
  → Shows "THIS DATA IS CORRECT BUT DROPPED"

- [ ] **11. No invariant violations**
  `grep '\[INV:FAIL\]' ghostty.log`
  → Zero results

---

## 8. Log Navigation Guide

### Tier 1 — Using existing log lines (no code changes)

**Start here: The complete handshake**
```bash
grep 'io_handler.*tmux' ghostty.log | head -40
```
Read top-to-bottom. Every notification and every Viewer action, in order. This is the
full story in one grep.

**The serial command dance**
```bash
grep 'io_handler.*tmux' ghostty.log | grep -E 'block_end|command' | head -20
```
Shows the request-response rhythm: `block_end` (response received) then `command`
(next request sent). Count the commands: version query (1), list-windows (1),
capture-pane x4, list-panes (1) = 7 total.

**The gap**
```bash
grep 'tmux viewer action.*windows' ghostty.log
```
The `.windows` action is emitted — meaning the Viewer has the data. But nothing renders.

**Live output routing**
```bash
grep 'tmux control mode event.*output' ghostty.log | tail -5
```
Shows `%output` notifications from typing in the attached session.

### Tier 2 — Using MVP log additions (with [GHY:*] prefixes)

**The Viewer's full story**
```bash
grep '\[GHY:TMUX:VIEWER\]' ghostty.log
```
~10 lines showing: created → state transitions → Terminal created → output routed.

**Terminal creation proof**
```bash
grep 'terminal_created' ghostty.log
```
Shows the Viewer creating a real Terminal emulator per pane with exact dimensions.

**The gap, explicitly**
```bash
grep 'DROPPED' ghostty.log
```
One line: "THIS DATA IS CORRECT BUT DROPPED."

**Invariant audit**
```bash
grep '\[INV:' ghostty.log
```
`[INV:WARN]` = investigate, `[INV:FAIL]` = broken. A healthy run has at most one
`[INV:WARN]` from clean exit.

---

## 9. Hypothesis-Driven Understanding

Before running anything, read these hypotheses. They are ordered by dependency — each
one builds on the previous. Your job is not to confirm them. Your job is to try to
**disprove** them. The disproofs are where the deepest learning happens.

---

**H1: Ghostty treats tmux's control mode entry as ordinary DCS — there is no
tmux-specific detection until three layers deep**

*What this means:* When tmux sends `ESC P 1000 p`, Ghostty does not have a
tmux-aware layer that intercepts these bytes early. Instead, the bytes pass through
three layers that are each ignorant of what the layer above will do with them:

1. **PTY read loop** — reads raw bytes, has no idea what they mean
2. **VT parser** — recognizes `ESC P` as the start of a DCS sequence (any DCS, not
   specifically tmux), collects the parameter `1000` and final byte `p`
3. **DCS Handler** — sees `params=[1000], final='p'`, and only HERE recognizes this
   as tmux control mode, creating the tmux Parser

The tmux-specific recognition happens in `dcs.zig` `tryHook()` at line 54 — three
function-call layers deep from where the bytes entered the system. The PTY layer
and VT parser have no tmux knowledge whatsoever.

*Why it matters:* This tells you exactly where to look if control mode fails to
activate. The failure can only be in (a) the VT parser not entering DCS state, or
(b) the DCS handler not recognizing parameter 1000. It also means any DCS parsing
bug (even for unrelated features like XTGETTCAP) could affect tmux entry.

*Prediction:* The first log line mentioning "tmux control mode" will come from
`stream_handler.zig:393` (scope `io_handler`), and it will be a `.enter` notification.
No earlier line will mention control mode. The PTY and VT parser layers are silent.

*How to test:*
```bash
# The first control-mode-aware log should be the .enter notification:
grep -n 'tmux control mode' ghostty.log | head -1
# Expected: "tmux control mode event cmd=...Notification{ .enter }"
# Note: "started subcommand path=tmux" may appear earlier but that's the
# process launch log (Exec.zig:1056), which knows nothing about control mode.
```

*How to disprove:*
```bash
# If control mode is detected somewhere other than the stream handler:
grep -n 'tmux control mode\|tmux_control\|control.mode' ghostty.log | head -1 | grep -v 'io_handler'
# Non-empty means something upstream detected tmux before the stream handler.
```

*If disproved:* There is a detection layer before the DCS handler. Check if Ghostty
added early tmux detection since the overview was written. Look at `Parser.zig` for
any tmux-specific state, or at `Termio.processOutput` for pre-VT-parser filtering.

---

**H2: The Viewer's startup follows a strict phase sequence, but notifications that
arrive "out of turn" are silently dropped, not rejected**

*What this means:* The Viewer progresses through three phases in order:
`startup_block` → `startup_session` → `command_queue`. Each phase only transitions
on specific notifications:

- `startup_block` transitions on `block_end` or `block_err` only
- `startup_session` transitions on `session_changed` only
- Both phases silently swallow anything else (including `%output`)

This is NOT "strict" in the sense of rejecting unexpected input. It is strict in the
sense of a funnel: only the expected notification advances the state. Everything else
passes through without effect. A `%output` arriving during `startup_block` (which CAN
happen if a pane produces output before the handshake completes) is simply ignored —
it does not cause an error, and its data is lost.

*Why it matters:* This means the startup handshake is resilient (unexpected
notifications don't break it) but lossy (some pane output during startup is silently
dropped). If you're debugging a case where early pane output seems missing, this
is the reason.

*Prediction:* In the Tier 1 logs, you will see:
1. `.enter`
2. `.block_end` (the initial block response)
3. `.session_changed` (session identification)
4. First `.command` action (only after session_changed)

You may also see `.output` notifications between steps 1 and 4 — these are the
silently-dropped ones. They will have NO corresponding action in the logs.

*How to test:*
```bash
# Extract the startup sequence. Look for the first 10 tmux log lines:
grep 'io_handler.*tmux' ghostty.log | head -10
# Verify: enter → block_end → session_changed → command (in that order)

# Check if any output notifications arrived during startup (before first command):
first_cmd_line=$(grep -n 'tmux viewer action.*command' ghostty.log | head -1 | cut -d: -f1)
grep -n 'tmux control mode event.*output' ghostty.log | awk -F: -v cmd="$first_cmd_line" '$1 < cmd'
# If non-empty: output arrived during startup and was silently dropped. H2 still
# holds (the drop is by design) but note that early output IS lost.
```

*How to disprove:*
```bash
# If a command is emitted before session_changed:
grep -n 'io_handler.*tmux' ghostty.log | grep -E 'session_changed|\.command' | head -2
# If .command appears on a lower line number than session_changed: H2 is false.
# The Viewer is sending commands before identifying the session.
```

*If disproved:* The Viewer either has a fast-path that skips session identification,
or the startup phases can be reordered. Check `nextStartupBlock` and
`nextStartupSession` in viewer.zig for alternative transition paths.

---

**H3: Commands and responses strictly alternate, but live output (`%output`)
interleaves freely between them**

*What this means:* The Viewer sends one command and waits for its `%begin`/`%end`
response block before sending the next command. This command-response pairing is
strict — you will never see two `.command` actions without a `block_end` between them.

HOWEVER, `%output` notifications (live pane output) can and do arrive between a
command send and its response. The Viewer handles `%output` in the `command_queue`
state (viewer.zig:462) without consuming the in-flight command slot. So the real
pattern is:

```
command → [zero or more %output] → block_end → command → [zero or more %output] → block_end → ...
```

*Why it matters:* If you only filter for `command` and `block_end`, you'll see strict
alternation and think the protocol is clean. But the raw log shows `%output`
notifications interleaved, which initially looks like the protocol is messy. It's
not — the Viewer correctly handles both streams simultaneously. Understanding this
dual-stream nature (commands are serial; output is concurrent) is essential for the
apprt integration, which needs to render `%output` while the Viewer is still
initializing panes.

*Prediction:* Filtering for ONLY command and block_end shows strict alternation.
But the raw log shows `%output` events mixed in, especially during the capture-pane
phase (when the session's pane might be producing output while Ghostty is capturing
its history).

*How to test:*
```bash
# Test 1: Command-response alternation (filtering out %output):
grep 'io_handler.*tmux' ghostty.log | grep -E '\.command|block_end' | head -20
# Should show strict alternation: command → block_end → command → block_end

# Test 2: Now look at the raw stream to see %output interleaving:
grep 'io_handler.*tmux' ghostty.log | grep -E '\.command|block_end|\.output' | head -30
# You may see: command → output → output → block_end → command → ...
# This is expected — %output arrives asynchronously from the pane.
```

*How to disprove:*
```bash
# Check for two consecutive commands with no block_end between them:
grep 'io_handler.*tmux' ghostty.log | grep -E '\.command|block_end' | \
  awk '/command/{if(last=="command") print NR": VIOLATION"; last="command"} /block_end/{last="block_end"}'
# Any "VIOLATION" means the serial constraint is broken.
```

*If disproved:* The Viewer pipelines commands — it sends a new command before the
previous response arrived. This would make the `%begin`/`%end` correlation by
timestamp and command number critical. Check the `command_consumed` logic in
`nextCommand` (viewer.zig:439-554).

---

**H4: The Viewer creates a full Terminal emulator instance for each tmux pane — the
same type Ghostty uses for its normal surfaces**

*What this means:* When the Viewer discovers a pane through `list-windows`, it calls
`Terminal.init()` (viewer.zig:1152) with the pane's exact column and row dimensions.
This Terminal is the SAME `Terminal` type defined in `src/terminal/Terminal.zig` that
Ghostty uses for its normal (non-tmux) terminal surfaces. It has primary and alternate
screen buffers, cursor state, mode flags, scroll region, tab stops, and a VT parser.

The Viewer then populates this Terminal by feeding it the captured pane content
(scrollback + visible area, both primary and alternate screens) via the Terminal's
VT stream parser — the same way normal terminal output is processed.

*Why it matters:* This is why the apprt integration is a plumbing problem, not a data
problem. The Viewer already holds renderable state. A tmux-backed Surface doesn't need
to build its own Terminal — it needs to connect to the one the Viewer already owns.

*Prediction (Tier 1):* After the `list-windows` response (`block_end`), the Viewer
immediately queues `capture-pane` commands. The existence of capture-pane commands
is proof that Terminal instances exist — there is nothing else to capture INTO.

*Prediction (Tier 2):* Direct log: `terminal_created pane_id=0 cols=80 rows=24`.

*How to test:*
```bash
# Tier 1: capture-pane commands prove Terminals exist:
grep 'tmux viewer action.*command' ghostty.log | grep 'capture-pane'
# Should show 4 capture-pane commands per pane (primary history, primary visible,
# alternate history, alternate visible).

# Tier 2: Direct proof of Terminal creation and output routing:
grep -E 'terminal_created|output_routed_to_terminal' ghostty.log
```

*How to disprove:*
```bash
# No capture-pane commands means no Terminal to capture into:
grep 'capture-pane' ghostty.log | wc -l | tr -d ' '
# If "0": H4 is wrong. The Viewer either doesn't create Terminals or doesn't
# populate them. Read initLayout in viewer.zig to understand what happens instead.
```

*If disproved:* The Viewer is lighter-weight than expected. The apprt integration
would need to create and populate Terminal instances itself, making it significantly
more complex. Reread `viewer.zig` `initLayout` and `syncLayouts`.

---

**H5: Data flows bidirectionally through the same PTY, but on different threads and
through completely different code paths**

*What this means:* Ghostty forks tmux as a subprocess connected via a single PTY.
Data flows in both directions through this PTY, but the paths are asymmetric:

**tmux → Ghostty (read path):**
```
tmux stdout → PTY fd → ReadThread.threadMainPosix [read thread]
  → Termio.processOutput (acquires renderer_state.mutex)
  → StreamHandler.nextSlice → VT parser → DCS handler → tmux Parser
  → StreamHandler.dcsCommand → Viewer.next()
  → returns Actions to stream handler
```
All of this happens synchronously on the **read thread**, under the renderer mutex.

**Ghostty → tmux (write path):**
```
Viewer emits .command Action
  → StreamHandler processes action [still on read thread]
  → messageWriter → termio_mailbox.send() [crosses thread boundary]
  → IO thread drains mailbox
  → Exec.queueWrite → xev stream → PTY master fd
  → tmux stdin
```
The write path starts on the read thread but **crosses to the IO thread** via a
mailbox. The actual `write()` syscall to the PTY happens on the IO thread, not
the read thread.

*Why it matters:* This asymmetry is critical for the apprt integration:
1. The Viewer runs on the read thread, so it cannot block or do slow work
2. Commands going to tmux are asynchronous — the Viewer emits a `.command` action
   and returns immediately; the actual write happens later on the IO thread
3. The Viewer will never see its own command reflected back immediately — there is
   always a round-trip through the IO thread, the PTY, tmux, and back through the
   read path

Understanding this bidirectional flow is essential for designing the input routing
path (keystrokes → `send-keys` → tmux) in the eventual integration.

*Prediction:* In the Tier 1 logs, you will see `.command` actions (the write path
initiation) interleaved with `event cmd=` lines (the read path). But the `.command`
appears BEFORE its effect is visible — the write has not happened yet when the action
is logged. The response (`block_end`) appears later, after the full round-trip:
Viewer emits command → mailbox → IO thread → PTY write → tmux processes → tmux
responds → PTY read → VT parser → tmux parser → Viewer receives response.

*How to test:*
```bash
# Show the command-response pairs to see the round-trip:
grep 'io_handler.*tmux' ghostty.log | grep -E '\.command|block_end' | head -14
# Each .command is the Viewer initiating a write (on the read thread).
# Each block_end is the response arriving (also on the read thread, after the
# full round-trip through the IO thread, PTY, and tmux).

# Verify the write path crosses threads — look for mailbox activity:
# (This requires Tier 2 or a debug build; Tier 1 can only see the effect.)
grep 'io_handler.*tmux viewer action.*command' ghostty.log | head -3
# These lines fire on the READ thread. The actual PTY write happens later
# on the IO thread — you won't see a separate log for it in Tier 1, but
# the fact that block_end responses eventually arrive proves the write
# succeeded.
```

*How to disprove:*
```bash
# If commands never get responses, the write path is broken:
cmd_count=$(grep 'tmux viewer action.*command' ghostty.log | wc -l | tr -d ' ')
resp_count=$(grep 'tmux control mode event.*block_end' ghostty.log | wc -l | tr -d ' ')
echo "Commands sent: $cmd_count, Responses received: $resp_count"
# If resp_count < cmd_count: some commands never got responses. The write path
# (mailbox → IO thread → PTY) may be broken, or tmux is not responding.

# If resp_count > cmd_count: there are unsolicited block responses — tmux sent
# blocks that were not in response to a Viewer command (possibly from another client).
```

*If disproved (commands without responses):* The mailbox or IO thread write path is
failing silently. Check `Exec.queueWrite` (Exec.zig:403) and the xev stream write
callback. Also check if tmux is actually running — it may have exited.

*If disproved (responses without commands):* tmux is sending unsolicited block
responses. This could happen if another tmux client is sending commands to the same
session. Check if `tmux list-clients` shows multiple clients.

---

**H6: The `.windows` action contains enough data to create native tabs and splits**

*What this means:* When the Viewer emits a `.windows` action, it carries an array
of `Window` structs, each containing: a window ID, width, height, and a parsed `Layout`
tree. The Layout tree has already been parsed from tmux's compact layout string into
a tree of nodes (pane leaves and horizontal/vertical container nodes). Each pane leaf
has a pane ID that maps to a Terminal instance in the Viewer's panes hash map.

This is everything the apprt layer needs to create native GUI elements.

*Why it matters:* If the data is complete, the next phase of work is purely GUI
plumbing. If the data is incomplete (e.g., no layout tree, or pane IDs don't match
the Viewer's internal state), more Viewer work is needed first.

*Prediction:* The `.windows` action in the logs will show window data with IDs
and dimensions. The full command sequence will have completed (version query +
list-windows + captures + state sync), meaning the Terminals are populated.

*How to test:*
```bash
# Check the .windows action has real content:
grep 'tmux viewer action.*windows' ghostty.log
# Should show window data (not empty).

# Verify the full initialization completed — count commands:
grep 'tmux viewer action.*command' ghostty.log | wc -l
# For a 1-pane session: expect 7 (version + list-windows + 4 captures + list-panes).
# For a 2-pane session: expect 12 (version + list-windows + 8 captures + list-panes).
# The formula: 2 + (4 × num_panes) + 1.
```

*How to disprove:*
```bash
# If .windows shows nothing useful, or initialization is incomplete:
grep 'tmux viewer action.*windows' ghostty.log | head -1
# If this line is missing entirely, the Viewer never reached the point of emitting
# window data. Check for errors or defunct transitions earlier in the log.
```

*If disproved:* The Viewer's initialization stalled or errored. Look for `warn` or
`err` level logs near the point where the sequence stops. The most common causes
would be a `%error` response to one of the capture-pane commands, or a tmux version
incompatibility in the format strings.

---

**H7: The gap is purely a missing consumer — the entire producer pipeline is correct**

*What this means:* Every layer from PTY read through VT parser through DCS handler
through tmux control parser through Viewer works correctly. The Viewer produces
complete `.windows` actions with fully populated Terminal instances. The ONLY missing
piece is the `// TODO` at `stream_handler.zig:456` where the `.windows` action should
create native Ghostty tabs and splits.

*Why it matters:* If H1-H6 all hold, the next step is "build the GUI glue." If any
fail, the next step is "fix the pipeline." This hypothesis is the gate between
understanding and implementation.

*Prediction:* All of H1-H6 hold. No errors appear in the tmux-related logs.

*How to test:*
```bash
# Comprehensive check:
echo "=== H1: First tmux log ==="
grep -n 'tmux control mode' ghostty.log | head -1

echo "=== H2: Startup order ==="
grep 'io_handler.*tmux' ghostty.log | head -6

echo "=== H3: Command-response pattern ==="
grep 'io_handler.*tmux' ghostty.log | grep -E '\.command|block_end' | head -16

echo "=== H4: Capture-pane issued ==="
grep 'capture-pane' ghostty.log | wc -l

echo "=== H5: Bidirectional flow (commands sent, responses received) ==="
echo -n "Commands: "; grep 'tmux viewer action.*command' ghostty.log | wc -l
echo -n "Responses: "; grep 'tmux control mode event.*block_end' ghostty.log | wc -l

echo "=== H6: .windows has data ==="
grep 'tmux viewer action.*windows' ghostty.log

echo "=== H7: No pipeline errors ==="
grep -iE 'err|fail|broken|defunct' ghostty.log | grep -i tmux | grep -v 'unknown.*notification'
```

*How to disprove:*
```bash
# Any tmux-related error (excluding expected "unknown notification"):
grep -iE 'err|fail|broken|defunct' ghostty.log | grep -i tmux | grep -v 'unknown.*notification'
# Non-empty means the pipeline has a problem. Read the error to identify which subsystem.
```

*If disproved:* Do not proceed to apprt integration. Fix the pipeline issue first.
The error log will name the subsystem. Cross-reference with §2 (Subsystem Inventory).

---

### Running Your Proof Session

This is not optional ceremony. The structure exists because predictions you write down
BEFORE seeing the data are the only ones that can genuinely surprise you. Surprises are
where learning happens.

**Before launching Ghostty:**

1. Read all seven hypotheses above.

2. Create a scratch file for your predictions:
```bash
cat > ~/tmux-mvp-predictions.md << 'EOF'
# My predictions before running the experiment
Date: $(date)

## H1: tmux detection happens 3 layers deep (PTY → VT → DCS handler)
My prediction: [yes/no/unsure]
Notes:

## H2: Startup phases are strict but silently drop unexpected notifications
My prediction: [yes/no/unsure]
Notes:

## H3: Commands alternate strictly with responses, but %output interleaves freely
My prediction: [yes/no/unsure]
Notes:

## H4: Real Terminal instances created (capture-pane proves it)
My prediction: [yes/no/unsure]
Notes:

## H5: Data flows bidirectionally — read thread vs IO thread
My prediction: [yes/no/unsure]
Notes:

## H6: .windows action has complete data for GUI creation
My prediction: [yes/no/unsure]
Notes:

## H7: Pipeline is error-free (gap is only a missing consumer)
My prediction: [yes/no/unsure]
Notes:
EOF
```

3. For each hypothesis, write your prediction. "Yes" or "No" is fine. If you write
   "unsure," note what you're uncertain about.

**Run the experiment** (follow §6 Tier 1 steps).

**After capturing logs, work through each hypothesis in order:**

4. For each hypothesis, run the "How to test" command. Compare the output against your
   prediction.

5. If a hypothesis holds: note it and move on. The confirmation is useful but not
   surprising.

6. **If a hypothesis is disproved:** Stop. This is the important moment. Write down:
   - What your mental model predicted
   - What the logs actually showed
   - What the correct model must be
   - Which file/function you would read next to understand why

   Then continue to the remaining hypotheses — a disproof at H2 does not invalidate H4,
   because the hypotheses test different aspects of the system.

7. After all seven hypotheses are tested, you have a verified mental model of the tmux
   control mode pipeline. Any hypothesis that held is now grounded in evidence, not
   assumption. Any hypothesis that failed has taught you something the documentation
   could not.

---

## 10. Risks & Blind Spots

### What this experiment will NOT show

1. **Rendering.** The tmux-backed Terminal instances inside the Viewer are populated with content, but nothing renders them to pixels. We cannot verify that pane content is correct by looking at the screen — only by adding a temporary Terminal dump log (not included in this MVP to keep scope minimal).

2. **Input routing.** We do not send keystrokes to tmux via `send-keys`. The user cannot type into the tmux-controlled window. This experiment is observation-only in the tmux→Ghostty direction.

3. **Resize handling.** No `refresh-client -C WxH` is sent when the Ghostty window resizes. The tmux session may have mismatched dimensions.

4. **Flow control.** No `refresh-client -f pause-after=N` is sent. If a fast-producing command runs in the tmux session, the control mode client may fall behind and eventually be disconnected (tmux's 300-second timeout).

5. **Window close / session rename.** `%window-close` and `%session-renamed` are not in the Notification union and will be logged by the existing `log.warn("unknown tmux control mode notification={s}")` at control.zig:478.

6. **Multi-window/pane content verification.** We log window and pane counts but do not verify that the Terminal instances contain the correct screen content. A future experiment should dump Terminal screen buffers.

7. **PTY write path observability.** We log the `.command` action text in the stream handler, but we do not log the actual bytes written to the PTY master fd. The mailbox and xev write path are not instrumented. If a command is queued but never written, we would not detect it from these logs alone.

8. **Read thread chunking.** The PTY read uses a 1024-byte buffer. A single tmux notification may span multiple reads, or multiple notifications may arrive in one read. The `[GHY:PTY:READ]` log shows raw chunks, not protocol-aligned messages. Correlating raw bytes to parsed notifications requires manual hex analysis.

9. **processOutput boundary.** [REVIEW ADDITION] The `Termio.processOutput()` call on the read thread (Exec.zig:1335) crosses a critical boundary: it calls into `StreamHandler.nextSlice()` which feeds bytes to the VT parser, all still on the read thread. This boundary is not instrumented. If the VT parser were to silently drop bytes (e.g., due to an internal state error), neither `[GHY:PTY:READ]` nor `[GHY:VT:DCS]` would detect it, because the PTY log fires before parsing and the DCS log fires only on `dcs_passthrough` entry. A gap between "bytes read" and "DCS entered" would be invisible.

10. **`[GHY:TMUX:PARSE]` prefix unused.** [REVIEW ADDITION] The log prefix schema defines `[GHY:TMUX:PARSE]` but after the noise-reduction fix (removing the idle→notification log), no log line actually uses this prefix. The prefix is retained in the schema for future use, but success criteria should not depend on it.

11. **`%begin` lines produce no log.** [REVIEW-R2 ADDITION] When the tmux control parser sees `%begin`, it transitions from `.notification` to `.block` state and returns `null` — not a Notification. This means `dcs.Handler.put()` returns null, `StreamHandler.dcsPut()` does not call `dcsCommand()`, and no `[GHY:DCS:PUT]` log fires. The `%begin` line is completely invisible in the log output. You will see `[GHY:DCS:HOOK]` (DCS detected) then silence until `[GHY:DCS:PUT] notification=block_end` (when `%end` arrives). This is correct protocol behavior — `%begin` is not a complete notification, just a state transition — but it creates a comprehension gap: the engineer won't know that `%begin` was received and parsed. The same applies to all bytes accumulated during `.block` state.

12. **macOS build path (mitigated).** On macOS, `zig build` produces `libghostty`, not a standalone executable. However, Tier 1 of this experiment requires no build at all — it uses the installed Ghostty.app directly. This is no longer a stumbling block for the primary path.

### Questions that remain unanswered after this experiment

- Does the Viewer correctly handle a tmux session with multiple pre-existing windows and panes? (Requires running `tmux -CC attach` to an existing complex session)
- Does the `%output` content actually render correctly if a Surface were connected? (Requires the apprt/surface integration work)
- What happens if tmux exits unexpectedly during the handshake? (Requires killing tmux during the startup sequence)
- Is the command queue correctly serialized under concurrent `%layout-change` and `%output` notifications? (Requires high-throughput testing)

---

*Plan reviewed against quality gate:*
- [x] Every log placement names a real file found during recon (§0)
- [x] Every invariant is falsifiable — a test could check for violation
- [x] The annotated trace (§5) could be diff'd against real output
- [x] A developer who has never seen this codebase could follow §6 and get logs flowing
- [x] §7 has zero criteria that require human judgment to evaluate

---

## Review Changelog

The following issues were found and fixed during critical review:

**Zig API error:** `std.fmt.fmtSliceHexLower` does not exist in Zig 0.15 or anywhere
in this codebase. Log 1 was simplified to log only the byte count, with a rationale
that hex-dumping the hot read path would be excessively noisy anyway.

**Byte count error in trace:** Phase 1 claimed `n=4` for the DCS sequence `\x1bP1000p`.
The actual byte count is 7: ESC + P + four digit chars + final byte. Fixed.

**Noise problem:** Log 6a (`idle → notification` on every `%` byte) would fire on every
single tmux notification during steady state, drowning the signal. Removed entirely —
the downstream `[GHY:DCS:PUT]` log on complete notifications is sufficient.

**False positive invariant:** `defunct` was tagged `[INV:FAIL]` but is legitimately
reached on clean exit. Changed to `[INV:WARN]` with explanatory text. Success
criterion #9 now only greps for `[INV:FAIL]`, so clean exits won't cause false failures.

**Defunct log ordering:** The log must fire before `self.state = .defunct` or
`@tagName(self.state)` always prints "defunct." Verified the placement is correct
and added an explicit ordering note.

**Grep typo:** The invariant audit grep was `"\[INV:\]"` which matches nothing
(the actual tags are `[INV:OK]`, `[INV:WARN]`, `[INV:FAIL]`). Fixed to `"\[INV:"`.

**Build recommendation:** Changed from `-Doptimize=Debug` (extremely slow compile,
laggy binary) to default build. All MVP logs use `log.info`, which is captured at
the default `.info` log level.

**CLI vs config file:** Deprioritized `--command=` CLI flag in favor of config file
approach. The CLI flag requires careful shell quoting; the config file is unambiguous.

**Success criterion precision:** Criterion #2 no longer asserts an exact format string
for the params slice — Zig's `{any}` rendering of `[]u16` is implementation-defined.

**Added blind spots:** (1) `processOutput` boundary between read thread and VT parser
is uninstrumented — silent byte drops would be invisible. (2) `[GHY:TMUX:PARSE]`
prefix is defined in schema but no log line uses it after the noise fix.

---

### Review R2 Changelog (second review pass)

**macOS build is wrong.** On macOS, `app_runtime` defaults to `.none`
(src/apprt/runtime.zig:22), so `zig build` produces libghostty, not a standalone
binary. `zig-out/bin/ghostty` does not exist on macOS. Fixed §6 with Xcode build
instructions and a fallback noting that existing log lines in the installed app
provide partial observability even without recompiling.

**Log 9b false invariant.** The log claimed `startup_session->command_queue` at line 384,
before `enterCommandQueue` was called at line 390. If `enterCommandQueue` fails (OOM),
the actual transition is `->defunct`, making the log a lie. Fixed by moving the
state-transition log INTO `enterCommandQueue` (after `self.state = .command_queue`
at viewer.zig:1185), and keeping only a session-info log at the original location.

**`%begin` silent gap.** The tmux control parser returns `null` (not a Notification)
when it sees `%begin` — it transitions to `.block` state internally. This means no
`[GHY:DCS:PUT]` log fires for `%begin`. Added as blind spot #11. Not fixed because
adding a log inside `parseNotification()` for the `%begin` case would require modifying
the return path of a function that returns `null` for this case, and the `%begin` → block
transition is an internal parser detail, not a system comprehension event.

**Line number correction:** `Parser.next()` is at line 251, not 238. Fixed in §2 inventory.

---

### Zig Compiler Review Changelog (third review pass)

**Hot-path log.info in PTY read loop (Log 1).** Changed from `log.info` to `log.debug`.
The PTY read inner loop (`ReadThread.threadMainPosix`, line 1306) runs hundreds of
iterations per second during heavy output. Each `log.info` call acquires
`std.debug.lockStderrWriter` (global mutex), writes to stderr, and flushes — all
blocking syscalls. The Ghostty developers had an identical log at line 1334
(`// log.info("DATA: {d}", .{n})`) and intentionally commented it out. Using
`log.debug` means the call is compiled out in release builds (`std_options.log_level`
is `.info` for non-Debug), making it zero-cost. The tradeoff: criterion #1 only works
in Debug builds. Added a release-build fallback criterion using `[GHY:VT:DCS]`.

**No per-scope filtering exists.** Ghostty has no `log_scope_levels` or runtime scope
filter. `GHOSTTY_LOG` (src/global.zig:114) only controls output targets (stderr,
macOS unified logging), not scope filtering. All `log.info` calls from all scopes go
to the same stderr stream. The plan's `[GHY:*]` grep prefix is the correct mitigation.
No code change needed, but engineers should be aware that live stderr will include
ALL info-level output from font loading, config, renderer, etc.

**All @tagName() calls verified safe.** Every enum/union targeted by `@tagName` in
the plan is either a plain `enum` or `union(enum)` — none are `extern` or
non-exhaustive. Specifically verified:
- `control.Notification`: `union(enum)` at control.zig:498
- `viewer.State`: `enum` at viewer.zig:1221
- `viewer.Action`: `union(enum)` at viewer.zig:196
`@tagName` with `{s}` format specifier is used throughout the codebase
(e.g., `gtk/class/application.zig:358`).

**`{any}` on `[]u16` verified.** The plan uses `{any}` to format the VT parser's
`params` slice. This pattern appears (commented out) at `stream.zig:1416`. In Zig 0.15,
`{any}` prints `u16` integers in decimal. The `[NEEDS VERIFICATION]` marker from R2
has been removed.

**All log.info calls survive release builds.** `std_options.log_level` is `.info` in
non-Debug mode (main_ghostty.zig:175). All MVP log calls except Log 1 use `log.info`,
which compiles and runs in ReleaseSafe/ReleaseFast. Log 1 uses `log.debug`, which is
compiled out — this is intentional (hot-path protection).

---

### Pedagogical Review Changelog (fourth review pass)

**Added "What You Will Understand" section (§0).** The original opened with tables of
file paths and line numbers — a reference, not a guide. The new §0 front-loads five
concrete learning goals so the engineer knows what to look for before they see a single
log line. An engineer who reads only §0 and §5 (the annotated trace) gets 80% of the
value of the whole document.

**Added architecture diagram with thread boundaries.** The ASCII diagram in §0.1 shows
the full data flow, the thread model, ownership of state, and the gap — all in one
picture. This builds more mental model in 30 seconds of reading than any number of log
lines. The diagram labels which code runs under `renderer_state.mutex` and which
thread each component lives on.

**Removed all `[INV:OK]` log lines.** Every `[INV:OK]` was a second log line that
restated the first. Example: `[GHY:DCS:HOOK] tmux_control_mode_detected params={1000}`
followed by `[INV:OK] DCS tmux hook: params[0]==1000` — the second line adds zero
information. Removing them halves the log volume in the handshake trace. Kept `[INV:FAIL]`
and `[INV:WARN]` which signal genuinely unexpected states.

**Added Terminal creation log (Log 9c).** `initLayout` at viewer.zig:1152 creates a
`Terminal.init()` for each new pane. This is the single most important fact for
understanding the apprt integration challenge: the Viewer already holds renderable
state. Without this log, the engineer only sees window/pane counts, not the internal
Terminal instances.

**Added %output→Terminal routing log (Log 9d).** `receivedOutput` at viewer.zig:1100
is the steady-state data path. This log proves that live data reaches a Terminal
instance — the pipeline works end-to-end internally, it just doesn't render.

**Added gap annotation in .windows log (Log 8b).** The `.windows` handler now logs
`THIS DATA IS CORRECT BUT DROPPED`. This makes the gap greppable and self-documenting.
An engineer who sees this line in the log immediately understands the problem.

**Replaced INV:OK counting criterion (#8) with request-response pattern criterion.**
The old criterion checked that INV:OK counts matched CMD counts — a mechanical check
that taught nothing. The new criterion asks the engineer to observe the alternating
CMD → block_end → CMD → block_end pattern, which is the most non-obvious architectural
insight in the system.

**Reordered log navigation guide.** Moved "Viewer's story" to the top as recommended
first read. The full dump is now last. An engineer who starts with
`grep "[GHY:TMUX:VIEWER]"` sees ~10 lines that tell the complete Viewer lifecycle.

**Annotated the handshake trace (§5) with teaching notes.** Added inline ↑ annotations
explaining WHY each event matters, not just WHAT it is. Phase 5.5 (Terminal creation)
was added as a new phase. Phase 7 now shows `output_routed_to_terminal`.

**`[NEEDS VERIFICATION]` items:**
- The Xcode project path `macos/Ghostty.xcodeproj` and scheme name `Ghostty` were verified. The `xcodebuild` output path `[NEEDS VERIFICATION]` — the derived data location depends on Xcode settings and may not be `macos/build/Debug/`. Use `xcodebuild -showBuildSettings | grep BUILT_PRODUCTS_DIR` to find the actual output path after building.
- The `{any}` format specifier for `self.params[0..self.params_idx]` in Log 2 was verified: `{any}` on `[]u16` slices is used elsewhere in the codebase (e.g., commented-out line at `stream.zig:1416`). Zig 0.15 prints `u16` values as decimal in `{any}` formatting.
