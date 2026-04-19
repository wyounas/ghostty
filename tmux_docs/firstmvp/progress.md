# First MVP Progress Handoff

Last updated: 2026-04-16

This document captures the current state of the `tmux -CC` first-MVP work so a
future Codex session can resume without re-discovering the same issues. The
source-of-truth task spec was moved to
`tmux_docs/first_mvp/firstmvp.md`.

## Scope We Implemented

The session implemented the first MVP described in
`tmux_docs/first_mvp/firstmvp.md`: when Ghostty is launched into tmux control
mode, the `.windows` action from the tmux viewer should create a second native
Ghostty surface/window for the first tmux pane, and that new surface should
bootstrap with a static snapshot of pane contents.

The implemented design stayed inside the intended MVP boundary:

- New backend kind for tmux-backed surfaces rather than trying to force the
  existing exec backend to do double duty.
- New app-thread action to request creation of a tmux snapshot window.
- New shared surface-config payload so the runtime boundary can carry tmux MVP
  metadata from Zig core into the macOS embedding layer.
- Snapshot bootstrap only.
- No live tmux output streaming into the child surface yet.
- No input forwarding from the child surface back into tmux yet.
- No resize sync back into tmux yet.
- No multi-pane layout rendering or window switching yet.

## Files Changed During This MVP

The implementation work touched at least these files:

- `include/ghostty.h`
- `macos/Sources/Ghostty/Ghostty.App.swift`
- `macos/Sources/Ghostty/Surface View/SurfaceView.swift`
- `src/App.zig`
- `src/Surface.zig`
- `src/apprt/action.zig`
- `src/apprt/embedded.zig`
- `src/apprt/surface.zig`
- `src/terminal/tmux/layout.zig`
- `src/terminal/tmux/viewer.zig`
- `src/termio.zig`
- `src/termio/Thread.zig`
- `src/termio/Tmux.zig`
- `src/termio/backend.zig`
- `src/termio/message.zig`
- `src/termio/stream_handler.zig`

Three files received extra temporary debug logging during validation:

- `src/terminal/tmux/viewer.zig`
- `src/termio/stream_handler.zig`
- `src/App.zig`

## What Landed Architecturally

The current code introduces a tmux-specific surface/backend path so Ghostty can
construct a surface without attaching it to a subprocess PTY.

Key pieces now in place:

- `backend.zig` has a tmux backend variant.
- `src/termio/Tmux.zig` exists as the tmux-side termio backend for this MVP.
- `src/App.zig` has a `new_tmux_window` app message and `newTmuxWindow(...)`
  helper to request a runtime-created window with explicit surface config.
- `src/apprt/action.zig` and `src/apprt/surface.zig` now carry a shared surface
  config payload across the runtime boundary, including:
  - backend type
  - source surface pointer
  - pane id
  - cols
  - rows
- `src/apprt/embedded.zig` understands that config, creates a tmux-backed
  surface, and notifies the source surface when the target surface is ready.
- `src/Surface.zig` has tmux MVP state for:
  - source/target relationship
  - target pane id
  - pending snapshot storage
  - flushing the stored snapshot into the target once the target surface exists
- `macos/Sources/Ghostty/Surface View/SurfaceView.swift` stores and forwards the
  tmux MVP config fields through the native surface creation path.
- `src/terminal/tmux/layout.zig` added helper support for locating the first pane
  leaf from the tmux layout tree.
- `src/terminal/tmux/viewer.zig` can emit the pane snapshot needed to bootstrap
  the second surface.

## Important Bug Fixed During Validation

One real correctness bug was found during manual validation and fixed.

Problem:

- `viewer.receivedListWindows()` emitted `.windows = windows.items`, where
  `windows` was a temporary local `ArrayList`.
- The local list storage was freed before the consumer used the action.
- Runtime logs then showed garbage like `0xAAAAAAAAAAAAAAAA` in window fields.

Fix:

- The code now calls `self.syncLayouts(windows.items)` first.
- The emitted action now uses `self.windows.items`, which is owned by the
  viewer and remains valid after the function returns.

Why it matters:

- Before this fix, the tmux window metadata crossing from viewer to stream
  handler was use-after-free garbage.
- After this fix, the `.windows` action is stable and contains the expected
  pane/window values.

## Test Status

