# tmux First MVP Diff Explanation

This document explains the implementation diff saved at:

- `tmux_docs/firstmvp/implementation.diff`

It maps each file change to the sub-tasks in
`tmux_docs/first_mvp/firstmvp.md`, explains why the change was made, why it is
architecturally sound, and how I would stress-test it as a senior engineer.

It also re-checks the build and manual validation instructions recorded in
`tmux_docs/firstmvp/progress.md`.

## Executive Summary

The implementation is directionally correct and matches the first MVP shape in
`firstmvp.md`:

- add a `.tmux` backend kind,
- create a tmux-specific surface on the main/app thread when the `.windows`
  tmux viewer action arrives,
- bootstrap the child surface with a static pane snapshot,
- keep the child surface read-only,
- avoid live tmux output routing for now.

The most important correctness fixes beyond the original implementation were:

- restoring append-only action ABI ordering,
- ensuring the tmux pane dimensions are actually applied to the child surface,
- fixing a use-after-free bug in the viewer `.windows` action payload,
- making backend invariants explicit instead of relying on accidental behavior.

## Task Mapping

`firstmvp.md` breaks the work into these sub-tasks:

1. Add `.tmux` variant to backend kind enum.
2. Fix all switch sites to handle `.tmux`.
3. Create a tmux backend stub implementation.
4. Wire the `.windows` action to create a surface.
5. Populate the tmux surface with captured pane content.

The diff implements all five. Some additional changes were not optional extras;
they were required to preserve Ghostty invariants and make the MVP actually
work on macOS.

## File-By-File Explanation

### `src/termio/backend.zig`

**Belongs to:** Sub-task 1 and Sub-task 2.

**What changed**

- Added `.tmux` to `Kind`.
- Added `.tmux` variants to `Config`, `Backend`, and `ThreadData`.
- Added explicit `.tmux` handling to every backend method switch.
- Added a doc comment stating the backend dispatch invariant.
- Added a comptime symmetry assertion across `Kind`, `Config`, `Backend`, and
  `ThreadData`.

**Why it was made**

This is the foundational type-system change that makes a non-exec surface even
possible. Without a second backend kind, every surface is forced into the PTY
/ subprocess model.

**Why it makes sense**

This is exactly what `firstmvp.md` asks for. It keeps the abstraction honest:
the surface owns a backend, and that backend decides how terminal content
arrives. `exec` means PTY/subprocess. `tmux` means pane-driven snapshot routing.

**Stress test**

- Add another backend kind later and intentionally forget to update one union:
  the comptime assertions should fail immediately.
- Call every backend method on a `.tmux` backend: no arm should panic merely
  because the backend is `.tmux`.
- Ensure the calling code never needs `if backend == ...` branching just to use
  the backend abstraction.

**Why it works**

Because it preserves the total-interface property of `Backend`: any backend kind
can safely receive the standard backend calls, even if some of those
implementations are intentional no-ops.

### `src/termio/Tmux.zig`

**Belongs to:** Sub-task 3.

**What changed**

- Added a new tmux backend stub implementation.
- Stored `pane_id`.
- Implemented the backend methods as no-op or assertion-backed tmux-specific
  behavior.
- Set `td.backend = .{ .tmux = .{} }` during `threadEnter`.

**Why it was made**

The backend union needs a concrete implementation for `.tmux`. This file is the
minimal non-PTY backend needed for the MVP.

**Why it makes sense**

It matches the design intent from `firstmvp.md`: no PTY, no child process, no
read thread, no live writes. The backend exists to satisfy the surface/termio
contract while staying deliberately small.

**Stress test**

- Verify this backend does not allocate PTY/process resources.
- Verify `queueWrite` does not mutate tmux state for the MVP.
- Verify `threadExit` and `focusGained` fail fast if the wrong thread-data kind
  reaches them.

**Why it works**

