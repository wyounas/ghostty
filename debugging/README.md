# Debugging Study Plan

This directory is a `main`-branch, macOS-first debugging study pack for
building a mental model of Ghostty before comparing it to tmux MVP work.

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