The core build/test loop was green after the fix.

Commands that succeeded:

```bash
zig build
zig build test -Dtest-filter='initial flow'
zig build test -Dtest-filter=tmux
```

Notes:

- `zig build` passed end-to-end.
- The targeted tmux tests passed.
- The tmux-targeted test build still emitted the existing warning
  `[terminal_tmux] (warn): tmux control mode error=`, but the test invocation
  itself completed successfully.

One extra assertion was added to the tmux `initial flow` test so the emitted
`.windows` action is checked for stable, correct values:

- window id `0`
- width `83`
- height `44`
- first pane id `0`
- rows `20`
- cols `83`

## The Biggest Build/Runtime Struggle

The hardest issue in this session was not the tmux parser/viewer path. It was
getting the actual macOS app bundle to run the new Zig code rather than a stale
library.

### What went wrong

At first, runtime behavior looked inconsistent with the code:

- `zig build` and tests were passing.
- The logs from the app bundle did not reflect the latest tmux instrumentation.
- Manual runs appeared to still behave like the older build.

The root cause was that `zig build` alone was not enough for validating the
actual macOS app bundle. The app bundle linked against
`macos/GhosttyKit.xcframework`, and that packaged library was stale.

### What the repo expects

The repo instructions in `macos/AGENTS.md` are important:

- If code outside `macos/` changes, first run:

```bash
zig build -Demit-macos-app=false
```

- Then build the app with `macos/build.nu`, which is a wrapper around
  `xcodebuild`.

### What complicated that

- `nu` was not available in the environment, so the wrapper script could not be
  used directly.
- A direct `xcodebuild` invocation had to be used instead:

```bash
env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  xcodebuild \
  -project /Users/waqas/code/ghostty_forked/macos/Ghostty.xcodeproj \
  -scheme Ghostty \
  -configuration Debug \
  SYMROOT=/Users/waqas/code/ghostty_forked/macos/build \
  build
```

### The stale-library problem

The key discovery was that the app was still effectively using an old
`libghostty.a` inside:

- `macos/GhosttyKit.xcframework/macos-arm64_x86_64/libghostty.a`

The archive timestamp did not match the recent Zig builds.

Searching `.zig-cache` found fresh libraries that contained the new trace
strings. The important one was a universal macOS archive:

- `.zig-cache/o/7bb5e464808028d1d539cedbe0c60f19/libghostty.a`

That archive reported both `x86_64` and `arm64` with `lipo -info`, unlike one
of the other candidates that turned out to be simulator-targeted and was not
valid for the macOS app.

### The workaround that finally unblocked runtime validation

The stale xcframework archive was manually replaced with the fresh universal
archive from `.zig-cache`, then the app was rebuilt with `xcodebuild`.

That was the first point where the app logs started matching the latest code.

This should be treated as a build-system sharp edge for future sessions:

- Passing `zig build` does not prove the app bundle is using the latest core
  library.
- If runtime behavior disagrees with recent Zig changes, verify the archive
  actually linked into `Ghostty.app`.

## Manual Validation Attempts and Friction

We repeatedly tried to validate the success criteria with a real macOS run:

- build the app
- launch `Ghostty.app`
- run an `initial-command = direct:/opt/homebrew/bin/tmux ... -CC new-session`
- observe whether a second native Ghostty window appears
- confirm the second window is static/read-only and seeded from the snapshot

### Friction encountered

1. Accessibility permission issues

- AppleScript window introspection through `System Events` failed because macOS
  had not granted assistive access yet.
- Granting the permission restarted VS Code and killed the Codex session.

2. Screenshot permission issues

- A fallback validation path using `screencapture` also failed initially because
  screen capture permission was not yet available.

3. App bundle confusion

- There were multiple Ghostty outputs in the repo, and it was easy to launch the
  wrong artifact or validate against an older installation/build.
- Using the absolute path to `macos/build/Debug/Ghostty.app` mattered.

4. Runtime state confusion

- At one point the user reported seeing two Ghostty windows, then later reported
  that running it in one window caused it to close.
- That suggests the app was at least partially traversing the new path at some
  stage, but we do not have a clean, fully-instrumented confirmation of the
  entire success criterion yet.

## What Runtime Validation Confirmed

After the viewer use-after-free fix and after rebuilding the app with the fresh
library, runtime logs finally became trustworthy.