The child surface only needs an owned `Terminal` and the termio lifecycle. It
does not need a subprocess. This stub backend provides exactly that and nothing
more.

### `src/termio.zig`

**Belongs to:** Sub-task 3.

**What changed**

- Exported `Tmux` from the termio module tree.

**Why it was made**

So `backend.zig` and `Surface.zig` can construct `termio.Tmux`.

**Why it makes sense**

This is normal Ghostty module plumbing. Without it, the new backend type cannot
participate in the existing termio composition pattern.

**Stress test**

- Build from a cold state and ensure no import cycle or missing symbol occurs.

**Why it works**

It is a straightforward module exposure change.

### `src/App.zig`

**Belongs to:** Sub-task 4.

**What changed**

- Added `new_tmux_window` to the app mailbox message union.
- Added `newTmuxWindow(...)`.
- In the mailbox drain path, routed `.new_tmux_window` to that handler.
- Built a `SurfaceConfig` that marks the new surface as `.tmux` and carries:
  - source surface,
  - pane id,
  - cols,
  - rows.
- Called `performAction(..., .new_window_with_surface_config, config)`.

**Why it was made**

The `.windows` action arrives on the IO thread, but surface creation must happen
on the app/main thread. `App.zig` is the correct bridge between those worlds.

**Why it makes sense**

This is the correct threading boundary. It obeys the hardest constraint in the
design doc: do not create the surface on the IO thread.

**Stress test**

- Fire multiple `.windows` actions and confirm the source surface’s
  `tmux_mvp.requested` flag prevents duplicate child-window requests.
- Close the source surface before the app-thread message drains; `hasSurface`
  should prevent creating an orphan child window.
- Ensure the action still targets the proper surface/app context.

**Why it works**

Because it defers the actual window creation to the runtime’s existing action
machinery, but with an explicit `SurfaceConfig` that changes the backend choice.

### `src/apprt/surface.zig`

**Belongs to:** Sub-task 4, with ABI support needed for Sub-task 5.

**What changed**

- Added `tmux_mvp_target_ready` and `tmux_mvp_target_closed` surface messages.
- Added `SurfaceConfigBackend`.
- Added a shared `SurfaceConfig` extern struct.
- Added tmux MVP metadata fields to that config.
- Added ABI-stable environment/platform support types reused by embedding.

**Why it was made**

The runtime boundary needed a single config payload that can:

- travel through the action system,
- cross Zig/C/Swift cleanly,
- carry both ordinary surface options and tmux-specific metadata.

**Why it makes sense**

This unifies what had previously been split or implicit. It is the right shape
for Ghostty’s embedding boundary and avoids building an ad hoc one-off message
format just for tmux.

**Stress test**

- Serialize ordinary exec-backed window creation through the same type and
  ensure behavior is unchanged.
- Verify null/default fields are safe.
- Verify the tmux pointer fields are only interpreted when `backend == .tmux`.

**Why it works**

It provides a stable contract between core Zig and the runtime layer, which is
exactly what cross-language window creation needs.

### `src/apprt/action.zig`

**Belongs to:** Sub-task 4, plus invariant repair.

**What changed**

- Added `new_window_with_surface_config`.
- Made its payload `apprt.surface.SurfaceConfig`.
- Updated the ABI size assertion for the union C payload.
- The action was later corrected to be append-only in the enum/union ordering.

**Why it was made**

The existing `new_window` action did not carry enough information to tell the
runtime that this was a tmux-backed surface with source/pane metadata.

**Why it makes sense**

This is a clean way to reuse Ghostty’s existing runtime action path without
lying about what kind of surface should be created.

**Stress test**

- Verify ordinary actions still preserve their tag values.
- Verify the C-compatible union size matches the surface-config payload.
- Verify the new action can be carried across the embedded runtime boundary.

**Why it works**

Because it turns “create a window” into “create a window with explicit surface
options,” which is exactly what this MVP needs.

### `include/ghostty.h`

