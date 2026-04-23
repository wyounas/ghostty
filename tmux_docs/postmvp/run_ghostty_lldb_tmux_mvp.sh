#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)

LLDB_CMDS="$SCRIPT_DIR/lldb_tmux_mvp_breakpoints.lldb"
GHOSTTY_BIN="$REPO_ROOT/macos/build/Debug/Ghostty.app/Contents/MacOS/ghostty"

if ! command -v lldb >/dev/null 2>&1; then
  echo "error: lldb not found in PATH" >&2
  exit 1
fi

if [ ! -f "$LLDB_CMDS" ]; then
  echo "error: breakpoint file not found: $LLDB_CMDS" >&2
  exit 1
fi

if [ ! -x "$GHOSTTY_BIN" ]; then
  echo "error: Ghostty executable not found or not executable: $GHOSTTY_BIN" >&2
  echo "build the Debug app first, then try again" >&2
  exit 1
fi

exec lldb -S "$LLDB_CMDS" "$GHOSTTY_BIN" "$@"
