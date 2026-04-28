# S0 Thread Backtraces

This directory stores raw LLDB backtraces captured during
`debugging/s0_startup_threads`, plus short interpretations of what each
backtrace proves.

Recommended format for future entries:

- one file per stop
- include the raw `thread backtrace` output first
- then add a short section:
  - `What thread am I on?`
  - `Where am I stopped?`
  - `Immediate call chain`
  - `What this proves`

Suggested naming style:

- `01_main_thread_surface_init_io_spawn.md`
- `02_renderer_thread_initial_wakeup.md`
- `03_exec_backend_read_thread_spawn.md`

The goal is not just to archive LLDB output. The goal is to build a small,
readable collection of “evidence snapshots” for the architecture walkthrough.
