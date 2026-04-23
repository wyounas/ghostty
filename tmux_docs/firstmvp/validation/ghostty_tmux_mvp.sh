#!/bin/sh

set -eu

exec /opt/homebrew/bin/tmux -L ghostty_mvp -f /dev/null -CC new-session -s mvp "printf 'MVP_MARKER\n'; exec ${SHELL:-/bin/zsh} -l"
