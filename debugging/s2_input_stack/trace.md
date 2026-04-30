# S2 Trace: Typing `l` and Following the Input Stack

This trace explains the LLDB dump from `s2_input_stack`.

The short story is:

1. the Ghostty window was already usable
2. you typed `l`
3. the key crossed the macOS-to-Zig boundary
4. Ghostty routed it into `Surface.keyCallback`
5. Ghostty checked bindings, encoded the key, and built a write request
6. the app thread forwarded that request to the IO side
7. the IO thread drained a `write_small` mailbox message
8. `Exec.queueWrite` entered the concrete exec backend
9. `Exec` then handed a concrete byte slice to `exec.write_stream.queueWrite`

That is the input-stack story this session is meant to teach, and your dump is
consistent with that story.

## First point: the session setup worked

You saw:

```text
(lldb) breakpoint enable 2 3 4 5 6 7 8 9
8 breakpoints enabled.
Process ... stopped
* thread #1 ... breakpoint 1.1
  frame #0 ... ghostty_surface_key ... at embedded.zig:1765:12
```

This shows the staged setup did its job:

- the first stop happened only after you typed into a usable window
- the session did not get hijacked by startup traffic
- the later breakpoints were enabled only after the first real key-event stop

One historical note:

- this captured run predates the new `Exec.zig:457` breakpoint
- that is why the log shows `breakpoint enable 2 3 4 5 6 7 8 9` rather than
  `2 3 4 5 6 7 8 9 10`

That means the `s1` lesson about "let the app become usable first" has carried
forward correctly into `s2`.

## The main story

### 1. The first stop is the surface-key export boundary

First stop:

- thread: `#1`, `com.apple.main-thread`
- location: `ghostty_surface_key` at `embedded.zig:1765`

What that means:

- macOS/Swift has already decided this is a key event for a particular surface
- control has now crossed into Zig through the exported embedded API
- this is the first useful Zig boundary for this surface-key path

The call at this point is:

```zig
return surface.app.keyEvent(
    .{ .surface = surface },
    event.keyEvent(),
)
```

So Ghostty is not yet doing terminal-input encoding here. It is still just
crossing the language/runtime boundary and forwarding the event inward.

### 2. The shared dispatch helper runs next

Second stop:

- thread: `#1`, `com.apple.main-thread`
- location: `embedded.App.keyEvent` at `embedded.zig:183`

This is the shared dispatch helper after the export boundary.

The important control-flow fact is:

- the surface export boundary has already happened
- Ghostty is now converting/routing the platform event
- the next interesting destination is `Surface.keyCallback`

Your `frame variable --show-types event` showed `event = <variable not available>`.
That is not a bug in Ghostty. It is a normal function-entry LLDB limitation.
At this stop, the reliable facts are:

- the function name
- the file/line
- the backtrace

### 3. At `Surface.keyCallback` entry, inspect `event_orig`, not `event`

Third stop:

- thread: `#1`, `com.apple.main-thread`
- location: `Surface.keyCallback` at `Surface.zig:2607`

Your dump showed:

```text
frame variable --show-types event
...
utf8.ptr = 0x0
len = 6171904736
action = 0xa0b680c8
key = backquote
...
composing = true
```

That printout is not trustworthy. The reason is visible in the code:

```zig
pub fn keyCallback(self: *Surface, event_orig: input.KeyEvent) !InputEffect {
    var event = event_orig;
```

At the function-entry stop, `event_orig` is the meaningful parameter. The local
`event` has not yet become the stable thing you want to inspect. So the right
lesson is:

- this stop proves entry into the per-surface key handler
- do not build a mental model from the printed `event` value here
- inspect `event_orig`, or step forward to a later stop where `event` is known
  to be live and meaningful

### 4. The first clean semantic event print is at the binding check

Fourth stop:

- thread: `#1`, `com.apple.main-thread`
- location: `Surface.zig:2649`

Here the event looked sane:

```text
utf8 = "l"
action = press
key = key_l
mods = 0
composing = false
```

This is the first stop in your dump where the event is semantically stable and
easy to trust.

What it proves:

- Ghostty is handling a plain `l` keypress
- we are past the early function-entry/prologue noise
- the session is following the intended probe input

This is also the exact place where Ghostty asks:

```zig
if (try self.maybeHandleBinding(...)) |v| return v;
```

So at this point Ghostty has not yet encoded terminal bytes. It is first
checking whether the key is consumed as a binding.

### 5. The run proves `l` was not consumed by a binding

You later reached:

- `Surface.zig:2752`
- `Surface.encodeKey` at `Surface.zig:3139`

That matters because it proves something specific:

- in this run, `l` was not consumed by a keybinding
- Ghostty therefore continued into terminal-input encoding

That is exactly the distinction `s2` is designed to teach:

- binding handling comes first
- terminal-input encoding comes second, but only if binding handling does not
  consume the key

### 6. `Surface.zig:2765` is the app-thread handoff to the IO side

You then stopped twice on:

