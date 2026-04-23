#!/bin/sh

set -eu

exec /opt/homebrew/bin/tmux -L ghostty_fullmvp -f /dev/null -CC attach -t fullmvp
