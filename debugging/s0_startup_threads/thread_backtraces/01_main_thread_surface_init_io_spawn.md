# Backtrace 01: Main Thread Stopped at `Surface.init` IO-Thread Spawn

## Raw LLDB Output

```text
thread backtrace
* thread #1, queue = 'com.apple.main-thread', stop reason = breakpoint 6.1
  * frame #0: 0x00000001062d2868 ghostty.debug.dylib`Surface.init(self=0x000000010cf48000, alloc=mem.Allocator @ 0x0000000104248000, config_original=0x000000016fdf7020, app=0x0000000104248000, rt_app=0x00000001041c2000, rt_surface=0x000000010cf48000) at Surface.zig:709:9
    frame #1: 0x00000001062d3c40 ghostty.debug.dylib`apprt.embedded.Surface.init(self=0x000000010cf48000, app=0x00000001041c2000, opts=apprt.embedded.Surface.Options @ 0x000000016fdf9f20) at embedded.zig:578:35
    frame #2: 0x00000001062d4384 ghostty.debug.dylib`apprt.embedded.App.newSurface(self=0x00000001041c2000, opts=apprt.embedded.Surface.Options @ 0x000000016fdf9f20) at embedded.zig:247:25
    frame #3: 0x00000001062d4630 ghostty.debug.dylib`apprt.embedded.CAPI.surface_new_(app=0x00000001041c2000, opts=0x000000016fdf9f20) at embedded.zig:1555:34
    frame #4: 0x00000001062d4728 ghostty.debug.dylib`apprt.embedded.CAPI.ghostty_surface_new(app=0x00000001041c2000, opts=0x000000016fdf9f20) at embedded.zig:1545:28
    frame #5: 0x00000001049ea008 ghostty.debug.dylib`closure #6 in Ghostty.SurfaceView.init(surface_cfg_c=GhosttyKit.ghostty_surface_config_s @ 0x000000016fdf9f20, app=0x1041c2000) at SurfaceView_AppKit.swift:395:17
    frame #7: 0x00000001049a1694 ghostty.debug.dylib`closure #1 in closure #1 in closure #1 in closure #1 in closure #1 in closure #1 in Ghostty.SurfaceConfiguration.withCValue<UnsafeMutableRawPointer?>(buffer=0 values (0x1fa6f5e00), config=GhosttyKit.ghostty_surface_config_s @ 0x000000016fdf9f20, body=0x00000001049ea020 ghostty.debug.dylib`partial apply forwarder for closure #6 (inout __C.ghostty_surface_config_s) -> Swift.Optional<Swift.UnsafeMutableRawPointer> in Ghostty.Ghostty.SurfaceView.init(_: Swift.UnsafeMutableRawPointer, baseConfig: Swift.Optional<Ghostty.Ghostty.SurfaceConfiguration>, uuid: Swift.Optional<Foundation.UUID>) -> Ghostty.Ghostty.SurfaceView at <compiler-generated>) at SurfaceView.swift:753:48
    frame #10: 0x00000001049a1418 ghostty.debug.dylib`closure #1 in closure #1 in closure #1 in closure #1 in closure #1 in Ghostty.SurfaceConfiguration.withCValue<UnsafeMutableRawPointer?>(valueCStrings=0 values, keyCStrings=0 values, config=GhosttyKit.ghostty_surface_config_s @ 0x000000016fdf9f20, body=0x00000001049ea020 ghostty.debug.dylib`partial apply forwarder for closure #6 (inout __C.ghostty_surface_config_s) -> Swift.Optional<Swift.UnsafeMutableRawPointer> in Ghostty.Ghostty.SurfaceView.init(_: Swift.UnsafeMutableRawPointer, baseConfig: Swift.Optional<Ghostty.Ghostty.SurfaceConfiguration>, uuid: Swift.Optional<Foundation.UUID>) -> Ghostty.Ghostty.SurfaceView at <compiler-generated>) at SurfaceView.swift:750:52
    frame #12: 0x0000000104a93360 ghostty.debug.dylib`Array<τ_0_0>.withCStrings<A>(body=0x00000001049c8a30 ghostty.debug.dylib`partial apply forwarder for closure #1 (Swift.Array<Swift.Optional<Swift.UnsafePointer<Swift.Int8>>>) throws -> A in closure #1 (Swift.Array<Swift.Optional<Swift.UnsafePointer<Swift.Int8>>>) throws -> A in closure #1 (Swift.Optional<Swift.UnsafePointer<Swift.Int8>>) throws -> A in closure #1 (Swift.Optional<Swift.UnsafePointer<Swift.Int8>>) throws -> A in closure #1 (Swift.Optional<Swift.UnsafePointer<Swift.Int8>>) throws -> A in Ghostty.Ghostty.SurfaceConfiguration.withCValue<A>(view: Ghostty.Ghostty.SurfaceView, _: (inout __C.ghostty_surface_config_s) throws -> A) throws -> A at <compiler-generated>) at Array+Extension.swift:30:24
    frame #13: 0x00000001049a0fd0 ghostty.debug.dylib`closure #1 in closure #1 in closure #1 in closure #1 in Ghostty.SurfaceConfiguration.withCValue<UnsafeMutableRawPointer?>(keyCStrings=0 values, values=0 values, config=GhosttyKit.ghostty_surface_config_s @ 0x000000016fdf9f20, body=0x00000001049ea020 ghostty.debug.dylib`partial apply forwarder for closure #6 (inout __C.ghostty_surface_config_s) -> Swift.Optional<Swift.UnsafeMutableRawPointer> in Ghostty.Ghostty.SurfaceView.init(_: Swift.UnsafeMutableRawPointer, baseConfig: Swift.Optional<Ghostty.Ghostty.SurfaceConfiguration>, uuid: Swift.Optional<Foundation.UUID>) -> Ghostty.Ghostty.SurfaceView at <compiler-generated>) at SurfaceView.swift:739:47
    frame #15: 0x0000000104a93360 ghostty.debug.dylib`Array<τ_0_0>.withCStrings<A>(body=0x00000001049c89ec ghostty.debug.dylib`partial apply forwarder for closure #1 (Swift.Array<Swift.Optional<Swift.UnsafePointer<Swift.Int8>>>) throws -> A in closure #1 (Swift.Optional<Swift.UnsafePointer<Swift.Int8>>) throws -> A in closure #1 (Swift.Optional<Swift.UnsafePointer<Swift.Int8>>) throws -> A in closure #1 (Swift.Optional<Swift.UnsafePointer<Swift.Int8>>) throws -> A in Ghostty.Ghostty.SurfaceConfiguration.withCValue<A>(view: Ghostty.Ghostty.SurfaceView, _: (inout __C.ghostty_surface_config_s) throws -> A) throws -> A at <compiler-generated>) at Array+Extension.swift:30:24
    frame #16: 0x00000001049a0e1c ghostty.debug.dylib`closure #1 in closure #1 in closure #1 in Ghostty.SurfaceConfiguration.withCValue<UnsafeMutableRawPointer?>(cInput=nil, config=GhosttyKit.ghostty_surface_config_s @ 0x000000016fdf9f20, body=0x00000001049ea020 ghostty.debug.dylib`partial apply forwarder for closure #6 (inout __C.ghostty_surface_config_s) -> Swift.Optional<Swift.UnsafeMutableRawPointer> in Ghostty.Ghostty.SurfaceView.init(_: Swift.UnsafeMutableRawPointer, baseConfig: Swift.Optional<Ghostty.Ghostty.SurfaceConfiguration>, uuid: Swift.Optional<Foundation.UUID>) -> Ghostty.Ghostty.SurfaceView at <compiler-generated>) at SurfaceView.swift:738:41
    frame #18: 0x0000000104aa0b04 ghostty.debug.dylib`Optional<τ_0_0>.withCString<A>(body=0x00000001049c88c4 ghostty.debug.dylib`partial apply forwarder for closure #1 (Swift.Optional<Swift.UnsafePointer<Swift.Int8>>) throws -> A in closure #1 (Swift.Optional<Swift.UnsafePointer<Swift.Int8>>) throws -> A in closure #1 (Swift.Optional<Swift.UnsafePointer<Swift.Int8>>) throws -> A in Ghostty.Ghostty.SurfaceConfiguration.withCValue<A>(view: Ghostty.Ghostty.SurfaceView, _: (inout __C.ghostty_surface_config_s) throws -> A) throws -> A at <compiler-generated>) at Optional+Extension.swift:7:24
    frame #19: 0x00000001049a0b80 ghostty.debug.dylib`closure #1 in closure #1 in Ghostty.SurfaceConfiguration.withCValue<UnsafeMutableRawPointer?>(cCommand=nil, config=GhosttyKit.ghostty_surface_config_s @ 0x000000016fdf9f20, body=0x00000001049ea020 ghostty.debug.dylib`partial apply forwarder for closure #6 (inout __C.ghostty_surface_config_s) -> Swift.Optional<Swift.UnsafeMutableRawPointer> in Ghostty.Ghostty.SurfaceView.init(_: Swift.UnsafeMutableRawPointer, baseConfig: Swift.Optional<Ghostty.Ghostty.SurfaceConfiguration>, uuid: Swift.Optional<Foundation.UUID>) -> Ghostty.Ghostty.SurfaceView at <compiler-generated>) at SurfaceView.swift:730:45
    frame #21: 0x0000000104aa0b04 ghostty.debug.dylib`Optional<τ_0_0>.withCString<A>(body=0x00000001049c8884 ghostty.debug.dylib`partial apply forwarder for closure #1 (Swift.Optional<Swift.UnsafePointer<Swift.Int8>>) throws -> A in closure #1 (Swift.Optional<Swift.UnsafePointer<Swift.Int8>>) throws -> A in Ghostty.Ghostty.SurfaceConfiguration.withCValue<A>(view: Ghostty.Ghostty.SurfaceView, _: (inout __C.ghostty_surface_config_s) throws -> A) throws -> A at <compiler-generated>) at Optional+Extension.swift:7:24
    frame #22: 0x00000001049a0a28 ghostty.debug.dylib`closure #1 in Ghostty.SurfaceConfiguration.withCValue<UnsafeMutableRawPointer?>(cWorkingDir=nil, config=GhosttyKit.ghostty_surface_config_s @ 0x000000016fdf9f20, body=0x00000001049ea020 ghostty.debug.dylib`partial apply forwarder for closure #6 (inout __C.ghostty_surface_config_s) -> Swift.Optional<Swift.UnsafeMutableRawPointer> in Ghostty.Ghostty.SurfaceView.init(_: Swift.UnsafeMutableRawPointer, baseConfig: Swift.Optional<Ghostty.Ghostty.SurfaceConfiguration>, uuid: Swift.Optional<Foundation.UUID>) -> Ghostty.Ghostty.SurfaceView at <compiler-generated>) at SurfaceView.swift:727:36
    frame #24: 0x0000000104aa0b04 ghostty.debug.dylib`Optional<τ_0_0>.withCString<A>(body=0x00000001049b34d8 ghostty.debug.dylib`partial apply forwarder for closure #1 (Swift.Optional<Swift.UnsafePointer<Swift.Int8>>) throws -> A in Ghostty.Ghostty.SurfaceConfiguration.withCValue<A>(view: Ghostty.Ghostty.SurfaceView, _: (inout __C.ghostty_surface_config_s) throws -> A) throws -> A at <compiler-generated>) at Optional+Extension.swift:7:24
    frame #25: 0x00000001049a0898 ghostty.debug.dylib`Ghostty.SurfaceConfiguration.withCValue<UnsafeMutableRawPointer?>(view=0x0000000a3b688500, body=0x00000001049ea020 ghostty.debug.dylib`partial apply forwarder for closure #6 (inout __C.ghostty_surface_config_s) -> Swift.Optional<Swift.UnsafeMutableRawPointer> in Ghostty.Ghostty.SurfaceView.init(_: Swift.UnsafeMutableRawPointer, baseConfig: Swift.Optional<Ghostty.Ghostty.SurfaceConfiguration>, uuid: Swift.Optional<Foundation.UUID>) -> Ghostty.Ghostty.SurfaceView at <compiler-generated>) at SurfaceView.swift:724:41
    frame #26: 0x00000001049e9024 ghostty.debug.dylib`Ghostty.SurfaceView.init(app=0x1041c2000, baseConfig=nil, uuid=nil) at SurfaceView_AppKit.swift:394:39
    frame #27: 0x00000001049e7304 ghostty.debug.dylib`Ghostty.SurfaceView.__allocating_init() at SurfaceView_AppKit.swift:0
    frame #28: 0x00000001048c1020 ghostty.debug.dylib`BaseTerminalController.init(ghostty=0x0000000a3a870540, base=nil, tree=nil) at BaseTerminalController.swift:142:33
    frame #29: 0x00000001048e072c ghostty.debug.dylib`TerminalController.init(ghostty=0x0000000a3a870540, base=nil, tree=nil, parent=nil) at TerminalController.swift:74:15
    frame #30: 0x00000001048e0360 ghostty.debug.dylib`TerminalController.__allocating_init() at TerminalController.swift:0
    frame #31: 0x00000001048e2b68 ghostty.debug.dylib`static TerminalController.newWindow(ghostty=0x0000000a3a870540, baseConfig=nil, explicitParent=nil) at TerminalController.swift:228:36
    frame #32: 0x0000000104746d8c ghostty.debug.dylib`AppDelegate.applicationDidBecomeActive(notification=Foundation.Notification @ 0x000000016fdfc5c0) at AppDelegate.swift:361:40
    frame #33: 0x000000010474422c ghostty.debug.dylib`AppDelegate.applicationDidFinishLaunching(notification=Foundation.Notification @ 0x000000016fdfce50) at AppDelegate.swift:330:13
    frame #35: 0x000000018d765494 CoreFoundation`__CFNOTIFICATIONCENTER_IS_CALLING_OUT_TO_AN_OBSERVER__ + 148
    frame #36: 0x000000018d7c9f54 CoreFoundation`___CFXRegistrationPost_block_invoke + 92
    frame #37: 0x000000018d7c9e98 CoreFoundation`_CFXRegistrationPost + 436
    frame #38: 0x000000018d743f94 CoreFoundation`_CFXNotificationPost + 740
    frame #39: 0x000000018f96e6d0 Foundation`-[NSNotificationCenter postNotificationName:object:userInfo:] + 88
    frame #40: 0x0000000191b8cea0 AppKit`-[NSApplication _postDidFinishNotification] + 308
    frame #41: 0x0000000191b8cc38 AppKit`-[NSApplication _sendFinishLaunchingNotification] + 172
    frame #42: 0x00000001921003a0 AppKit`-[NSApplication(NSAppleEventHandling) _handleAEOpenEvent:] + 488
    frame #43: 0x0000000192103ba4 AppKit`-[NSApplication(NSAppleEventHandling) _handleCoreEvent:withReplyEvent:] + 488
    frame #44: 0x000000018f8bba34 Foundation`-[NSAppleEventManager dispatchRawAppleEvent:withRawReply:handlerRefCon:] + 316
    frame #45: 0x000000018ef7a688 Foundation`_NSAppleEventManagerGenericHandler + 80
    frame #46: 0x00000001959d40f4 AE`___lldb_unnamed_symbol876 + 1600
    frame #47: 0x00000001959d3a34 AE`___lldb_unnamed_symbol875 + 44
    frame #48: 0x00000001959cd0e8 AE`aeProcessAppleEvent + 484
    frame #49: 0x000000019a22d7c8 HIToolbox`AEProcessAppleEvent + 68
    frame #50: 0x0000000191b8810c AppKit`_DPSNextEvent + 1296
    frame #51: 0x000000019264ef08 AppKit`-[NSApplication(NSEventRouting) _nextEventMatchingEventMask:untilDate:inMode:dequeue:] + 688
    frame #52: 0x000000019264ec14 AppKit`-[NSApplication(NSEventRouting) nextEventMatchingMask:untilDate:inMode:dequeue:] + 72
    frame #53: 0x0000000191b80780 AppKit`-[NSApplication run] + 368
    frame #54: 0x0000000191b6c6dc AppKit`NSApplicationMain + 880
    frame #55: 0x00000001047629e4 ghostty.debug.dylib`main at main.swift:33:5
    frame #56: 0x000000018d305d54 dyld`start + 7184
