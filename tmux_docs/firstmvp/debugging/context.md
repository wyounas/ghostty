You are a senior engineer with deep expertise in Zig, terminal emulators,
libxev event loops, tmux control mode (`ESC P 1000 p`, `%output`,
`%layout-change`, `%window-add`, `%begin/%end`), and LLDB debugging of Zig
binaries on macOS.

I want to build a precise mental model of Ghostty's core architecture and of
where tmux control mode plugs into it. The immediate goal is not to implement
tmux work. The immediate goal is to design a sequence of focused debugging
sessions that teach the architecture with the eyes of a debugger.

## Primary baseline and scope

1. **Use `main` as the primary baseline.**
   - Treat a clean checkout of the current `main` branch as the architectural
     baseline.
   - The tmux first-MVP branch is **comparison material for later**, not the
     primary learning target.
   - Do not make branch switching, rebasing, or moving docs across branches the
     main work of this prompt.

2. **Use macOS as the only platform for this prompt.**
   - Target the macOS app build and the embedded/Swift apprt path.
   - Do not produce Linux/GTK-specific sessions unless I later ask for them.
   - The relevant runtime boundary is the macOS app plus Zig core, not the GTK
     path.

3. **This is not greenfield.**
   Ghostty already has substantial tmux control-mode scaffolding. Your job is
   to design debugging sessions that help me see:
   - what ordinary Ghostty does today,
   - where tmux control mode enters that architecture,
   - which existing code paths already work,
   - and where the real gaps are.

4. **This prompt is for planning and documentation design, not implementation.**
   - Produce an architecture brief first.
   - Stop and wait for my confirmation before generating debugging session
     directories.
   - Do not assume you should mutate code or fix bugs.

## Docs and local sources you must read first

Before producing the architecture brief, read and cite the local project docs
that materially affect the debugging plan:

- `HACKING.md`
- `AGENTS.md`
- `macos/AGENTS.md`
- `README.md`
- any relevant docs under `tmux_docs/` that explain the current tmux control
  mode analysis, especially if they are already being used as local context

Use these docs to anchor:

- build/debug behavior
- logging strategy
- the project's own terminology, especially **"input stack"**
- the macOS app build flow

Do not cite web discussions as if they were primary sources unless I later ask
for internet-backed context. Prefer the repo and local docs first.

## Priority source files to inspect

These are the high-value files you should inspect. Treat them as **priority
targets to verify**, not as infallible frozen truth:

- `src/main_ghostty.zig`
- `src/App.zig`
- `src/Surface.zig`
- `src/apprt/embedded.zig`
- `src/apprt/surface.zig`
- `src/termio.zig`
- `src/termio/Termio.zig`
- `src/termio/Thread.zig`
- `src/termio/Exec.zig`
- `src/termio/backend.zig`
- `src/termio/message.zig`
- `src/termio/stream_handler.zig`
- `src/terminal/Parser.zig`
- `src/terminal/stream.zig`
- `src/terminal/dcs.zig`
- `src/terminal/Terminal.zig`
- `src/terminal/tmux/control.zig`
- `src/terminal/tmux/viewer.zig`
- `src/terminal/tmux/layout.zig`
- `src/terminal/tmux/output.zig`
- `src/renderer.zig`
- `src/renderer/Thread.zig`
- `src/renderer/State.zig`
- `src/Command.zig`
- `src/pty.zig`

Important correction:

- `src/terminal/tmux/output.zig` is about parsing tmux command output into typed
  data. Do **not** describe it as the place that routes live `%output`
  notifications to panes unless the current code proves that claim.

## Verification discipline

1. **Do not present unverified details as confirmed facts.**
   - File paths are usually stable; line numbers are not.
   - If a line number matters, verify it against the current `main` branch.
   - If a symbol location is uncertain, say so and explain how to confirm it.

2. **Separate three kinds of truth in your brief.**
   - verified from code
   - inferred from code structure
   - still uncertain and needs later confirmation

3. **Separate Ghostty-general architecture from tmux-specific architecture.**
   For example:
   - thread topology, mailbox flow, renderer mutex, input stack: Ghostty-general
   - DCS `1000 p`, `ControlParser`, `Viewer`, tmux action flow:
     tmux-control-specific

4. **Do not freeze approximate source locations into the prompt unless the exact
   line is essential.**
   Prefer:
   - "verify the current line number on `main`"
   over:
   - "line 688 definitely does X"