The final observed state was:

- tmux control mode activates
- the viewer emits a correct `.windows` action
- the stream handler receives that action
- the stream handler requests creation of a tmux window
- pane snapshot capture happens

Representative runtime logs confirmed:

- `tmux mvp windows action len=1 first_id=0 first_width=80 first_height=24`
- `tmux mvp requesting pane_id=0 cols=80 rows=24`

This means the parser/viewer/stream-handler side is now behaving correctly
enough to request the MVP window.

## The Current Blocker

Despite the correct `.windows` action and the snapshot request, the second
window still was not conclusively created in the final clean validation run.

The most important missing log was from `src/App.zig`:

- `new tmux window source={} pane_id={} cols={} rows={}`

That log should appear inside `App.newTmuxWindow(...)` when the app-thread
mailbox drains the `new_tmux_window` message.

What this means:

- `stream_handler.zig` is reaching `self.appMessageWriter(.new_tmux_window = ...)`
- but the message is either:
  - not being delivered to the app mailbox,
  - not waking the macOS app loop,
  - not being drained by `ghostty_app_tick`,
  - or being lost before `App.drainMailbox()` reaches the `.new_tmux_window`
    arm.

So the remaining bug is likely in the app-thread handoff, not in the tmux
viewer/parser logic.

## Code Paths Already Narrowed Down

The relevant chain is:

1. `src/termio/stream_handler.zig`
   - receives `.windows`
   - computes first pane
   - sets source surface tmux MVP bookkeeping
   - pushes `.new_tmux_window` via `self.appMessageWriter(...)`

2. `src/App.zig`
   - `Mailbox.push(...)` should enqueue the message and call `self.rt_app.wakeup()`
   - `tick(...)` should call `drainMailbox(...)`
   - `drainMailbox(...)` should dispatch `.new_tmux_window`
   - `newTmuxWindow(...)` should call runtime action
     `.new_window_with_surface_config`

3. `macos/Sources/Ghostty/Ghostty.App.swift`
   - runtime `wakeup_cb` calls `App.wakeup(...)`
   - macOS `wakeup(...)` should schedule `state.appTick()` on the main queue
   - `appTick()` should call `ghostty_app_tick(app)`
   - action dispatch should handle
     `GHOSTTY_ACTION_NEW_WINDOW_WITH_SURFACE_CONFIG`

4. `src/apprt/embedded.zig`
   - `new_window_with_surface_config` path should create the tmux-backed surface
   - if successful, it should notify the source surface with
     `.tmux_mvp_target_ready`

## Temporary Diagnostics Added

To isolate the blocker, temporary logging was added in these places:

### `src/termio/stream_handler.zig`

- `tmux mvp windows action len={} first_id={} first_width={} first_height={}`
- `tmux mvp windows action had no first pane`
- `tmux mvp requesting pane_id={} cols={} rows={}`

These logs proved the tmux viewer path is now producing sane data.

### `src/App.zig`

- `new tmux window source={} pane_id={} cols={} rows={}`

This log did not appear in the final validation run. That is the strongest clue
that the failure is before or during the app-thread mailbox drain.

## What I Was Going To Check Next

The next debugging pass should focus on proving whether the macOS app wakeup and
tick path is actually firing after `new_tmux_window` is pushed.

Recommended next steps:

1. Add temporary logging in `src/App.zig` mailbox delivery

- Log inside `App.Mailbox.push(...)` right after `self.mailbox.push(...)`
- Log at the top of `drainMailbox(...)` and log every message tag before the
  `switch`

Why:

- This will show whether the app mailbox received the message at all.

2. Add temporary logging in `macos/Sources/Ghostty/Ghostty.App.swift`

- log inside `App.wakeup(...)`
- log inside `appTick()`
- log when handling
  `GHOSTTY_ACTION_NEW_WINDOW_WITH_SURFACE_CONFIG`

Why:

- This will confirm whether the runtime wakeup reaches the main thread and
  whether the Swift action bridge sees the surface-config action.

3. If wakeup/tick/action all fire, then inspect the runtime surface creation
   path

- instrument `src/apprt/embedded.zig` around the surface creation and
  `tmux_mvp_target_ready` notification
- instrument the macOS native window creation path if needed

Why:

