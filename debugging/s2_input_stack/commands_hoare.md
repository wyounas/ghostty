# S2 Hoare-Style Commands

This file treats the `s2_input_stack` walkthrough as a sequence of observable
preconditions and postconditions:

```text
{ precondition } line executes { postcondition }
```

The purpose is to make each stop teach one precise fact about the input path,
without overclaiming about hidden state.

## Ground rules

1. This session proves control-flow order better than it proves big struct
   contents.

2. A plain single ASCII character such as `l` is the best probe.
   For that case, you will usually see a `write_small` request later in the
   path. More complex keys may still be correct, but they make the shape of the
   later message less simple.

3. If a keybinding consumes the key, the session will diverge before the write
   path. For a plain `l` in an ordinary shell-focused surface, the expected
   path is "not consumed by a binding, then encoded, then queued."

4. If LLDB shows low-level or noisy values, trust:
   - source position
   - thread identity
   - stop order
   more than giant dumps.

5. Some function-entry breakpoints stop before LLDB has stabilized all local
   values for display. If an argument looks unavailable or nonsense at the
   first stop inside a function, validate the control-flow fact first, then use
   `next` once or twice before trusting the printed value.

## Setup

Run:

```bash
sh debugging/s2_input_stack/run.sh
```

At the LLDB prompt:

```lldb
breakpoint list
```

Confirm:

- breakpoint `1` at `embedded.zig:1765` is enabled
- breakpoints `2` through `10` are disabled

Then:

```lldb
run
```

Wait until Ghostty is visibly usable, then type a single `l`.

Recommended baseline commands at each stop:

```lldb
frame info
source list
thread backtrace
frame variable --show-types
```

## Stop 1: `ghostty_surface_key` at `embedded.zig:1765`

Source:

```zig
) bool {
    return surface.app.keyEvent(
```

### Preconditions

Before this line executes:

- a surface window is already usable
- you typed a key into that surface
- the call is entering Zig through the surface-key export boundary

### Validate the preconditions

Run:

```lldb
thread backtrace
source list -l 1765
frame variable --show-types surface
frame variable --show-types event
```

What this proves:

- this is the first useful Zig boundary for surface key input
- the path is surface-targeted, not app-global key handling

### Postcondition

After this call site executes, the key event is forwarded into the shared
embedded app/surface dispatch helper.

### Validate the postcondition

Use:

```lldb
continue
```

Then confirm the next relevant stop is `embedded.App.keyEvent`.

## Stop 2: `embedded.App.keyEvent` at `embedded.zig:183`

Source:

```zig
) !bool {
    const input_event: input.KeyEvent = event.core() orelse return false;
```

### Preconditions

Before this helper proceeds:

- control already crossed the surface-key export boundary
- the helper still has a platform/apprt-flavored event, not final terminal
  bytes
- the target should be `.surface`

### Validate the preconditions

Run:

```lldb
thread backtrace
source list -l 183
frame variable --show-types target
```

If `event` is unavailable here, that is acceptable. This stop is still useful
because the control-flow fact is "the shared dispatch helper was entered."

### Postcondition

If `event.core()` succeeds and the target is `.surface`, the next meaningful
stop should be `Surface.keyCallback`.

### Validate the postcondition

Use:

```lldb
continue
```

Then confirm the next relevant stop is `Surface.zig:2607`.

## Stop 3: `Surface.keyCallback` at `Surface.zig:2607`

Source:

```zig
pub fn keyCallback(self: *Surface, event_orig: input.KeyEvent) !InputEffect
```

### Preconditions

Before this function begins:

- the event has already crossed the export boundary and shared dispatch helper
- Ghostty now has an `input.KeyEvent`
- no binding decision has happened yet inside this function
- no PTY write has happened yet

### Validate the preconditions

Run:

```lldb
thread backtrace
source list -l 2607
frame variable --show-types event_orig
```

### Postcondition

As control moves deeper into `keyCallback`, Ghostty will first consider
bindings before deciding whether to encode terminal input.

### Validate the postcondition

Use:

```lldb
continue
```

Then confirm the next relevant stop is `Surface.zig:2649`.

## Stop 4: binding check at `Surface.zig:2649`

Source:

```zig
if (try self.maybeHandleBinding(...)) |v| return v;
```

### Preconditions

Before this line executes:

- Ghostty is still in the surface input path
- it has not yet encoded any terminal bytes for this key
- it is about to ask whether the key should be consumed as a binding

### Validate the preconditions

Run:

```lldb
source list -l 2649
frame variable --show-types event
```

### Postcondition

For this session's intended probe key (`l`), if the key is not consumed as a
binding, execution later reaches the encoding path.

### Validate the postcondition

Use:

```lldb
continue
```

Then check whether you later reach `Surface.zig:2752`.

That proves the key was **not** consumed by a binding in this run.

## Stop 5: encoding decision at `Surface.zig:2752`

Source:

```zig
if (try self.encodeKey(...)) |write_req| {
```

### Preconditions

Before this line executes:

- the key was not consumed as a binding
- Ghostty is now deciding whether this key produces terminal input bytes
- no write request has been forwarded yet

### Validate the preconditions

Run:

```lldb
source list -l 2752
frame variable --show-types event
```

### Postcondition

If `encodeKey` succeeds, Ghostty will enter the success branch with a
`write_req`, then later forward it at line 2765.

### Validate the postcondition

Use:

```lldb
continue
```

Then confirm you later reach `Surface.zig:3139` and then `Surface.zig:2765`.

## Stop 6: `encodeKey` at `Surface.zig:3139`

