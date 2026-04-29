#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
SESSION_DIR="$ROOT/debugging/s2_input_stack"
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
: > "$LOG_PATH"
echo "Session: S2 input stack"
echo "Writing LLDB transcript to $LOG_PATH"

GHOSTTY_LOG=stderr \
  lldb --no-lldbinit -S "$SESSION_DIR/breakpoints.lldb" "$APP_BIN" 2>&1 | tee "$LOG_PATH"