- At that point the problem would no longer be mailbox delivery; it would be
  native surface creation or target-ready notification.

4. Re-run a fully fresh manual validation after rebuilding the app correctly

- run `zig build -Demit-macos-app=false`
- ensure the app bundle is rebuilt via Xcode
- verify the linked `libghostty.a` is actually fresh
- launch `macos/build/Debug/Ghostty.app` by absolute path
- use a temp config with `initial-command = direct:/opt/homebrew/bin/tmux -S ... -CC new-session`

Why:

- The session lost time repeatedly to stale builds and wrong-artifact launches.
  The next session should aggressively verify the app bundle before drawing
  conclusions from runtime behavior.

## Suggested Validation Checklist For The Next Session

Use this exact sequence:

1. Verify the current source still contains the temporary tmux logs.
2. Run:

```bash
zig build -Demit-macos-app=false
zig build test -Dtest-filter=tmux
```

3. Build the macOS app with Xcode, not just `zig build`.
4. Confirm the macOS `libghostty.a` bundled into the xcframework is fresh if the
   app behavior looks stale.
5. Launch only:

- `/Users/waqas/code/ghostty_forked/macos/build/Debug/Ghostty.app`

6. Use a temporary config with:

- `window-save-state = never`
- `initial-command = direct:/opt/homebrew/bin/tmux -S <socket> -CC new-session -s <session>`

7. Tail the Ghostty log and specifically watch for:

- `tmux mvp windows action ...`
- `tmux mvp requesting ...`
- `new tmux window source=...`
- any Swift wakeup/appTick logs if added
- any `tmux_mvp_target_ready` log if added next

8. Once the second window appears, verify the actual MVP success criteria:

- a second native Ghostty surface/window exists
- it displays the captured pane content
- it is static/read-only
- it uses Ghostty's normal renderer

## Bottom Line

The tmux viewer/parser side is no longer the main risk.

What is done:

- tmux-specific backend path exists
- source-to-target snapshot bootstrap plumbing exists
- viewer `.windows` action data corruption was fixed
- core builds/tests pass
- runtime logging proves the tmux path now reaches the point where it requests
  a new tmux window

What is not yet proven:

- the app-thread mailbox and macOS wakeup/action bridge actually create and show
  the second native window reliably

That handoff should save the next session from redoing the tmux parser analysis
or the stale-build investigation from scratch.

## 2026-04-17 Session Update

This session focused on finishing the first MVP implementation, tightening the
places where the previous attempt had drifted from the design doc, and then
validating the path on macOS with the actual app bundle rather than relying on
`zig build` alone.

### 1. Faithfulness review against `tmux_docs/first_mvp/firstmvp.md`

I first re-audited the current implementation against the first MVP document
and the previous progress log.

Conclusion:

- The implementation was broadly faithful to the intended MVP shape.
- The tmux control-mode path was already wired deeply enough that Ghostty could:
  - enter tmux control mode,
  - parse pane/window events,
  - construct a `new_tmux_window` app-thread request,
  - attempt to create a second Ghostty surface/window.
- The implementation was not fully faithful yet because two important gaps
  remained:
  - the new `new_window_with_surface_config` action had been inserted in the
    middle of the public action ABI rather than appended at the end, which
    violates Ghostty's action tag ordering invariant,
  - `tmux_mvp_cols` and `tmux_mvp_rows` were being carried through parts of the
    plumbing but were not actually used to size the target tmux child surface.

Net assessment before changes:

- Roughly 80 percent faithful to the first MVP doc.
- Architecturally on the correct path.
- Not fully compliant with invariants/success criteria until the ABI ordering
  and tmux child sizing issues were corrected.

### 2. Code changes made in this session

I made the following source changes.

#### ABI ordering fix

The first MVP work introduced a new action:

- `new_window_with_surface_config`

That action had been added in the middle of:

- `src/apprt/action.zig`
- `include/ghostty.h`

This is unsafe because Ghostty's C/Zig action ABI expects new action tags and
union members to be appended at the end, not inserted in the middle, or the
tag values can shift and break consumers.

What I changed:

- moved `new_window_with_surface_config` to the end of the `Action` union in
  `src/apprt/action.zig`,