Source:

```zig
) !?termio.Message.WriteReq {
    const write_req: termio.Message.WriteReq = req: {
```

### Preconditions

Before this function begins:

- `Surface.keyCallback` has decided to try terminal-input encoding
- the later write path does not exist yet for this keypress

### Validate the preconditions

Run:

```lldb
thread backtrace
source list -l 3139
frame variable --show-types event
```

### Postcondition

If encoding succeeds for a plain `l`, the caller later receives a `write_req`
and forwards it at `Surface.zig:2765`.

### Validate the postcondition

Use:

```lldb
continue
```

Then confirm the next relevant stop is `Surface.zig:2765`.

## Stop 7: write forwarding at `Surface.zig:2765`

Source:

```zig
self.queueIo(switch (write_req) { ... }, .unlocked);
```

### Preconditions

Before this line executes:

- encoding has already succeeded
- `write_req` exists
- `self.child_exited == false`, otherwise the earlier branch would have closed
  the surface and returned

### Validate the preconditions

Run:

```lldb
source list -l 2765
frame variable --show-types write_req
frame variable --show-types self.child_exited
```

### Postcondition

After this line, the typed input is being forwarded to the IO side as a
`termio.Message`.

### Validate the postcondition

Use:

```lldb
continue
```

Then confirm the next relevant stop is on the IO-thread dispatch side at
`termio/Thread.zig:336`.

## Stop 8: IO-thread dispatch at `termio/Thread.zig:336`

Source:

```zig
.write_small => |v| try io.queueWrite(...)
```

### Preconditions

Before this case runs:

- the key-generated write has already crossed from the app thread into the IO
  thread
- `drainMailbox` has already popped one message
- for a simple single-byte key like `l`, the expected active message arm is
  `write_small`

### Validate the preconditions

Run:

```lldb
thread backtrace
source list -l 336
frame variable --show-types message
```

If the message is `write_small`, that is the clean expected case for this
session.

### Postcondition

After this case executes, the exec backend write path will run.

### Validate the postcondition

Use:

```lldb
continue
```

Then confirm the next relevant stop is `Exec.zig:408`.

## Stop 9: `Exec.queueWrite` entry at `Exec.zig:408`

Source:

```zig
) !void {
    _ = self;
    const exec = &td.backend.exec;
```

### Preconditions

Before this function executes:

- the IO thread has already decided to dispatch a write message
- `Exec` is the concrete backend selected for this surface
- no more backend *selection* remains after this frame; from here on, the path
  is concrete exec-write machinery

### Validate the preconditions

Run:

```lldb
thread backtrace
source list -l 408
next
next
frame variable --show-types data
frame variable --show-types linefeed
```

Why `next` twice:

- the first stop is at function entry
- LLDB may show noisy or unavailable argument values there
- after a step or two, `data` should stabilize to the encoded bytes for your
  probe key, such as a single-byte `l`

### Postcondition

If `exec.exited` is false, `Exec.queueWrite` will build a concrete `slice` and
reach the PTY-stream handoff at line 457.

### Validate the postcondition

Use:

```lldb
continue
```

Then confirm the next relevant stop is `Exec.zig:457`.

## Stop 10: PTY-stream handoff at `Exec.zig:457`

Source:

```zig
exec.write_stream.queueWrite(
    td.loop,
    &exec.write_queue,
```

### Preconditions

Before this line executes:

- the IO thread is still in the concrete exec backend path
- a concrete `slice` now exists
- Ghostty is about to hand that slice to the PTY-side async stream writer

### Validate the preconditions

Run:

```lldb
thread backtrace
source list -l 457
frame variable --show-types slice
frame variable --show-types linefeed
```

For a simple `l`, `slice` should contain one byte: `l`.

### Postcondition

After this line executes:

- the write has been queued on `exec.write_stream`
- the next lower-level step is async stream machinery, not another Ghostty
  backend-selection layer
- completion later returns through `ttyWrite`

### Validate the postcondition

For this session, source position and backtrace are enough. You do not need to
step into xev internals unless you explicitly want lower-level event-loop
details.

## Assertions you should avoid

Do **not** claim the following from this session:

- "The key is visible because Ghostty locally echoes it."
- "Bindings are impossible here."  
  Better: "In this run, the probe key was not consumed as a binding."
- "Every key always becomes `write_small`."  
  Better: "A simple ASCII key like `l` commonly does in this session."
- "The export boundary and shared dispatch helper are the same thing."
- "The first function-entry dump always shows trustworthy argument values."

## Condensed Hoare story

```text
{ typed key entered a usable surface window }
ghostty_surface_key
{ control crosses the first Zig surface-key boundary }

{ target is a surface key path }
embedded.App.keyEvent
{ Ghostty will dispatch to Surface.keyCallback }

{ no binding decision yet; no PTY write yet }
Surface.keyCallback entry
{ Ghostty will check bindings first }

{ key not yet encoded }
maybeHandleBinding site
{ if not consumed, Ghostty can continue toward encoding }

{ not consumed as binding }
encodeKey / write_req path
{ a concrete write request exists }

{ write_req exists; child not exited }
Surface.zig:2765
{ a termio message is forwarded to the IO side }

{ IO thread popped a write message }
termio/Thread.zig:336
{ the backend write path will run }

{ backend write path entered }
Exec.queueWrite
{ a concrete byte slice is built }

{ concrete slice exists }
Exec.zig:457
{ the write is queued on the PTY-side stream }
```

That is the architectural lesson `s2` is meant to teach.
