# Full MVP Manual Validation

This is the source-of-truth manual proof for the tmux first MVP.

If this flow passes exactly as written, the first MVP claims from
`tmux_docs/firstmvp/firstmvp.md` are proven:

- Ghostty creates a second native window for tmux pane `%0`
- the second window is seeded from a tmux pane snapshot
- the second window stays static after the source tmux pane changes
- the second window behaves as read-only for this MVP
- the second window is a normal Ghostty surface and window

If any required check fails, the MVP is not yet proven.

## Validation Assets

Everything for this validation now lives under `tmux_docs/firstmvp/validation/`:

- `fullmvp_manual_validation.md`: this manual proof
- `ghostty_tmux_fullmvp_attach.sh`: attaches Ghostty to the already prepared tmux session
- `validate_remaining_mvp.sh`: repeats the same proof automatically
- `fullmvp_manual_validation_tutorial.md`: simple explanation of what each step is doing

## What This Validation Proves

This validation uses three markers:

- `FULLMVP_SNAP_A`
- `FULLMVP_LIVE_B`
- `FULLMVP_CHILD_INPUT`

Each marker proves one thing:

- `FULLMVP_SNAP_A` proves the child window was seeded from the captured tmux pane
- `FULLMVP_LIVE_B` proves the source tmux pane changed after the snapshot
- absence of `FULLMVP_CHILD_INPUT` in tmux proves the child window is read-only in practice

## Preconditions

Run all commands from the repository root:

```bash
cd /Users/waqas/code/ghostty_forked
```

This flow assumes:

- `nu` is installed at `/opt/homebrew/bin/nu`
- tmux is installed at `/opt/homebrew/bin/tmux`
- the built app path is `/Users/waqas/code/ghostty_forked/macos/build/Debug/Ghostty.app`
- the Ghostty executable path is `/Users/waqas/code/ghostty_forked/macos/build/Debug/Ghostty.app/Contents/MacOS/ghostty`

## 1. Start From a Clean Ghostty State

Quit any existing Ghostty instance:

```bash
osascript -e 'tell application "/Users/waqas/code/ghostty_forked/macos/build/Debug/Ghostty.app" to quit' >/dev/null 2>&1 || true
sleep 1
```

Now verify that no leftover Ghostty process is still running:

```bash
pgrep -if '/Users/waqas/code/ghostty_forked/macos/build/Debug/Ghostty.app/Contents/MacOS/ghostty' || true
```

Required result:

- no PID is printed

Why this matters:

- restored or leftover windows make the window-count checks invalid
- this proof only counts if the run starts from zero Ghostty windows

## 2. Build the Exact App You Will Validate

Run:

```bash
zig build -Demit-macos-app=false
zig build test -Dtest-filter=tmux -Demit-macos-app=false
zig build test -Dtest-filter='initial flow' -Demit-macos-app=false
macos/build.nu --scheme Ghostty --configuration Debug --action build
```

Required result:

- all four commands succeed

If any command fails, stop. The MVP is not validated.

## 3. Clear Stale tmux State

Run:

```bash
/opt/homebrew/bin/tmux -L ghostty_fullmvp -f /dev/null kill-server >/dev/null 2>&1 || true
```

Do this before every validation attempt.

## 4. Pre-Create the tmux Session and Make Sure the Snapshot Marker Already Exists

Create the tmux session before Ghostty attaches:

```bash
/opt/homebrew/bin/tmux -L ghostty_fullmvp -f /dev/null new-session -d -s fullmvp "printf 'FULLMVP_SNAP_A\n'; exec ${SHELL:-/bin/zsh} -l"
```

Now verify the pane already contains the snapshot marker:

```bash
/opt/homebrew/bin/tmux -L ghostty_fullmvp -f /dev/null capture-pane -p -t fullmvp:0.0
```

Required result:

- the captured pane text already contains `FULLMVP_SNAP_A`

Do not launch Ghostty until this passes.

Why this matters:

- the child window is seeded from tmux `capture-pane`
- if Ghostty attaches before the marker exists in tmux history, the snapshot can be empty
- pre-populating the pane removes that race

## 5. Use the Checked-In Control-Mode Attach Launcher

Make sure the checked-in attach script is executable:

```bash
chmod +x tmux_docs/firstmvp/validation/ghostty_tmux_fullmvp_attach.sh
```

That script does one thing:

- it attaches Ghostty to the already prepared `fullmvp` session in tmux control mode

This is important because the session must already contain `FULLMVP_SNAP_A`
before Ghostty starts.

## 6. Launch the Built Ghostty Binary With Logging and Disabled Window Restore

Run:

```bash
GHOSTTY_LOG=stderr \
  /Users/waqas/code/ghostty_forked/macos/build/Debug/Ghostty.app/Contents/MacOS/ghostty \
  --quit-after-last-window-closed=true \
  --window-save-state=never \
  --initial-command='direct:/Users/waqas/code/ghostty_forked/tmux_docs/firstmvp/validation/ghostty_tmux_fullmvp_attach.sh'
```

Leave this terminal open while you validate.

Why this launch shape is required:

- `--window-save-state=never` prevents old Ghostty windows from being restored
- `direct:.../ghostty_tmux_fullmvp_attach.sh` forces Ghostty to attach to the tmux session prepared in step 4

## 7. Confirm Ghostty Created Exactly Two Native Windows