- moved it to the end of `Action.Key` in the same file,
- moved `GHOSTTY_ACTION_NEW_WINDOW_WITH_SURFACE_CONFIG` to the end of
  `ghostty_action_tag_e` in `include/ghostty.h`,
- moved `new_window_with_surface_config` to the end of `ghostty_action_u` in
  `include/ghostty.h`.

This restores the expected append-only ABI discipline.

#### Pane-size plumbing fix

The first MVP doc expects the tmux child Ghostty surface to reflect the pane
geometry when the snapshot window is created.

What I found:

- `tmux_mvp_cols` / `tmux_mvp_rows` existed in the surface options and were
  threaded into some control-mode plumbing,
- but the values were not actually being applied to the target child surface
  configuration when the embedded tmux backend surface was initialized.

What I changed:

- in `src/apprt/embedded.zig`, during embedded surface initialization, when
  `opts.backend == .tmux`, I now set:
  - `config.@"window-width"` from `opts.tmux_mvp_cols`,
  - `config.@"window-height"` from `opts.tmux_mvp_rows`.

This is the important behavioral fix because it reuses Ghostty's normal initial
size path instead of carrying extra custom size state farther into the stack.

#### Removal of dead internal size state

Once the tmux pane dimensions were applied at the actual surface-config layer,
some extra state being pushed through the core tmux MVP backend became dead
weight.

I removed:

- `cols` / `rows` from `Surface.InitBackend.tmux_mvp` in `src/Surface.zig`,
- `pending_cols` / `pending_rows` from `TmuxMvpState` in `src/Surface.zig`,
- corresponding writes in `src/termio/stream_handler.zig`,
- now-unneeded parameter passing in `src/apprt/embedded.zig`.

This reduced duplication and made the sizing story match the design intent more
cleanly.

#### Backend invariants cleanup

Some tmux backend methods had `unreachable` on non-tmux thread data. For this
code path, that is too brittle and obscures the actual invariant.

What I changed:

- in `src/termio/Tmux.zig`, replaced the `unreachable`-style backend checks in
  `threadExit`, `focusGained`, and `queueWrite` with explicit
  `std.debug.assert(td.backend == .tmux)`,
- in `src/termio/backend.zig`, added a note documenting the backend-kind
  symmetry invariant,
- added a comptime structural check to ensure `Kind`, `Config`, `Backend`, and
  `ThreadData` remain aligned.

This does not materially change MVP behavior, but it hardens the implementation
 and makes backend expansion mistakes easier to catch.

#### Explicit invariants restored and added

For clarity, these are the invariants that were either restored or made
explicit in this session:

- **Append-only action ABI invariant**
  - new action tags and union members must be appended at the end, never
    inserted in the middle, or C/Zig ABI consumers can observe shifted tag
    values.
- **Backend/thread-data kind alignment invariant**
  - `termio.backend.Kind`, `Config`, `Backend`, and `ThreadData` must remain in
    structural sync, because the backend dispatch layer assumes those sets of
    variants describe the same backend universe.
- **Tmux backend method invariant**
  - tmux backend entry points such as `threadExit`, `focusGained`, and
    `queueWrite` must only be called with tmux thread data; this is now guarded
    with explicit assertions instead of relying on `unreachable`.
- **Initial child-surface sizing invariant**
  - tmux MVP pane dimensions must be applied at actual surface/window config
    creation time, not merely stored in side-channel state that may never be
    consumed.
- **Normal Ghostty renderer invariant**
  - the tmux snapshot child view should continue to be a normal Ghostty surface
    using Ghostty's renderer and surface creation path, rather than introducing
    a one-off rendering path for tmux panes.

#### Formatting

Ran `zig fmt` on the edited Zig files after the changes.

### 3. Files changed

The files updated in this session were:

- `src/apprt/action.zig`
- `include/ghostty.h`
- `src/apprt/embedded.zig`
- `src/Surface.zig`
- `src/termio/Tmux.zig`
- `src/termio/backend.zig`
- `src/termio/stream_handler.zig`

### 4. Build and test validation done

One of the major goals of this session was to stop guessing and build a real,
repeatable understanding of how Ghostty must be validated on macOS.

#### Zig-side validation

I successfully ran:

```bash
zig build -Demit-macos-app=false
zig build test -Dtest-filter=tmux -Demit-macos-app=false
zig build test -Dtest-filter='initial flow' -Demit-macos-app=false
```