```

## What thread am I on?

- `thread #1, queue = 'com.apple.main-thread'`

This proves the stop happened on the macOS main thread, not on the renderer
thread, IO thread, or PTY read thread.

## Where am I stopped?

- `frame #0 ... Surface.init ... at Surface.zig:709:9`

This means execution is currently stopped inside `Surface.init`, at the IO
thread spawn area of the first surface setup.

## Immediate call chain

The useful top part of the stack is:

1. `Surface.init` at `Surface.zig:709`
2. `apprt.embedded.Surface.init`
3. `apprt.embedded.App.newSurface`
4. `surface_new_`
5. `ghostty_surface_new`
6. Swift `Ghostty.SurfaceView.init`

In plain English:

- Swift app code is creating a new Ghostty surface
- the call crosses into the embedded C/Zig API through `ghostty_surface_new`
- that flows into `App.newSurface`
- that then reaches `Surface.init`
- the stop happens while `Surface.init` is performing ordinary startup work

## What this proves

This backtrace supports several important S0 claims:

1. **Ordinary surface creation starts from the app/runtime side.**
   The call chain originates in Swift UI/runtime code and then enters the Zig
   runtime surface-creation path.

2. **The stop is on the app thread.**
   Surface creation is happening on the macOS main thread.

3. **We are still inside `Surface.init`, not inside any child thread.**
   The renderer and IO threads are being spawned from this main-thread setup
   path.

