#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP="/Users/waqas/code/ghostty_forked/macos/build/Debug/Ghostty.app"
TMUX_BIN="/opt/homebrew/bin/tmux"
TMUX_SOCKET="ghostty_fullmvp"
TMUX_SESSION="fullmvp"
ATTACH_LAUNCHER="$SCRIPT_DIR/ghostty_tmux_fullmvp_attach.sh"
ITERATIONS="${ITERATIONS:-5}"
WINDOW_TIMEOUT_SECONDS="${WINDOW_TIMEOUT_SECONDS:-30}"
WINDOW_SETTLE_SECONDS="${WINDOW_SETTLE_SECONDS:-1}"
CLIPBOARD_SETTLE_SECONDS="${CLIPBOARD_SETTLE_SECONDS:-1}"
INPUT_SETTLE_SECONDS="${INPUT_SETTLE_SECONDS:-1}"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

window_count() {
    count="$(osascript -e "tell application \"$APP\" to count windows" 2>/dev/null || true)"
    if [ -z "$count" ]; then
        printf '0\n'
        return 0
    fi
    printf '%s\n' "$count"
}

wait_for_window_count() {
    target="$1"
    ticks=$((WINDOW_TIMEOUT_SECONDS * 2))
    i=0
    while [ "$i" -lt "$ticks" ]; do
        if [ "$(window_count)" = "$target" ]; then
            return 0
        fi
        sleep 0.5
        i=$((i + 1))
    done
    return 1
}

quit_app() {
    osascript -e "tell application \"$APP\" to quit" >/dev/null 2>&1 || true
}

reset_tmux() {
    "$TMUX_BIN" -L "$TMUX_SOCKET" -f /dev/null kill-server >/dev/null 2>&1 || true
}

require_paths() {
    [ -d "$APP" ] || fail "Ghostty.app not found at $APP"
    [ -x "$TMUX_BIN" ] || fail "tmux not found at $TMUX_BIN"
    [ -x "$ATTACH_LAUNCHER" ] || fail "attach launcher is not executable: $ATTACH_LAUNCHER"
}

prepare_tmux_session() {
    snap_marker="$1"
    reset_tmux
    "$TMUX_BIN" -L "$TMUX_SOCKET" -f /dev/null new-session -d -s "$TMUX_SESSION" \
        "printf '$snap_marker\n'; exec ${SHELL:-/bin/zsh} -l"
}

launch_app() {
    open -na "$APP" --args \
        --quit-after-last-window-closed=true \
        --window-save-state=never \
        --initial-command="direct:$ATTACH_LAUNCHER"
}

terminal_ids() {
    osascript -e "tell application \"$APP\" to get id of every terminal" \
        | tr ',' '\n' \
        | sed 's/^ *//; s/ *$//' \
        | sed '/^$/d'
}

copy_terminal_text() {
    terminal_id="$1"
    osascript -e "tell application \"$APP\" to perform action \"write_screen_file:copy\" on terminal id \"$terminal_id\"" >/dev/null
    sleep "$CLIPBOARD_SETTLE_SECONDS"
    path="$(pbpaste)"
    [ -n "$path" ] || fail "Ghostty did not copy a screen file path for terminal $terminal_id"
    [ -f "$path" ] || fail "Ghostty copied a non-existent screen file path for terminal $terminal_id: $path"
    cat "$path"
}

send_child_input() {
    terminal_id="$1"
    marker="$2"
    osascript \
        -e "tell application \"$APP\" to input text \"$marker\" to terminal id \"$terminal_id\"" \
        -e "tell application \"$APP\" to send key \"enter\" to terminal id \"$terminal_id\"" \
        >/dev/null
}

tmux_capture() {
    "$TMUX_BIN" -L "$TMUX_SOCKET" -f /dev/null capture-pane -p -t "$TMUX_SESSION:0.0"
}