**Belongs to:** Sub-task 4, plus ABI repair.

**What changed**

- Added `ghostty_surface_config_backend_e`.
- Added tmux fields to `ghostty_surface_config_s`.
- Added `GHOSTTY_ACTION_NEW_WINDOW_WITH_SURFACE_CONFIG`.
- Added `new_window_with_surface_config` to `ghostty_action_u`.

**Why it was made**

The Swift/macOS side consumes the exported C ABI. The new action and surface
config could not exist purely in Zig.

**Why it makes sense**

This keeps the C ABI aligned with the Zig types. Anything less would make the
embedded runtime behavior undefined or stale.

**Stress test**

- Regenerate or compile any consumer against `ghostty.h` and ensure tags and
  payload layout match the Zig side.
- Confirm the new action tag remains appended at the end.

**Why it works**

Because it mirrors the runtime-facing data exactly. The C header is not an
optional convenience here; it is part of the execution path.

### `macos/Sources/Ghostty/Ghostty.App.swift`

**Belongs to:** Sub-task 4.

**What changed**

- Added handling for `GHOSTTY_ACTION_NEW_WINDOW_WITH_SURFACE_CONFIG`.
- Added a `newWindow(..., config:)` path.
- Posted the existing new-window notification with a concrete `SurfaceConfig`.

**Why it was made**

The app runtime needed to accept the new explicit surface configuration when the
Zig side requests a tmux-backed window.

**Why it makes sense**

This reuses the established macOS window-creation path instead of inventing a
special tmux-only window constructor in Swift.

**Stress test**

- Create an app-targeted window and a surface-targeted window and ensure both
  notification paths remain correct.
- Verify nil/invalid target handling does not crash.

**Why it works**

The Swift app layer already knows how to create windows from notifications. The
only missing piece was passing through the full config instead of a bare action.

### `macos/Sources/Ghostty/Surface View/SurfaceView.swift`

**Belongs to:** Sub-task 4.

**What changed**

- Extended `SurfaceConfiguration` with:
  - backend,
  - source surface,
  - pane id,
  - cols,
  - rows.
- Read those fields from `ghostty_surface_config_s`.
- Wrote those fields back out in `withCValue`.

**Why it was made**

The Swift side had to preserve the explicit tmux config when creating the new
surface. Without this, the C payload would be truncated back to exec defaults.

**Why it makes sense**

This is the exact bridge the runtime needs. The config must survive the
Swift-layer hop intact.

**Stress test**

- Round-trip a config through Swift and verify the backend and tmux metadata are
  unchanged.
- Ensure ordinary exec-backed window creation still defaults to `.exec`.

**Why it works**

Because it maintains a symmetric translation between Zig/C ABI and Swift.

### `src/apprt/embedded.zig`

**Belongs to:** Sub-task 4, plus the pane-size correction needed for success
criteria.

**What changed**

- Reused `apprt.surface.SurfaceConfig` as the embedded options type.
- Reused the shared env-var type.
- Converted the surface creation path to understand `opts.backend`.
- When `backend == .tmux`:
  - applied `tmux_mvp_cols` / `tmux_mvp_rows` to `window-width` /
    `window-height`,
  - built `CoreSurface.InitBackend.tmux_mvp`,
  - passed the source surface and pane id into core surface init,
  - sent `tmux_mvp_target_ready` after the target surface was created.
- Ensured `newSurfaceOptions` defaults to `.exec`.

**Why it was made**

This file is where the embedded runtime actually instantiates surfaces. It is
the place where the backend choice has to turn from metadata into reality.

**Why it makes sense**

This is the correct layer for two crucial decisions:

- whether the new surface is exec-backed or tmux-backed,
- what initial size the new window should have.

The pane-size application here was a necessary fix. Before that correction, the
metadata existed but did not affect the actual child surface geometry.

**Stress test**

