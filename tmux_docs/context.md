# Context: Ghostty tmux Control Mode Analysis

## What This Is

This documentation captures an in-depth analysis of adding **tmux control mode** (`tmux -CC`) support to [Ghostty](https://github.com/ghostty-org/ghostty), a GPU-accelerated terminal emulator written in Zig. The goal is to make tmux windows appear as native Ghostty tabs and tmux panes as native splits — the same experience iTerm2 provides today. As of this writing, Ghostty parses the tmux control protocol and builds internal state (Terminals per pane), but the final step — creating native Surfaces from that state — is not yet wired up (the `.windows` action is dropped at a `// TODO`).

Act as a senior engineer with decades of experience with terminals, Zig, and Tmux. 

## How to Use These Docs With an LLM

1. **Start with this file** to understand what each document covers.
2. **Load `smallestmvp.md`** for the master experiment guide — it explains the full data path, threading model, and where the system breaks.
3. **Load `progress.md`** to see what's been done and what's next. (there are two, tmux_docs/progress.md and tmux_docs/firstmvp/progress.md)
4. **Load `analysis/tmux-control-mode.diff`** if you want to apply the diagnostic log changes to the Ghostty source and reproduce the instrumented runs.
5. Load other files as needed based on what you're working on (architecture, specific file details, diagrams, etc.).

The diff should be applied to Ghostty `main` branch at commit `0790937d0`.

## File Index

Please read every line of evrey document under tmux_docs/ and tmux_docs/firstmvp and tmux_docs/validation and tmux_docs/analysis.


### Root (`tmux_docs/`)

| File | Description |
|------|-------------|
| `context.md` | This file — index and context for all documentation |
| `smallestmvp.md` | Master experiment guide: instrumented Ghostty with diagnostic logs to trace tmux control mode data flow end-to-end. Explains 5 learning goals, the complete data path from tmux bytes to the dead end, the Viewer's serial request-response dance, what the Viewer builds (real Terminal instances per pane), where the system breaks (`.windows` dropped at `// TODO`), and the threading model |
| `overview.md` | Sections 1-5: first-principles explanation of tmux, the control mode protocol (`%begin`/`%end` blocks, `%output` notifications), how iTerm2 implements it as a reference, Ghostty's architecture, and current integration state |
| `overview_1_5.md` | Same content as `overview.md` (Sections 1-5) |
| `overview_6_14.md` | Sections 6-14: file-by-file source code inspection of Ghostty's tmux implementation, parser state machine details, Viewer state machine, DCS handler, stream handler glue, gap analysis of what's missing, and implementation roadmap |
| `prose.md` | File-by-file walkthrough of every relevant Ghostty source file (control.zig, viewer.zig, dcs.zig, stream_handler.zig, Parser.zig, Exec.zig, Surface.zig, backend.zig), written for engineers new to Zig and terminal internals |
| `dataflow.md` | Data flow diagrams comparing iTerm2's working tmux control mode integration with Ghostty's current partial implementation, showing where the paths diverge |
| `diagrams.md` | Technical reference diagrams: control.zig parser state machine (4 states), Viewer state machine, notification flow through the 7-file pipeline, threading model |
| `plan.md` | Engineering plan with 3 learning approaches (code reading, instrumented runs, protocol tracing), Zig/terminal primer topics, and pass/fail success criteria |
| `firstmvp.md` | Architectural analysis of the first real implementation step: wiring the `.windows` action to create native Surfaces. Covers the Backend abstraction problem — today every Surface requires a PTY subprocess (`Kind = enum { exec }`), but tmux panes need a new Backend kind that reads from the Viewer's Terminal instances |
| `subtask4.md` | Deep dive tutorial on the threading challenge: the Viewer emits `.windows` on the IO/read thread, but Surface creation must happen on the main thread. Explains Ghostty's thread model, mailbox pattern, and how to bridge the gap |
| `surfaces_and_backends.md` | Explains Ghostty's Surface and Backend abstractions from first principles — what a Surface is, what a Backend does, the current exec-only coupling, and why a new Backend kind is needed for tmux panes |
| `progress.md` | Progress tracker: branch state (`smallestmvp` off `main` at `0790937d0`), 6 modified source files with what each log addition does, experiment results, and next steps |
| `*.pdf` | PDF renders of the corresponding `.md` files (dataflow, diagrams, overview, plan, prose) |

### Analysis (`tmux_docs/analysis/`)

| File | Description |
|------|-------------|
| `postmvp.md` | April 8 enhanced Tier 2 analysis: added logging to `control.zig` (tmux protocol parser) to make `%begin`/`%end` block parsing visible. Shows the complete 7-file trace for the first time, with round-trip-by-round-trip breakdown, the `.windows` gap annotation, and comparison statistics vs the April 6 run |
| `sequence_diagram.md` | ASCII sequence diagrams showing a complete command round-trip (version query) through all 7 source files: stream_handler sends command -> Exec reads PTY -> control.zig parses block -> dcs.zig wraps notification -> viewer.zig processes response -> stream_handler sends next command. Also includes a condensed full-session view |
| `ghostty.log` | Raw Ghostty debug log from the April 8 instrumented run. Contains 365 total log lines (165 GHY-prefixed diagnostic lines across 7 source files). Can be used to verify analysis claims or as input for further analysis |
| `tmux-control-mode.diff` | Git diff of all 6 modified Zig source files (92 insertions, 8 deletions). Apply to Ghostty `main` at commit `0790937d0` with `git apply` to reproduce the instrumented build. Changes are debug log additions only — no functional changes |


There is also tmux_docs/validation containing data and infomration on how we've validated the first mvp. 