# Validate With `build.nu`

This is an older smoke validation for the initial window-creation path. For a
screencast or maintainer demo of the full MVP, use
`tmux_docs/firstmvp/validation/fullmvp_manual_validation.md` instead because it
also proves snapshot seeding, static behavior, and read-only behavior.

This file records the verified macOS validation flow using the repo's official
build entrypoint:

- `macos/build.nu`

This was checked against:

- `macos/AGENTS.md`
- `macos/build.nu`

Current environment assumptions that were verified:

- `nu` is installed at `/opt/homebrew/bin/nu`
- `macos/build.nu` is executable
- the built app output path is:
  - `/Users/waqas/code/ghostty_forked/macos/build/Debug/Ghostty.app`

## Why this flow

For changes outside `macos/`, the repo expects:

1. update the underlying Ghostty core library with:
   - `zig build -Demit-macos-app=false`
2. then build the macOS app with:
   - `macos/build.nu`

Do not use `zig build` alone to validate the GUI app runtime behavior.

## Step-by-step validation

Run all commands from the repository root:

```bash
cd /Users/waqas/code/ghostty_forked
```

### 1. Rebuild the Zig core library

Required because the tmux MVP changes are outside `macos/`.

```bash
zig build -Demit-macos-app=false
```

### 2. Run the targeted tmux Zig test

```bash
zig build test -Dtest-filter=tmux -Demit-macos-app=false
```

### 3. Run the focused initial-flow Zig test

```bash
zig build test -Dtest-filter='initial flow' -Demit-macos-app=false
```

### 4. Build the macOS app with the official repo command

```bash
macos/build.nu --scheme Ghostty --configuration Debug --action build
```

Expected output artifact:

```bash
/Users/waqas/code/ghostty_forked/macos/build/Debug/Ghostty.app
```

### 5. Use the checked-in tmux control-mode launcher script

This keeps the validation assets in the repo instead of recreating a `/tmp`
script each time.

```bash
chmod +x tmux_docs/firstmvp/validation/ghostty_tmux_mvp.sh
```

### 6. Clear stale tmux server state

```bash
/opt/homebrew/bin/tmux -L ghostty_mvp -f /dev/null kill-server >/dev/null 2>&1 || true
```

### 7. Launch the built Ghostty app binary with logging

```bash
GHOSTTY_LOG=stderr \
  /Users/waqas/code/ghostty_forked/macos/build/Debug/Ghostty.app/Contents/MacOS/ghostty \
  --quit-after-last-window-closed=true \
  --initial-command='direct:/Users/waqas/code/ghostty_forked/tmux_docs/firstmvp/validation/ghostty_tmux_mvp.sh'
```

### 8. Watch for the key log lines

You want to see lines equivalent to:

```text
tmux mvp requesting pane_id=... cols=... rows=...
new_tmux_window
```

Those indicate:

- Ghostty entered tmux control mode
- the `.windows` action was handled
- the app-thread request to create the tmux child window was issued

### 9. In another terminal, verify the built app has two windows

```bash
osascript -e 'tell application "/Users/waqas/code/ghostty_forked/macos/build/Debug/Ghostty.app" to count windows'
```

Expected result:

```text
2
```

### 10. Optional: verify the windows are distinct

```bash
osascript -e 'tell application "/Users/waqas/code/ghostty_forked/macos/build/Debug/Ghostty.app" to get id of every window'
```

### 11. Optional: bring the app to the foreground

```bash
osascript -e 'tell application "/Users/waqas/code/ghostty_forked/macos/build/Debug/Ghostty.app" to activate'
```

## Success criteria for this validation

Treat the run as a successful first-MVP validation if all of the following are
true:

- `zig build -Demit-macos-app=false` succeeds
- `zig build test -Dtest-filter=tmux -Demit-macos-app=false` succeeds
- `zig build test -Dtest-filter='initial flow' -Demit-macos-app=false` succeeds
- `macos/build.nu --scheme Ghostty --configuration Debug --action build` succeeds
- the launched app enters tmux control mode
- logs show `tmux mvp requesting ...`
- logs show `new_tmux_window`
- a second Ghostty window appears
- AppleScript window count returns `2`

## Notes

- `macos/build.nu` is the canonical repo-recommended build path for the macOS
  app.
- `macos/build.nu` is a wrapper around a clean `xcodebuild` invocation, but use
  the wrapper when available so the build path stays aligned with repo
  expectations.
- The tmux child surface being strictly static/read-only in every edge case is
  still a separate behavioral proof beyond this window-creation validation.