- Create a normal window and ensure it still goes through `.exec`.
- Create a tmux window and verify the resulting surface gets the pane metadata.
- Verify target-ready notification can arrive before or after snapshot storage
  without losing data.
- Verify invalid `tmux_mvp_source_surface` is rejected.

**Why it works**

Because it is the single runtime choke point where the config becomes a real
surface. That is where backend branching belongs.

### `src/Surface.zig`

**Belongs to:** Sub-task 4 and Sub-task 5.

**What changed**

- Added `InitBackend` so `Surface.init` can create either:
  - an exec-backed surface,
  - a tmux MVP child surface.
- Added `TmuxMvpState` to track:
  - whether a request was made,
  - which pane is being targeted,
  - the target child surface,
  - pending snapshot bytes,
  - reverse linkage from child to source.
- Changed `Surface.init` to branch backend creation instead of hardcoding exec.
- Marked tmux MVP surfaces as `readonly = true`.
- On child deinit, notified the source surface that the target closed.
- Added handlers for:
  - `tmux_mvp_target_ready`,
  - `tmux_mvp_target_closed`.
- Added snapshot store/flush helpers.
- Routed snapshot bytes to the child surface via the child termio mailbox.
- Added a tmux-safe fallback string for abnormal-exit reporting.

**Why it was made**

This file owns the surface lifecycle and is where the architecture had been
hardcoded to exec. It also owns the synchronization state needed to bridge
snapshot bytes from the source tmux session into the child terminal safely.

**Why it makes sense**

This is the core of the MVP:

- the child surface remains a normal Ghostty surface with its own `Termio` and
  `Terminal`,
- the source surface stores the snapshot until the child target exists,
- the child receives bytes through its own IO path,
- the child is explicitly read-only.

This follows the design doc exactly. It does not try to share the viewer’s
terminal object, which would be the wrong abstraction.

**Stress test**

- Snapshot arrives before target-ready:
  - it should be buffered and flushed later.
- Target-ready arrives before snapshot:
  - later snapshot should flush immediately.
- Target closes:
  - source should stop holding a stale target pointer.
- User types in child surface:
  - `readonly` should prevent normal input behavior, and backend writes are
    also no-op.
- Multiple snapshots for same pane:
  - older pending snapshot should be freed and replaced safely.

**Why it works**

Because it respects the surface’s own ownership model. The child terminal is
only mutated through the child surface’s own termio mailbox, under the child’s
normal synchronization path.

### `src/terminal/tmux/layout.zig`

**Belongs to:** Sub-task 4.

**What changed**

- Added `FirstPane`.
- Added `firstPane()` traversal helper.

**Why it was made**

The `.windows` action contains the layout tree. The MVP needs a deterministic
way to pick the first pane from that layout.

**Why it makes sense**

The first MVP only promises “pane %0 / the first pane” behavior, not a full
multi-pane renderer. This helper keeps that extraction logic localized and
testable.

**Stress test**

- Run against pane-only layouts.
- Run against nested horizontal/vertical layouts.
- Ensure it returns the first leaf pane consistently.

**Why it works**

It is a straightforward recursive left-to-right search of the existing layout
tree.

### `src/terminal/tmux/viewer.zig`

**Belongs to:** Sub-task 5, plus one critical correctness fix that unblocked
Sub-task 4.

**What changed**

- Added a `pane_snapshot` action carrying the primary-screen VT bytes.
- Emitted `pane_snapshot` when `pane_visible` arrives for the primary screen.
- Fixed the `.windows` action to emit `self.windows.items` after `syncLayouts`
  instead of emitting a temporary local array.
- Strengthened the `initial flow` test to assert stable window/pane/layout
  values.

**Why it was made**

Two reasons:

1. The child surface needs VT bytes to seed its terminal.
2. The preexisting `.windows` implementation was buggy because it emitted a
   pointer to freed temporary storage.

**Why it makes sense**