Wait a moment for the attach and child-window creation to settle, then run:

```bash
sleep 1
osascript -e 'tell application "/Users/waqas/code/ghostty_forked/macos/build/Debug/Ghostty.app" to count windows'
```

Required result:

- output is exactly `2`

Optional supporting check:

```bash
osascript -e 'tell application "/Users/waqas/code/ghostty_forked/macos/build/Debug/Ghostty.app" to get id of every window'
```

Required interpretation:

- there are exactly two distinct window IDs

If the count is anything other than `2`, the run is invalid. Quit Ghostty,
clear tmux with step 3, and restart from step 1.

What this proves:

- Ghostty created a second native window instead of keeping everything inside the original control-mode surface

## 8. Visually Confirm the Child Window Shows the Snapshot Marker

You should now see:

- one original tmux control-mode window
- one new child window

Required visual check:

- the new child window visibly shows `FULLMVP_SNAP_A`

Required interpretation:

- if the child window is blank, missing, or does not contain `FULLMVP_SNAP_A`, the MVP is not validated

What this proves:

- the second window was not only created
- it was seeded with captured tmux pane contents
- Ghostty rendered that snapshot as a real terminal surface

## 9. Advance the Source tmux Pane After the Snapshot Exists

Now change the real tmux pane after the child snapshot window is already visible:

```bash
/opt/homebrew/bin/tmux -L ghostty_fullmvp -f /dev/null send-keys -t fullmvp:0.0 "printf 'FULLMVP_LIVE_B\n'" C-m
```

Then verify the source pane:

```bash
/opt/homebrew/bin/tmux -L ghostty_fullmvp -f /dev/null capture-pane -p -t fullmvp:0.0
```

Required result:

- the tmux pane output contains both `FULLMVP_SNAP_A` and `FULLMVP_LIVE_B`

What this proves:

- the real tmux pane kept changing after the snapshot point

## 10. Confirm the Child Window Stayed Static

Look back at the child Ghostty window after step 9 passes.

Required visual check:

- the child window still shows `FULLMVP_SNAP_A`
- the child window does not show `FULLMVP_LIVE_B`

Required interpretation:

- if `FULLMVP_LIVE_B` appears in the child window, the child is live-updating and the first MVP has failed

What this proves:

- the child is a static snapshot window, not a live mirror

## 11. Confirm the Child Window Is Read-Only

Click into the child Ghostty window and type:

```text
FULLMVP_CHILD_INPUT
```

Then press `Enter`.

After that, run:

```bash
/opt/homebrew/bin/tmux -L ghostty_fullmvp -f /dev/null capture-pane -p -t fullmvp:0.0
```

Required result:

- the tmux pane output does not contain `FULLMVP_CHILD_INPUT`

Required interpretation:

- if `FULLMVP_CHILD_INPUT` appears in tmux, input leaked through and the child is not read-only

What this proves:

- the child surface behaves like a normal Ghostty window for focus and rendering
- but input is not forwarded into tmux for this MVP

## 12. Check for Crash or Unexpected Teardown

While the app is running, the launch terminal from step 6 must not show:

- a process crash
- an unexpected exit
- Ghostty quitting before you finish the checks

If Ghostty crashes or exits unexpectedly during any part of the validation, the
MVP is not validated.

## 13. Repeat the Same Proof for Stability

To treat the MVP as stable, repeat the full flow above at least 5 times from a
clean tmux server.

You can do that in one of two ways:

- manually, by repeating steps 1 through 12
- automatically, by running:

```bash
chmod +x tmux_docs/firstmvp/validation/validate_remaining_mvp.sh
tmux_docs/firstmvp/validation/validate_remaining_mvp.sh
```

That script follows the same proof shape as this document:

- it clears Ghostty and tmux state
- it pre-creates the tmux session with the snapshot marker already present
- it launches Ghostty through the checked-in attach script
- it waits for two windows
- it verifies snapshot, static, and read-only behavior

Required result:

- all 5 runs pass

If even one run fails intermittently, the MVP is not stable enough to call
done.

## Final Pass Criteria

Only call the tmux first MVP complete if all of the following are true:

- the build and test commands in step 2 all pass
- the tmux pane already contains `FULLMVP_SNAP_A` before Ghostty launches
- Ghostty creates exactly `2` native windows
- the child window visibly contains `FULLMVP_SNAP_A`
- the real tmux source pane later contains both `FULLMVP_SNAP_A` and `FULLMVP_LIVE_B`
- the child window still does not show `FULLMVP_LIVE_B`
- typing `FULLMVP_CHILD_INPUT` into the child does not change the tmux pane
- Ghostty does not crash during the run
- the entire flow passes 5 times from a clean tmux server

If every one of those conditions is satisfied, then the first MVP is validated.

## Notes

- If logs show `.pane_snapshot = .{ .pane_id = 0, .data = { } }`, the snapshot was empty and the run is invalid. That means Ghostty attached before the marker existed in tmux history. Re-run from a clean tmux server and make sure step 4 passes before step 6.
- If `IOSurfaceLayer: surface is wrong size for layer, discarding` appears in logs but every required behavioral check above passes, treat that warning as non-blocking for the first MVP.
- Do not treat “two windows appeared” by itself as sufficient. The MVP requires snapshot content, static behavior, and read-only behavior, not only window creation.