## Build and run assumptions for this prompt

This prompt is macOS-first. Use the repo's actual macOS guidance.

1. **Debug build expectation**
   - `zig build` without `-Doptimize` is a Debug build.
   - Debug builds are slow. Slow startup alone is not a bug.

2. **Canonical macOS app build path**
   - If code outside `macos/` changed, first run:
     `zig build -Demit-macos-app=false`
   - Then build the app with:
     `macos/build.nu --scheme Ghostty --configuration Debug --action build`
   - Use direct `xcodebuild` only as a fallback if `nu` is unavailable.

3. **Canonical runnable target**
   - Target the built app bundle:
     `macos/build/Debug/Ghostty.app`
   - The executable you debug is typically:
     `macos/build/Debug/Ghostty.app/Contents/MacOS/ghostty`
   - Do not assume the primary debug target is `zig-out/bin/ghostty`.

4. **Logging**
   - Use `GHOSTTY_LOG` intentionally.
   - On Debug builds, `stderr` logging is useful.
   - On macOS, unified logging also exists.
   - Where logs teach the same concept more cheaply than an LLDB breakpoint,
     recommend logs instead.

## Zig + LLDB rules

Apply these to every session, but only emphasize the ones that materially affect
that session:

- symbol lookup may need regex or image lookup; do not guess mangled names
- optionals and tagged unions may print poorly in stock LLDB
- `comptime` code has no runtime instructions; do not set breakpoints there
- small and inline functions may not bind cleanly; break at a verified call site
  if needed
- libxev callbacks appear as loop-driven callbacks, not always with intuitive
  "caller" stacks
- on macOS, backtraces for user input start in Swift / Objective-C frames before
  crossing into Zig

## Breakpoint hygiene

These rules are non-negotiable:

1. Every breakpoint in every `.lldb` file must be preceded by a one-line
   pedagogical comment:
   - what concept does stopping here teach me?

2. Use **stopping breakpoints** for low-frequency lifecycle moments:
   - app init
   - first surface init
   - thread spawn
   - new child surface creation

3. Use **logging or auto-continue breakpoints** on hot paths:
   - parser byte handling
   - IO thread dispatch
   - renderer callback
   - frequent termio message processing

4. Prefer conditional breakpoints and one-shot breakpoints where possible.

5. If `GHOSTTY_LOG` would teach the same thing more clearly and cheaply, prefer
   logging over a breakpoint.

## Architecture brief: required topics

Before you propose any session directories, write a concise architecture brief
that confirms or corrects the following on the current `main` branch.

Keep it short, but cite real file:line references verified on `main`.

You must confirm or correct:

1. **Per-surface thread topology**
   - app/main thread
   - one IO thread
   - one renderer thread
   - whether exec-backed surfaces also have a separate PTY read thread, and how
     it differs from the IO thread

2. **Mailbox mechanics**
   - where the queue primitive lives
   - how wakeup reaches the receiving thread
   - which parts are app-thread mailboxes versus termio-thread mailboxes

3. **Renderer state mutex handoff**
   - who mutates terminal state
   - who reads terminal state for rendering
   - when the renderer locks, snapshots, unlocks, and draws

4. **Renderer trigger model**
   - wakeup on dirty/IO activity
   - timer-driven work such as cursor blink or animation

5. **Input stack**
   - apprt OS event
   - `KeyEvent`
   - `App` / `Surface.keyCallback`
   - keybinding/action path versus PTY write path

6. **DCS / tmux hook**
   - where `ESC P 1000 p` is recognized
   - how subsequent bytes flow into the tmux control parser
   - how notifications flow into the Viewer

7. **Where tmux exits general Ghostty architecture and becomes tmux-specific**
   - `dcs.zig`
   - tmux control parser
   - Viewer
   - stream-handler action handoff

If any part of my framing is wrong, correct it in the brief before designing
sessions.

## Deliverables after the architecture brief is approved

After I approve the architecture brief, generate:

- `tmux_docs/debugging/architecture_brief.md`
- one subdirectory per approved session:
  - `s0_startup_threads/`
  - `s1_mailbox/`
  - etc.

Each session directory should contain:

- `README.md`
- `breakpoints.lldb`
- `commands.md`
- `run.sh`
- `transcript_template.md`

### Session file expectations