`pane_snapshot` is the cleanest way to keep the viewer responsible for
producing pane content while leaving surface creation and rendering elsewhere.

The `.windows` fix was mandatory. Without it, window metadata crossing into the
stream handler was garbage.

**Stress test**

- Ensure the viewer emits `pane_snapshot` only for the primary screen.
- Ensure the `.windows` payload remains valid after the handler returns.
- Confirm the strengthened test catches regression in layout parsing or storage
  lifetime.

**Why it works**

Because it separates two distinct artifacts:

- stable window/layout metadata,
- snapshot VT bytes for initial rendering.

Both are now emitted in forms the downstream code can safely consume.

### `src/termio/message.zig`

**Belongs to:** Sub-task 5.

**What changed**

- Added `process_output` message carrying owned bytes.

**Why it was made**

The source surface needed a safe way to ask the child surface’s IO thread to
feed bytes through `processOutput()`.

**Why it makes sense**

This is the right threading primitive for the design doc’s terminal-mutation
invariant. It avoids direct cross-thread terminal mutation.

**Stress test**

- Send owned data and verify it is freed exactly once.
- Ensure this message type does not bypass existing mailbox ordering.

**Why it works**

It reuses the existing mailbox model rather than introducing a one-off callback
or lock inversion.

### `src/termio/Thread.zig`

**Belongs to:** Sub-task 5.

**What changed**

- Added handling for `process_output`.
- Freed the owned buffer after delivery.
- Called `io.processOutput(v.data)`.

**Why it was made**

The new mailbox message needed a consumer in the child surface’s IO thread.

**Why it makes sense**

This is exactly the right place to process forwarded bytes because this thread
already owns the normal output-processing pipeline.

**Stress test**

- Deliver multiple process-output messages back-to-back.
- Verify no leak or double-free occurs.
- Verify terminal state changes happen under the same threading model as normal
  PTY output.

**Why it works**

Because it feeds the snapshot through the same mature VT parsing pipeline Ghostty
already uses for subprocess output.

### `src/termio/stream_handler.zig`

**Belongs to:** Sub-task 4 and Sub-task 5.

**What changed**

- Added `appMessageWriter(...)` to push app-thread messages while safely dealing
  with mailbox backpressure.
- Implemented `.windows` handling:
  - picks the first pane,
  - marks the request as sent,
  - posts `.new_tmux_window` to the app mailbox.
- Implemented `.pane_snapshot` handling:
  - stores snapshot bytes on the source surface,
  - flushes them if the target is already ready.

**Why it was made**

This is where the viewer actions land. Before this change, `.windows` was a
dead end.

**Why it makes sense**

This file is the correct control-plane integration point:

- it receives tmux viewer actions,
- it runs on the source surface IO thread,
- it can coordinate with the app mailbox and surface mailbox.

Crucially, it still does **not** create the child surface directly.

**Stress test**

- `.windows` arrives multiple times:
  only the first one should schedule the child window.
- `.pane_snapshot` arrives before target-ready:
  it should buffer.
- `.pane_snapshot` arrives after target-ready:
  it should flush immediately.
- App mailbox is temporarily full:
  the helper should fall back to a blocking push without permanently breaking
  the renderer mutex discipline.

**Why it works**

Because it is doing coordination only, not violating thread ownership. Surface
creation stays on the app thread, and terminal mutation stays on the target IO
thread.

## Additional Invariant Repairs Beyond The Raw MVP

The raw sub-task list in `firstmvp.md` was not enough by itself. These extra
corrections were required for a sound implementation.

### ABI append-only ordering

The action ABI must remain append-only. The new action was corrected so it is
appended at the end of:

- `src/apprt/action.zig`
- `include/ghostty.h`

Why this matters:

- C/Zig consumers may depend on stable enum tag values.
- Inserting a new action into the middle can silently corrupt behavior across
  the runtime boundary.

### Surface sizing must be consumed, not merely threaded