send_live_marker() {
    live_marker="$1"
    "$TMUX_BIN" -L "$TMUX_SOCKET" -f /dev/null send-keys -t "$TMUX_SESSION:0.0" \
        "printf '$live_marker\n'" C-m
}

wait_for_tmux_marker() {
    marker="$1"
    ticks=$((WINDOW_TIMEOUT_SECONDS * 2))
    i=0
    while [ "$i" -lt "$ticks" ]; do
        pane="$(tmux_capture 2>/dev/null || true)"
        if printf '%s\n' "$pane" | grep -F "$marker" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
        i=$((i + 1))
    done
    return 1
}

identify_child_terminal() {
    snap_marker="$1"
    live_marker="$2"

    ids="$(terminal_ids)"
    [ -n "$ids" ] || fail "Ghostty did not expose any terminals"

    child_id=""
    for terminal_id in $ids; do
        text="$(copy_terminal_text "$terminal_id")"
        if printf '%s\n' "$text" | grep -F "$snap_marker" >/dev/null 2>&1 &&
            ! printf '%s\n' "$text" | grep -F "$live_marker" >/dev/null 2>&1; then
            if [ -n "$child_id" ]; then
                fail "More than one terminal looked like the static tmux child"
            fi
            child_id="$terminal_id"
        fi
    done

    [ -n "$child_id" ] || fail "Could not identify the tmux child terminal from copied contents"
    printf '%s\n' "$child_id"
}

validate_iteration() {
    iteration="$1"
    snap_marker="FULLMVP_SNAP_$iteration"
    live_marker="FULLMVP_LIVE_$iteration"
    input_marker="FULLMVP_CHILD_INPUT_$iteration"

    printf '== Iteration %s ==\n' "$iteration"

    quit_app
    wait_for_window_count 0 || fail "Ghostty windows did not close before iteration $iteration"
    prepare_tmux_session "$snap_marker"
    wait_for_tmux_marker "$snap_marker" || fail "tmux source pane did not reach snapshot marker in iteration $iteration"
    launch_app

    wait_for_window_count 2 || fail "Ghostty did not reach two windows in iteration $iteration"
    sleep "$WINDOW_SETTLE_SECONDS"
    send_live_marker "$live_marker"
    wait_for_tmux_marker "$live_marker" || fail "tmux source pane did not reach live marker in iteration $iteration"

    child_id="$(identify_child_terminal "$snap_marker" "$live_marker")"
    child_text="$(copy_terminal_text "$child_id")"

    printf '%s\n' "$child_text" | grep -F "$snap_marker" >/dev/null 2>&1 ||
        fail "Child terminal missing snapshot marker in iteration $iteration"
    if printf '%s\n' "$child_text" | grep -F "$live_marker" >/dev/null 2>&1; then
        fail "Child terminal showed live marker in iteration $iteration"
    fi

    source_text="$(tmux_capture)"
    printf '%s\n' "$source_text" | grep -F "$snap_marker" >/dev/null 2>&1 ||
        fail "tmux source pane missing snapshot marker in iteration $iteration"
    printf '%s\n' "$source_text" | grep -F "$live_marker" >/dev/null 2>&1 ||
        fail "tmux source pane missing live marker in iteration $iteration"

    send_child_input "$child_id" "$input_marker"
    sleep "$INPUT_SETTLE_SECONDS"
    source_after_input="$(tmux_capture)"
    if printf '%s\n' "$source_after_input" | grep -F "$input_marker" >/dev/null 2>&1; then
        fail "Input sent to the tmux child leaked into tmux in iteration $iteration"
    fi

    printf 'child terminal id: %s\n' "$child_id"
    printf 'snapshot/static/readonly checks passed for iteration %s\n' "$iteration"

    quit_app
    wait_for_window_count 0 || fail "Ghostty windows did not close cleanly after iteration $iteration"
    reset_tmux
}

require_paths

i=1
while [ "$i" -le "$ITERATIONS" ]; do
    validate_iteration "$i"
    i=$((i + 1))
done

printf 'All %s iterations passed.\n' "$ITERATIONS"