`README.md`
- learning objectives
- 3–5 success-criteria questions I should be able to answer afterward
- prerequisites
- realistic expected duration
- exact run instructions
- what the session does **not** cover

`breakpoints.lldb`
- comments before every breakpoint
- conditions / one-shot behavior where useful
- auto-continue traces where hot-path stopping would be noisy

`commands.md`
- only LLDB commands relevant to that session
- include Zig/macOS gotchas only if they affect that session
- not a generic LLDB cheat sheet

`run.sh`
- POSIX shell
- macOS-oriented by default
- verify the Debug app bundle exists
- if needed, tell the user exactly which build command to run first
- source `breakpoints.lldb`
- use `GHOSTTY_LOG` deliberately where useful
- tee debugger output to `session.log`
- do **not** invent Ghostty CLI flags or config syntax; verify them first

`transcript_template.md`
- a structured place for me to record observations against the session's
  success criteria

## Session ordering

Unless source inspection gives a strong reason to adjust it, use this teaching
order:

**S0 — Startup, thread topology, and initial Surface**
- app init
- first `Surface` construction
- IO thread spawn
- renderer thread spawn
- mailbox wiring
- event-loop start

Success:
- I can draw the per-surface thread diagram from memory.

**S1 — Mailbox mechanics in isolation**
- trigger one benign cross-thread message
- watch enqueue, wakeup, drain, and message dispatch

Success:
- I can explain the queue + wakeup pattern in one paragraph.

**S2 — Input stack: user types `ls` (no Enter)**
- trace one keystroke from apprt callback to PTY write
- answer the local-echo question

Success:
- I can name every important function from key event to PTY write.

**S3 — Output stack: `ls\n` and shell response**
- trace bytes from PTY read through parsing to terminal mutation and render

Success:
- I can state the IO -> renderer handoff and the renderer trigger model.

**S4 — Resize / SIGWINCH propagation**
- trace one resize through apprt, surface, termio/backend, PTY, terminal, and
  renderer

Success:
- I can list every component that learns about a resize, in order.

**S5 — Surface construction via split**
- use a normal split/new surface as the existing analogue of child-surface
  creation

Success:
- I can list every major step for an ordinary child surface.

**S6 — tmux control mode entry and Viewer startup**
- DCS hook
- control parser
- Viewer creation
- startup handshake
- command queue

Success:
- I can explain how tmux data first enters Ghostty and when the Viewer becomes
  active.

**S7 — tmux `.windows` and the app-thread handoff**
- where the Viewer emits actions
- where stream handler receives `.windows`
- what happens next on `main`

Success:
- I can explain exactly where tmux-discovered structure would have to cross into
  app/runtime surface creation.

**S8 — Contrast session: what a tmux-backed surface would replace**
- use S5 as the baseline
- list which ordinary exec/PTy steps would be skipped or replaced for a
  tmux-backed surface

Success:
- I can write a concrete replacement table:
  exec/PTy path versus tmux-driven path.

This order is deliberate:

- first learn ordinary Ghostty
- then learn where tmux control mode hooks in
- only then discuss how tmux-backed surfaces differ

## Additional sessions

Only propose extra sessions if they are genuinely necessary and you can justify
them in one sentence each.

Good reasons:
- the source shows a concept is too large for one session
- one session would otherwise mix unrelated mental models

Do not pad the plan.

## What not to do

- Do not treat the tmux MVP branch as the primary baseline.
- Do not mix Linux/GTK and macOS/embedded instructions in the same session.
- Do not invent unverified Ghostty CLI flags.
- Do not hard-code stale line numbers without verifying them.
- Do not overuse stopping breakpoints on hot paths.
- Do not produce session directories until I approve the architecture brief.

## Comparison policy for later

If later I ask for comparison against a tmux MVP branch, reuse the same session
structure and add delta notes:

- what changed in backend selection
- what changed in app-thread handoff
- what changed in surface creation
- what changed in snapshot/live-output routing

But that comparison comes **after** the `main`-branch architecture is clear.

## Final instructions

- Use the project's own terminology:
  `input stack`, `apprt`, `Surface`, `Termio`, `renderer state mutex`,
  `ControlParser`, `Viewer`
- cite file:line for every claim
- if a line number is uncertain, say so and explain how to confirm it
- if my framing is wrong, push back
- produce the architecture brief first
- stop and wait for confirmation before generating the session directories