Results:

- the core library build succeeded,
- targeted tmux tests succeeded,
- the focused initial-flow test succeeded,
- the known tmux warning during tests still appeared but did not fail the run:
  - `[terminal_tmux] (warn): tmux control mode error=`

This confirmed the source changes were syntactically and semantically valid on
the Zig side.

### 5. macOS build knowledge and validation

The biggest build lesson reinforced this session is:

- `zig build` is not enough to validate the macOS app behavior when the goal is
  to run the actual Ghostty GUI app and inspect window creation behavior.

For macOS runtime validation, the app bundle must be rebuilt correctly.

I rebuilt the macOS app with Xcode using:

```bash
env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  xcodebuild \
  -project /Users/waqas/code/ghostty_forked/macos/Ghostty.xcodeproj \
  -scheme Ghostty \
  -configuration Debug \
  SYMROOT=/Users/waqas/code/ghostty_forked/macos/build \
  -derivedDataPath /tmp/ghostty-derived-data \
  build
```

Result:

- build succeeded,
- produced app bundle:
  - `/Users/waqas/code/ghostty_forked/macos/build/Debug/Ghostty.app`

This was important because stale app-bundle/runtime confusion was a major
problem in the earlier session.

### 6. Runtime validation work completed

To make tmux startup deterministic, I created a temporary helper script:

- `/tmp/ghostty_tmux_mvp.sh`

Its purpose was to launch a clean tmux control-mode session with a dedicated
socket and a simple initial command, avoiding environment/config interference.

The script effectively ran:

```sh
exec tmux -L ghostty_mvp -f /dev/null -CC new-session \
  "printf 'MVP_MARKER\n'; exec ${SHELL:-/bin/zsh} -l"
```

I also cleaned any stale server state with:

```bash
tmux -L ghostty_mvp -f /dev/null kill-server
```

Then I launched the built app executable directly with logging enabled:

```bash
GHOSTTY_LOG=stderr \
  /Users/waqas/code/ghostty_forked/macos/build/Debug/Ghostty.app/Contents/MacOS/ghostty \
  --quit-after-last-window-closed=true \
  --initial-command='direct:/tmp/ghostty_tmux_mvp.sh'
```

Observed runtime evidence:

- Ghostty entered tmux control mode.
- The `.windows` control-mode action was parsed and emitted.
- Logs showed:
  - `tmux mvp requesting pane_id=... cols=80 rows=24`
- The app mailbox received:
  - `new_tmux_window`

That is the exact high-value checkpoint for this MVP, because it proves the
flow now reaches the native window creation request with pane metadata.

### 7. Runtime instability investigation

During one validation run, there was an apparent intermittent failure around the
time the new tmux window was being created.

To investigate, I ran the app under `lldb` and captured backtraces during the
launch path. One noisy run suggested a stop around `memcpy` after the
`new_tmux_window` path had been reached, but the failure did not reproduce
deterministically on later runs.

A quieter `lldb` run with logging suppressed did not immediately reproduce the
same failure and allowed the app to continue running.

Current assessment:

- there may still be a timing-sensitive or memory-safety issue near or after
  native child-window creation,
- it is not yet proven to be deterministic,
- it did not block the core validation milestone below.

### 8. Concrete MVP validation achieved in this session

While the quieter runtime was active, I verified via AppleScript that the built
Ghostty app had two windows open.

Checks performed:

- counted windows in the running app,
- retrieved window IDs to confirm distinct native windows,
- activated the built app bundle directly.

Result:

- two Ghostty windows existed at runtime.

The user also directly observed:

- "two ghostty windows appeared"

That is the strongest practical validation result from this session.

### 9. Updated assessment of faithfulness and success criteria

After the fixes above, the implementation is much closer to the first MVP doc.

Current assessment:

- The code path is now faithful to the first MVP architecture.
- The append-only action ABI invariant is restored.
- The tmux pane dimensions are now applied in the place that matters for child
  surface creation.
- The implementation preserves the intended separation where the tmux pane is
  rendered by a normal Ghostty surface/window rather than by a custom renderer.

On success criteria:

- creating a second native Ghostty window/surface: validated,
- using Ghostty's regular rendering path for the child window: strongly
  supported by the current architecture and code path,
