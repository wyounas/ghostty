# S5: Ordinary Child Surface Construction via Split

## Learning objectives

- Use a normal split as the existing analogue of "create another surface."
- See which work happens on the app/runtime side versus inside `Surface.init()`.
- Confirm what an ordinary child surface contains at birth.

## Success criteria

After this session, you should be able to answer:

1. What runtime entrypoint is used when Ghostty creates another surface?
2. Which major pieces are installed into the child surface before threads start?
3. Why is this a useful baseline for future tmux child-surface creation?
4. Where does the exec backend enter the picture for the child?

## Prerequisites

- Build the Debug macOS app first.
- Be able to trigger one ordinary Ghostty split from the app UI you already use.

## Expected duration

25-35 minutes.

## Run

1. Run:
   `sh debugging/s5_surface_construction_via_split/run.sh`
2. In LLDB, run:
   `run`
3. Use any normal Ghostty split action from the running app.
4. If you do not know the binding, use the app UI until `ghostty_surface_split`
   and then `ghostty_surface_new` stop.
5. Use these LLDB commands as you move through the stops:
   - `continue` or `c`
   - `next` or `n`
   - `step` or `s`
   - `finish`
   - `thread backtrace`
   - `thread list`
   - `frame variable`
   - `frame variable --show-types <name>`
   - `source list -l <line>`

## How to think about LLDB output in this session

This session is a child-surface version of `s0`. The key question is not
"what is every field in the new surface?" The key question is:

1. where does the split request enter runtime code?
2. where does runtime ask core Ghostty to build another surface?
3. what does the child surface contain before threads start?

If `self` prints as an address, that is fine. Use source position plus a few
small locals to prove what was wired before the child threads existed.

## What to watch for

- `ghostty_surface_split` is the exported request for making a split.
- `ghostty_surface_new` is the ordinary runtime entrypoint that creates the new
  surface object.
- `Surface.init()` installs app-mailbox routing, renderer state, termio, exec
  backend, and the child surface size before starting threads.

## How to validate what to watch for

### 1. Validate the split request entrypoint

At the stop in [embedded.zig](/Users/waqas/code/ghostty_forked/src/apprt/embedded.zig:1910):

- run `thread backtrace`
- run `source list -l 1910`
- run `frame variable --show-types ptr`

What this proves:

- ordinary child-surface creation begins as an app/runtime request
- this is runtime-side work, not renderer-side or backend-side work

### 2. Validate the runtime-to-core handoff

At the stop in [embedded.zig](/Users/waqas/code/ghostty_forked/src/apprt/embedded.zig:1541):

- run `thread backtrace`
- run `source list -l 1541`
- run `frame variable --show-types app`
- run `frame variable --show-types opts`

What this proves:

- the runtime uses `ghostty_surface_new` as the ordinary core entrypoint for
  creating the child surface

### 3. Validate what the child surface contains before threads start

At the stops in
[Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:549) and
[Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:654):

- run `source list -l 549`
- run `frame variable --show-types app_mailbox`
- run `frame variable --show-types render_thread`
- run `frame variable --show-types io_thread`
- continue
- run `source list -l 654`
- run `frame variable --show-types io_exec`
- run `frame variable --show-types io_mailbox`
- run `frame variable --show-types self.renderer_state`
- run `frame variable --show-types self.size`

What this proves:

- the child surface is a full normal surface, not just a bare view shell
- before its worker threads start, it already has:
  app-mailbox routing, shared renderer state, termio, exec backend, mailbox,
  and size-related state

### 4. Validate the child-thread start points

At the stops in
[Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:700) and
[Surface.zig](/Users/waqas/code/ghostty_forked/src/Surface.zig:708):

- run `thread list`
- run `thread backtrace`
- run `source list -l 700`
- use `next`
- continue
- run `source list -l 708`
- use `next`

What this proves:

- ordinary child surfaces use the same renderer-thread plus IO-thread model as
  the first surface

## Why this session matters for tmux work

Later, when you think about tmux child surfaces, this session gives you the
baseline answer to:

- what ordinary child creation already looks like
- which parts are runtime/app-thread work
- which parts are generic surface plumbing
- which parts are exec-specific and may later be replaced

## What this session does not cover

- tmux control mode
- tmux-backed backends
