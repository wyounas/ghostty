#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
SESSION_DIR="$ROOT/debugging/s9_tmux_inside_exec_surface"
APP_BIN="$ROOT/macos/build/Debug/Ghostty.app/Contents/MacOS/ghostty"

if [ ! -x "$APP_BIN" ]; then
  cat <<'EOF'
Debug app not found.
Build it first with:
  zig build -Demit-macos-app=false
  macos/build.nu --scheme Ghostty --configuration Debug --action build
EOF
  exit 1
fi

LOG_PATH="$SESSION_DIR/session.log"
echo "Session: S9 ordinary tmux inside one exec-backed surface"
echo "Writing LLDB transcript to $LOG_PATH"

rm -f "$LOG_PATH"

exec script -q -F "$LOG_PATH" \
  env GHOSTTY_LOG=stderr \
  lldb --no-lldbinit -S "$SESSION_DIR/breakpoints.lldb" "$APP_BIN"