- `Surface.zig:2765`

This is the same LLDB behavior you already saw in `s1`: one source line can map
to more than one machine-code stop location.

The line is:

```zig
self.queueIo(switch (write_req) { ... }, .unlocked);
```

What it means:

- key encoding has already succeeded
- `write_req` exists
- the app thread is now turning that into a `termio.Message` and forwarding it
  to the IO side

### 7. The IO-thread mailbox consumer sees `write_small`

The next important stop was:

- thread: `#10`, name = `io`
- location: `termio.Thread.drainMailbox` at `Thread.zig:336`

Your `message` dump showed:

- `tag = write_small`
- `write_small.data` begins with `"l"`
- `write_small.len = 1`

Everything else in the union dump that looked like `0xaaaaaaaa...` is inactive
union-arm garbage for this stop and must be ignored.

So the clean reading is:

- the message is a `write_small`
- its active payload is a single byte: `l`
- the app-thread key handler has already finished its producer work
- the IO thread is now consuming that work

The backtrace is also important:

```text
wakeupCallback
-> drainMailbox
-> ... termio.Thread.threadMain_
```

That proves the write path is now running on the IO thread, not on the main
thread.

### 8. `Exec.queueWrite` is the concrete backend-entry stop

Then you reached:

- thread: `#10`, name = `io`
- location: `Exec.queueWrite` at `Exec.zig:408`

This is the first stop where the generic write path becomes the concrete exec
backend path.

Your first print at function entry looked wrong:

```text
data = (ptr = "/\b", len = 34032)
```

Then, after stepping, the values stabilized:

```text
data = "l..."
len = 1
linefeed = false
```

That is the expected pattern for a function-entry stop in LLDB:

- the first instant can show noisy argument state
- after one or two `next` steps, the arguments become trustworthy

So the right interpretation is:

- Ghostty entered the exec backend on the IO thread
- the encoded data is one byte, `l`
- linefeed conversion is not active for this write

The backtrace also answers your question about "why is there no backend after
this?" The backtrace shows:

```text
frame #0 Exec.queueWrite
frame #1 backend.Backend.queueWrite
frame #2 Termio.queueWrite
frame #3 Thread.drainMailbox
```

That means:

- `Backend.queueWrite` was just a dispatch wrapper
- by `frame #0`, the wrapper has already chosen `.exec`
- there is no further Ghostty backend-selection layer below `Exec`

### 9. `Exec.zig:457` is the PTY-stream handoff

The new breakpoint added for this session is the next crucial proof point:

```zig
exec.write_stream.queueWrite(
    td.loop,
    &exec.write_queue,
    req,
    .{ .slice = slice },
    termio.Exec.ThreadData,
    exec,
    ttyWrite,
);
```

This line is the answer to the question:

"Where does `Exec` actually hand bytes to the PTY-side write machinery?"

What it means:

- `Exec` has already built a concrete `slice`
- Ghostty is now queueing an async write on the PTY-side stream
- below this point, you are no longer looking at backend selection logic
- the later completion comes back through `ttyWrite`

This is the cleanest place in `s2` to see the phrase "PTY-side write" turn into
an actual code event.

## Are things working well?

Yes. The run looks correct.

The important good signs are:

- the staged setup worked and let you type into a usable window
- the path stayed on the main thread until the IO handoff
- the key was not consumed as a binding
- the mailbox delivered `write_small`
- the IO thread, not the app thread, entered `Exec.queueWrite`
- the eventual concrete write data stabilized to one byte: `l`

Nothing in this dump suggests a logic bug in the input path. The confusing
parts are debugger-view issues, not Ghostty path issues.

## The two most important LLDB lessons from this trace

### 1. Do not trust every function-entry variable dump

Three places in your dump showed this problem:

- `embedded.App.keyEvent`: `event` unavailable
- `Surface.keyCallback` entry: `event` looked nonsensical when you printed the
  wrong variable too early
- `Exec.queueWrite` entry: `data` briefly looked wrong until you stepped

The rule is:

- at function-entry stops, trust function name, file/line, and backtrace first
- trust locals only after you know they are live and stable

### 2. For Zig unions, trust the tag and the active arm only

At the IO-thread mailbox stop, the important facts were:

- `tag = write_small`
- payload begins with `"l"`
- `len = 1`

Everything else in the union dump is not part of the real story for that stop.

## The final plain-English story

You typed `l` into a usable Ghostty surface.

Ghostty received that key on the main thread, crossed into Zig through
`ghostty_surface_key`, routed it through `embedded.App.keyEvent`, and entered
`Surface.keyCallback`. There, Ghostty first checked bindings, then decided the
key should become terminal input, then encoded it.

The app thread forwarded the resulting write request to the IO side. The IO
thread woke up, drained a `write_small` mailbox message containing `l`, and
entered `Exec.queueWrite`. Finally, `Exec` prepared a concrete slice and handed
it to `exec.write_stream.queueWrite(...)`, which is the PTY-side async write
handoff.
