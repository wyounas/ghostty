# Debugging Study Plan

This directory is a `main`-branch, macOS-first debugging study pack for
building a mental model of Ghostty before comparing it to tmux MVP work.

## Context

This study pack is intentionally built around the current `main` branch, not
around `tmux_mvp`.

The target environment is:

- macOS only
- the embedded/Swift apprt path
- Debug builds
- LLDB-first learning

The baseline assumption is:

- ordinary Ghostty architecture must be understood first
- tmux control mode must then be understood as a hook into that architecture
- only after that should tmux-driven surface creation or tmux MVP deltas be
  studied

Use `tmux_mvp` docs as comparison scaffolding when needed, but treat current
branch code as the source of truth.

## Problem

The problem these sessions are trying to solve is not “implement tmux support
immediately.” The problem is:

> build a correct debugger-level mental model of how Ghostty already works, so
> later tmux-control-mode work does not build on false assumptions

More concretely, these sessions are designed to answer:

- what threads exist per surface
- how mailbox and wakeup handoff works
- how input reaches the PTY write path
- how returned bytes reach parsing and rendering
- where tmux control mode enters the normal Ghostty output path
- what already exists on `main`
- what is still missing on `main`, especially the `.windows` -> app-thread GUI
  bridge

They also protect against a few common wrong mental models:

- thinking the macOS app thread is the same thing as a generic Zig main loop
- thinking ordinary tmux-in-Ghostty already uses native Ghostty child surfaces
- thinking parser/viewer code implies the GUI bridge already exists
- thinking one noisy LLDB stop proves more than the code and thread ownership
  actually prove

Start here:

- [context.md](/Users/waqas/code/ghostty_forked/debugging/context.md)
- [architecture.md](/Users/waqas/code/ghostty_forked/debugging/architecture.md)
- [architecture_brief.md](/Users/waqas/code/ghostty_forked/debugging/architecture_brief.md)

Recommended session order:

1. [s0_startup_threads/README.md](/Users/waqas/code/ghostty_forked/debugging/s0_startup_threads/README.md)
2. [s1_mailbox/README.md](/Users/waqas/code/ghostty_forked/debugging/s1_mailbox/README.md)
3. [s2_input_stack/README.md](/Users/waqas/code/ghostty_forked/debugging/s2_input_stack/README.md)
4. [s3_output_stack/README.md](/Users/waqas/code/ghostty_forked/debugging/s3_output_stack/README.md)
5. [s4_resize/README.md](/Users/waqas/code/ghostty_forked/debugging/s4_resize/README.md)
6. [s5_surface_construction_via_split/README.md](/Users/waqas/code/ghostty_forked/debugging/s5_surface_construction_via_split/README.md)
7. [s6_tmux_entry_and_viewer_startup/README.md](/Users/waqas/code/ghostty_forked/debugging/s6_tmux_entry_and_viewer_startup/README.md)
8. [s7_tmux_windows_handoff/README.md](/Users/waqas/code/ghostty_forked/debugging/s7_tmux_windows_handoff/README.md)
9. [s8_exec_vs_tmux_surface_contrast/README.md](/Users/waqas/code/ghostty_forked/debugging/s8_exec_vs_tmux_surface_contrast/README.md)

Optional current-state tmux supplements:

10. [s9a_tmux_inside_exec_write_path/README.md](/Users/waqas/code/ghostty_forked/debugging/s9a_tmux_inside_exec_write_path/README.md)
11. [s9b_tmux_inside_exec_read_path/README.md](/Users/waqas/code/ghostty_forked/debugging/s9b_tmux_inside_exec_read_path/README.md)

Use `s9a` and `s9b` after `s3` if you want to prove what current Ghostty does
with ordinary tmux **before** you study tmux control-mode scaffolding.

Legacy combined session:

- [s9_tmux_inside_exec_surface/README.md](/Users/waqas/code/ghostty_forked/debugging/s9_tmux_inside_exec_surface/README.md)

The teaching order is deliberate:

- first learn ordinary Ghostty startup, mailboxes, input, output, and resize
- then learn ordinary child-surface creation
- only then study tmux entry, `Viewer`, and the missing `.windows` bridge