- pane snapshot bootstrapping from tmux control-mode data: validated by the log
  path and the second window creation,
- static/read-only behavior of the child snapshot window: not fully proven in
  this session yet,
- long-run stability of repeated creation/teardown on macOS: not fully proven
  yet.

### 10. Practical build knowledge established this session

The most useful build/validation knowledge reinforced in this session was:

- for Zig-only correctness, use:
  - `zig build -Demit-macos-app=false`
  - targeted `zig build test -Dtest-filter=... -Demit-macos-app=false`
- for macOS GUI/runtime correctness, prefer `macos/build.nu` to rebuild the app
  bundle and use direct `xcodebuild` only as a fallback when `nu` is not
  available,
- run the produced `macos/build/Debug/Ghostty.app` when validating GUI/runtime
  behavior,
- do not infer macOS GUI correctness from a library-only Zig build,
- use a deterministic tmux control-mode launcher script and a dedicated tmux
  socket to avoid stale server/session confusion,
- when validating window creation, verify the actual running app bundle and the
  live window count rather than assuming behavior from logs alone.

### 10.1 Consolidated macOS / Zig build quirks discovered

This section collects the concrete build quirks that were figured out across the
earlier work and this session, because these details were a major source of
lost time.

- **`zig build` is not sufficient for macOS GUI validation**
  - it proves the Zig/core side builds,
  - it does **not** prove that the runnable `Ghostty.app` bundle is using the
    latest core library.
- **Use `-Demit-macos-app=false` for the core loop**
  - when iterating on Zig/core changes, the fast and correct first step is:
    - `zig build -Demit-macos-app=false`
  - then run targeted tests with the same flag.
- **For real runtime validation, rebuild the macOS app bundle separately**
  - after core changes, rebuild the app with Xcode,
  - validate the output at:
    - `/Users/waqas/code/ghostty_forked/macos/build/Debug/Ghostty.app`
- **In this environment, `macos/build.nu` was not available**
  - the repo guidance points to `macos/build.nu`,
  - but `nu` was not installed here,
  - so direct `xcodebuild` was the required fallback.
- **A clean-ish Xcode environment helps avoid path/tool surprises**
  - the working invocation used:
    - `env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin ... xcodebuild ...`
  - this reduces interference from shell/session environment differences.
- **Pin `SYMROOT` and `derivedDataPath` explicitly**
  - setting:
    - `SYMROOT=/Users/waqas/code/ghostty_forked/macos/build`
    - `-derivedDataPath /tmp/ghostty-derived-data`
  - makes the produced app location deterministic and reduces confusion about
    which artifact was just built.
- **Stale xcframework/core-library linkage is a real sharp edge**
  - a previous debugging pass showed the app bundle could effectively still be
    using an older `libghostty.a` packaged in:
    - `macos/GhosttyKit.xcframework/macos-arm64_x86_64/libghostty.a`
  - if runtime behavior does not match recent Zig changes, do not assume the
    source is wrong; verify the app is actually linked against fresh core bits.
- **If app behavior looks stale, verify the library actually embedded for macOS**
  - compare timestamps and behavior,
  - confirm the app logs contain newly added trace strings,
  - if necessary, inspect candidate `libghostty.a` outputs from `.zig-cache`
    and ensure the chosen archive is a real macOS universal archive, not a
    simulator-targeted artifact.
- **Always launch the exact built app by absolute path**
  - using some other installed Ghostty or another build output can invalidate
    the test completely,
  - use:
    - `/Users/waqas/code/ghostty_forked/macos/build/Debug/Ghostty.app`
- **Pin tmux by absolute path in validation scripts**
  - on this machine, the correct binary is:
    - `/opt/homebrew/bin/tmux`
  - relying on bare `tmux` can fail if the app runtime environment has a
    different `PATH` than the interactive shell.

### 11. Current status at the end of this session

What is now done:

- first MVP implementation corrected in the main places it was drifting from the
  design,
- ABI ordering invariant fixed,
- tmux pane dimensions now actually applied to child-window creation,
- Zig build and targeted tests passing,
- macOS app rebuilt successfully,
- runtime path validated far enough to observe two Ghostty windows.

What remains to be proven or tightened in a follow-up:

- confirm the child tmux window is strictly static/read-only as intended,
- investigate the intermittent runtime failure seen during one probing run,
- repeat validation enough times to gain confidence that the macOS window
  creation path is reliable and not accidentally depending on timing.