4. **This is normal Ghostty startup/window creation, not tmux-specific logic.**
   The deeper frames show `SurfaceView`, `TerminalController`, `AppDelegate`,
   and AppKit launch machinery.

## Short interpretation

The simplest summary of this backtrace is:

> I am on the macOS main thread, stopped inside `Surface.init` while ordinary
> Ghostty surface creation is still in progress. Swift app/runtime code called
> into `ghostty_surface_new`, which eventually reached this point.

---

## Additional Raw LLDB Output: Renderer Thread Initial Wakeup

```text
Process 70285 stopped
* thread #11, name = 'renderer', stop reason = breakpoint 7.1
    frame #0: 0x00000001062fce38 ghostty.debug.dylib`renderer.Thread.threadMain_(self=0x000000010cf56740) at Thread.zig:244:13
   241      self.draw_now.wait(&self.loop, &self.draw_now_c, Thread, self, drawNowCallback);
   242
   243      // Send an initial wakeup message so that we render right away.
-> 244      try self.wakeup.notify();
                    ^
   245
   246      // Start blinking the cursor.
   247      self.cursor_h.run(
Target 0: (ghostty) stopped.
thread backtrace
* thread #11, name = 'renderer', stop reason = breakpoint 7.1
  * frame #0: 0x00000001062fce38 ghostty.debug.dylib`renderer.Thread.threadMain_(self=0x000000010cf56740) at Thread.zig:244:13
    frame #1: 0x00000001062f1fe0 ghostty.debug.dylib`renderer.Thread.threadMain(self=0x000000010cf56740) at Thread.zig:201:21
    frame #2: 0x00000001062e82b4 ghostty.debug.dylib`Thread.callFn__anon_527520(args=<unavailable>) at Thread.zig:509:13
    frame #3: 0x00000001062ddc90 ghostty.debug.dylib`Thread.PosixThreadImpl.spawn__anon_526032.Instance.entryFn(raw_arg=0x0000000a3a808900) at Thread.zig:781:30
    frame #4: 0x000000018d6cfc08 libsystem_pthread.dylib`_pthread_start + 136
```

## What thread am I on now?

- `thread #11, name = 'renderer'`

This proves we are no longer on the macOS main thread. We are now running
inside the dedicated renderer thread created for the surface.

## Where am I stopped now?

- `frame #0 ... renderer.Thread.threadMain_ ... at Thread.zig:244:13`

The stop is at the renderer thread's startup logic, exactly where it sends its
initial wakeup:

- `try self.wakeup.notify();`

## Immediate call chain now

The useful top part of the stack is:

1. `renderer.Thread.threadMain_`
2. `renderer.Thread.threadMain`
3. `Thread.callFn...`
4. `Thread.PosixThreadImpl.spawn...entryFn`
5. `_pthread_start`

In plain English:

- the renderer thread has already been spawned
- it has started executing its own thread entrypoint
- it is still in renderer-thread startup code
- this is no longer app-thread setup code

## What this additional backtrace proves

This backtrace supports another key S0 claim:

1. **The renderer really is a separate OS thread.**
   The thread name is `renderer`, and the stack is a thread entry stack, not a
   Swift app-thread stack.

2. **The renderer performs its own startup sequence after spawn.**
   It is setting up wait handlers and then sending an initial wakeup so the
   first frame can be rendered immediately.

3. **The first renderer wakeup comes from inside the renderer thread startup.**
   The line at `Thread.zig:244` is direct evidence for the README claim that
   the renderer gives itself an initial wakeup.

4. **This stop is downstream of the main-thread spawn point.**
   The earlier main-thread backtrace showed where renderer-thread creation was
   requested. This backtrace shows the newly created thread actually running.

## Short interpretation for the renderer backtrace

The simplest summary of this second backtrace is:

> I am now on the dedicated renderer thread, stopped in its startup function at
> the line where it sends itself the initial wakeup so the first render can
> happen right away.

---

## Additional Raw LLDB Output: IO Thread Inside `Exec.threadEnter`

```text
12, name = 'io', stop reason = step over
    frame #0: 0x00000001062ffce8 ghostty.debug.dylib`termio.Exec.threadEnter(self=0x000000010cf57a20, alloc=<unavailable>, io=0x000000010cf57a10, td=0x0000000173fcb9c8) at Exec.zig:146:7
   143      read_thread.setName("io-reader") catch {};
   144
   145      // Setup our threadata backend state to be our own
-> 146      td.backend = .{ .exec = .{
              ^
   147          .start = process_start,
   148          .write_stream = stream,
   149          .process = process,
Target 0: (ghostty) stopped.
thread backtrace
* thread #12, name = 'io', stop reason = step over
  * frame #0: 0x00000001062ffce8 ghostty.debug.dylib`termio.Exec.threadEnter(self=0x000000010cf57a20, alloc=<unavailable>, io=0x000000010cf57a10, td=0x0000000173fcb9c8) at Exec.zig:146:7
    frame #1: 0x00000001063000e4 ghostty.debug.dylib`termio.backend.Backend.threadEnter(self=0x000000010cf57a20, alloc=<unavailable>, io=0x000000010cf57a10, td=0x0000000173fcb9c8) at backend.zig:45:50
    frame #2: 0x0000000106301e5c ghostty.debug.dylib`termio.Termio.threadEnter(self=0x000000010cf57a10, thread=0x000000010cf57120, data=0x0000000173fcb9c8) at Termio.zig:364:33
    frame #3: 0x00000001063029cc ghostty.debug.dylib`termio.Thread.threadMain_(self=0x000000010cf57120, io=0x000000010cf57a10) at Thread.zig:267:23
    frame #4: 0x00000001062f209c ghostty.debug.dylib`termio.Thread.threadMain(self=0x000000010cf57120, io=0x000000010cf57a10) at Thread.zig:137:21
    frame #5: 0x00000001062e82ec ghostty.debug.dylib`Thread.callFn__anon_527527(args=<unavailable>) at Thread.zig:509:13
    frame #6: 0x00000001062de2ac ghostty.debug.dylib`Thread.PosixThreadImpl.spawn__anon_526046.Instance.entryFn(raw_arg=0x0000000a3a808970) at Thread.zig:781:30
    frame #7: 0x000000018d6cfc08 libsystem_pthread.dylib`_pthread_start + 136
```

## What thread am I on now?

- `thread #12, name = 'io'`

This proves we are on the dedicated IO thread for the surface, not on the app
thread and not on the renderer thread.

## Where am I stopped now?

- `frame #0 ... termio.Exec.threadEnter ... at Exec.zig:146:7`

The stop is inside the exec backend's `threadEnter` path, immediately after the
read thread was spawned and named `io-reader`, and right as backend-specific
thread data is being stored into `td.backend`.

The source lines matter:

- line 143 shows the `io-reader` thread has just been named
- line 146 stores the exec backend state into `td.backend`

So this stop happens after the IO thread has entered backend startup, not while
the main thread is still building the surface.

## Immediate call chain now

The useful top part of the stack is:

1. `termio.Exec.threadEnter`
2. `termio.backend.Backend.threadEnter`
3. `termio.Termio.threadEnter`
4. `termio.Thread.threadMain_`
5. `termio.Thread.threadMain`

In plain English:

- the IO thread has already started
- the IO thread called into `Termio.threadEnter`
- `Termio.threadEnter` dispatched through the backend union
- because this surface uses the exec backend, control reached
  `Exec.threadEnter`
- `Exec.threadEnter` is now doing exec-specific startup work

## What this additional backtrace proves

This backtrace supports another key S0 claim:

1. **The IO thread is a separate thread with its own startup path.**
   The thread name is `io`, and the stack is an IO-thread entry stack.

2. **Exec-specific startup happens from the IO thread, not from the app thread.**
   The call chain is `termio.Thread.threadMain_ -> Termio.threadEnter ->
   Backend.threadEnter -> Exec.threadEnter`.

3. **The extra PTY read thread is introduced by the exec backend during backend
   startup.**
   The stop occurs just after `read_thread.setName("io-reader")`, which is
   direct evidence that exec-backed surfaces grow an additional thread from this
   backend path.

4. **This explains the difference between the IO thread and the PTY read thread.**
   The IO thread is the thread currently running this startup code. The
   `io-reader` thread is a second thread that the exec backend has just created
   for PTY reads.

## Short interpretation for the IO-thread backtrace

The simplest summary of this third backtrace is:

> I am on the dedicated IO thread, inside `Exec.threadEnter`. This shows that
> after the IO thread starts, Ghostty enters backend-specific startup, and the
> exec backend adds the extra `io-reader` PTY read thread from there.