The tmux pane cols/rows were added to the config path, but that alone is not
enough. They must be consumed in the actual child-surface creation path.

That correction was made in `src/apprt/embedded.zig` by applying:

- `window-width = tmux_mvp_cols`
- `window-height = tmux_mvp_rows`

Why this matters:

- otherwise the pane-size metadata is dead weight,
- the child window can come up with the wrong geometry,
- the success criteria explicitly care about rendering the pane snapshot in a
  normal surface/window.

### Read-only and static behavior

The design doc wants a read-only, static snapshot surface.

This implementation satisfies that in two separate ways:

- `Surface.init` marks tmux MVP surfaces as `readonly = true`,
- `Tmux.queueWrite` is a no-op.

And it stays static because:

- only the initial `pane_snapshot` path feeds bytes to the child,
- there is no live `%output` forwarding into the child yet.

That is exactly the intended scope limit for the first MVP.

## Stress-Test Verdict

As a senior-engineering review, the design is sound for the first MVP because it
holds the right invariants:

- surface creation stays on the app/main thread,
- terminal mutation stays on the target surface’s own IO path,
- the child surface owns its own `Termio` and `Terminal`,
- tmux does not get forced into the exec/PTTY model,
- the child remains read-only and static,
- cross-language config payloads are explicit and ABI-stable.

The two places that needed especially careful scrutiny were:

1. **lifetime of window metadata**
   - fixed by switching from a temporary `windows` array to `self.windows`.
2. **ordering of snapshot vs target creation**
   - handled by buffering `pending_snapshot` on the source and flushing when the
     target becomes ready.

Those are the kinds of edge cases that usually break an MVP like this. The
current design handles them in a defensible way.

## Build Instruction Verification

I re-checked the build instructions against:

- `macos/AGENTS.md`
- `macos/build.nu`

### What is correct

- For core Zig changes outside `macos/`, run:
  - `zig build -Demit-macos-app=false`
- For the macOS app, the **preferred** build entrypoint is:
  - `macos/build.nu --scheme Ghostty --configuration Debug --action build`
- The output app path is:
  - `macos/build/Debug/Ghostty.app`
- If `nu` is unavailable, direct `xcodebuild` is a valid fallback.
- Manual validation should target the built app by absolute path.
- The tmux validation script should pin tmux to:
  - `/opt/homebrew/bin/tmux`

### What I corrected in `progress.md`

The manual runbook in `tmux_docs/firstmvp/progress.md` has been corrected so it
now:

- presents `macos/build.nu` as the preferred app build path,
- keeps direct `xcodebuild` as the fallback used in this environment,
- pins the tmux cleanup command to `/opt/homebrew/bin/tmux`,
- keeps the rest of the validation sequence aligned with the actual artifact
  paths and runtime checks we used.

### Recommended manual validation sequence

The current manual validation instructions in `progress.md` are correct to use,
with these expectations:

- run the Zig build/test commands from the repo root,
- build the app with `macos/build.nu` if available,
- otherwise use the documented `xcodebuild` fallback,
- create `/tmp/ghostty_tmux_mvp.sh` with `/opt/homebrew/bin/tmux`,
- clear stale tmux server state with the same absolute tmux path,
- launch:
  - `/Users/waqas/code/ghostty_forked/macos/build/Debug/Ghostty.app/Contents/MacOS/ghostty`
- verify logs show:
  - `tmux mvp requesting ...`
  - `new_tmux_window`
- verify AppleScript window count returns `2`.

## Bottom Line

The diff is coherent and the changes make sense.

The strongest reasons this MVP works are:

- it uses Ghostty’s real surface/termio/renderer model instead of bypassing it,
- it obeys the app-thread vs IO-thread boundary,
- it bootstraps the child terminal through Ghostty’s normal VT path,
- it deliberately keeps the scope small: one pane, one extra window, static
  snapshot, read-only.

That is the right first proof point for tmux control-mode integration.