### 12. Explicit current status and manual validation runbook

To remove ambiguity for the next session, this is the current verified status of
the first MVP as of this session:

- **Yes**, Ghostty was started in tmux control mode in the built macOS app.
- **Yes**, the tmux control-mode flow reached the `new_tmux_window` request.
- **Yes**, a second native Ghostty window appeared.
- **Yes**, the two-window state was verified programmatically via AppleScript.
- **No**, strict static/read-only behavior of the child window has not yet been
  fully proven.
- **No**, repeated-run macOS stability has not yet been fully proven.

What specifically was verified:

- the app was launched from the built bundle at:
  - `/Users/waqas/code/ghostty_forked/macos/build/Debug/Ghostty.app`
- runtime logs showed the tmux path reaching:
  - `.windows` handling,
  - `tmux mvp requesting pane_id=... cols=80 rows=24`,
  - `new_tmux_window`
- AppleScript window counting confirmed two live windows for the built app,
- the user visually confirmed that two Ghostty windows appeared.

#### Manual validation commands

Run these from the repository root:

1. Build the Zig core:

```bash
zig build -Demit-macos-app=false
```

2. Run the targeted tmux test:

```bash
zig build test -Dtest-filter=tmux -Demit-macos-app=false
```

3. Run the focused initial-flow test:

```bash
zig build test -Dtest-filter='initial flow' -Demit-macos-app=false
```

4. Rebuild the macOS app bundle.

Preferred path, if `nu` is installed:

```bash
macos/build.nu --scheme Ghostty --configuration Debug --action build
```

Fallback used in this environment, because `nu` was not installed:

```bash
env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  xcodebuild \
  -project /Users/waqas/code/ghostty_forked/macos/Ghostty.xcodeproj \
  -scheme Ghostty \
  -configuration Debug \
  SYMROOT=/Users/waqas/code/ghostty_forked/macos/build \
  -derivedDataPath /tmp/ghostty-derived-data \
  build
```

5. Create the deterministic tmux launcher script:

```bash
cat >/tmp/ghostty_tmux_mvp.sh <<'EOF'
#!/bin/sh
exec /opt/homebrew/bin/tmux -L ghostty_mvp -f /dev/null -CC new-session "printf 'MVP_MARKER\n'; exec ${SHELL:-/bin/zsh} -l"
EOF
chmod +x /tmp/ghostty_tmux_mvp.sh
```

6. Clear stale tmux server state:

```bash
/opt/homebrew/bin/tmux -L ghostty_mvp -f /dev/null kill-server >/dev/null 2>&1 || true
```

7. Launch the built Ghostty app binary with logging:

```bash
GHOSTTY_LOG=stderr \
  /Users/waqas/code/ghostty_forked/macos/build/Debug/Ghostty.app/Contents/MacOS/ghostty \
  --quit-after-last-window-closed=true \
  --initial-command='direct:/tmp/ghostty_tmux_mvp.sh'
```

8. In the logs, watch for:

- `tmux mvp requesting pane_id=... cols=... rows=...`
- `new_tmux_window`

9. In another terminal, verify the built app has two windows:

```bash
osascript -e 'tell application "/Users/waqas/code/ghostty_forked/macos/build/Debug/Ghostty.app" to count windows'
```

Expected result:

- `2`

10. Optional: verify the windows are distinct:

```bash
osascript -e 'tell application "/Users/waqas/code/ghostty_forked/macos/build/Debug/Ghostty.app" to get id of every window'
```

11. Optional: bring the app to the foreground:

```bash
osascript -e 'tell application "/Users/waqas/code/ghostty_forked/macos/build/Debug/Ghostty.app" to activate'
```

#### Manual success criteria for this stage

Treat the run as a successful first-MVP validation if all of the following are
true:

- Ghostty starts successfully from the rebuilt macOS app bundle,
- tmux control mode is entered,
- logs show `tmux mvp requesting ...` and `new_tmux_window`,
- a second native Ghostty window appears,
- AppleScript window count returns `2`.

Treat the following as still-open follow-up items even if the above passes:

- proving the child window is static/read-only,
- investigating intermittent crash/stability behavior,
- verifying repeated create/teardown cycles.
