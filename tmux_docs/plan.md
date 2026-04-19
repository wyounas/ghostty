# Engineering Plan: Understanding Ghostty's Codebase for tmux Control Mode Integration

> **Revision: 3 (final)**
>
> **Revision history:**
>
> - **Revision 1:** Fixed all command examples to use actual CLI syntax instead of
>   spelled-out words (e.g., `tmux -C` instead of "tmux minus-C"). Added tmux session
>   cleanup instructions after experiments. Added approximate qualifiers to line-number
>   references since they may shift. Made Approach 3 Milestone 2 less verbose (described
>   the notification naturally instead of listing individual bytes). Added more specific
>   guidance for Approach 2 Milestone 5 on how to access Viewer internals in Zig.
>
> - **Revision 2:** Added five missing primer topics to Part B: TERM environment variable,
>   Renderer, Zig error handling, Zig optional types, and Zig slices. Made Approach 2
>   success criteria more concrete (specific log line patterns to expect). Made Approach 3
>   Milestone 3 step 5 more specific about what to look for in stream handler communication.
>   Added Zig-specific orientation notes to the primer since the audience is new to Zig.
>
> - **Revision 3:** Added a "Before You Begin" prerequisites section. Added a "Which
>   Approach to Start With" recommendation. Added a "Combining Approaches" section at the
>   end of Part A. Tightened success criteria throughout to be pass/fail checkable. Added a
>   note about the relationship between the three approaches (they are not mutually
>   exclusive). Reordered Part B primer entries to flow from most fundamental to most
>   specific.

## Goal

Help a junior engineer understand all parts of the Ghostty codebase that will be touched by a Ghostty + tmux control mode integration. The engineer is new to Zig and has never worked on terminals or terminal emulators.

---

## Before You Begin

**Prerequisites you need before starting any approach:**

1. A macOS or Linux machine with at least 8 GB of RAM and 20 GB of free disk space.
2. Zig installed (version matching the Ghostty build requirements — check the repository's build documentation).
3. The Ghostty repository cloned locally.
4. A text editor you are comfortable with. Any editor works, but one with Zig syntax highlighting will help (VS Code with the Zig extension, or Neovim with tree-sitter).
5. tmux installed. On macOS: `brew install tmux`. On Linux: your package manager's tmux package. Verify with `tmux -V`.
6. Basic comfort with the command line: navigating directories, running commands, reading output.

**Which approach to start with:**

- If you are making architectural decisions or need to understand the full scope before touching code, start with **Approach 1** (Top-Down Reading).
- If you learn best by doing and have a working build environment, start with **Approach 2** (Bottom-Up Instrumentation). This is the recommended default for most engineers.
- If you already have some orientation from reading the overview documents and want to go deep fast, start with **Approach 3** (Trace-a-Feature).

These approaches are not mutually exclusive. Most engineers will benefit from combining them: start with one, then switch to another when you hit a plateau. For example, you might start with Approach 2 (run experiments, observe logs), then switch to Approach 1 (read the architecture) when you want to understand why something works the way it does, then use Approach 3 (trace a specific flow) when you need to understand the exact mechanism at an integration boundary.

---

## Part A: Three Learning Approaches

### Approach 1: Top-Down Reading ("Understand the Architecture First")

**When to choose this approach:** Choose this when you are the kind of learner who needs to see the big picture before any details make sense. If you find yourself asking "but why does this exist?" when reading unfamiliar code, start here. This approach is also the right choice if you are going to be making architectural decisions (like designing the new tmux backend) rather than implementing within an existing design.

**Why it works:** The tmux control mode integration spans five layers of the Ghostty codebase: protocol parsing, semantic state management, integration glue, terminal I/O, and GUI. Reading top-down gives you a mental map of how data flows through these layers before you get lost in the details of any one layer. You will know what each file is for and why it exists before you read a single line of its implementation.

#### Milestone 1: Understand the product and protocol

**Steps:**

1. Read the tmux wiki page on Control Mode at https://github.com/tmux/tmux/wiki/Control-Mode. Read it completely, not skimming. Pay attention to the list of notification types, the escaping rules, and the flow control mechanism.

2. In any terminal, start control mode with echo enabled:
   ```
   tmux -C new-session -s test
   ```
   This gives you human-readable control mode. Type `list-windows` and press Enter. Observe the `%begin` line, the output line, and the `%end` line. Type `list-panes` and observe. Type `display-message -p '#{version}'` and observe.

3. Open a second terminal window and attach to the same session:
   ```
   tmux attach -t test
   ```
   Type some commands (like `echo hello`). Go back to the control mode terminal and observe the `%output` lines that appeared.

4. In the attached session, run `tmux split-window`. Go back to the control mode terminal and observe the `%layout-change` notification. Note how the layout string changed to include a second pane.

5. Write down, in your own words, a list of the notification types you observed and what each one means.

6. Clean up when done: in the control mode terminal, type `kill-session` and press Enter, or press Ctrl-C. Verify the session is gone with `tmux list-sessions`.

**Success criterion:** You can explain to another engineer, without notes, what tmux control mode is, what the protocol looks like, and how a terminal emulator would use it to create native tabs and splits. You can describe the difference between `%output` (live pane data), `%begin`/`%end` blocks (command responses), and async notifications (`%layout-change`, `%window-add`, etc.).

#### Milestone 2: Understand the data flow through Ghostty

**Steps:**

1. Read the `diagrams.md` file in the repository root, focusing on the "Data flow: DCS bytes to screen pixels" diagram. Trace the path from tmux server through `dcs.zig`, `control.zig`, `stream_handler.zig`, `viewer.zig`, and the TODO gap.

2. Read `src/terminal/tmux.zig` (the module re-export file, about 14 lines). Note which types are exported and from which files.

3. Read `src/terminal/main.zig` around line 26 to find the conditional export. Understand that the tmux module only exists when `tmux_control_mode` is true.

4. Read `src/terminal/build_options.zig` around line 46 to see that `tmux_control_mode` is tied to Oniguruma availability.

5. Draw your own diagram (on paper or whiteboard) showing how bytes flow from the tmux process to the Viewer, labeling each file and the data type passed between them.

**Success criterion:** You can draw, from memory, the pipeline from tmux bytes to the Viewer's `.windows` action, naming each file and the type that crosses each boundary (bytes into `dcs.zig`, Notification into `stream_handler.zig`, Action from `viewer.zig`). You can point to the exact file and the specific action variant where the pipeline breaks.

#### Milestone 3: Read each file's public interface

**Steps:**

1. Open `src/terminal/tmux/control.zig`. Read only the Notification union definition (search for `pub const Notification`) and the Parser struct definition (near the top). Do not read the implementation of `put` or `parseNotification` yet. Write down what notification types exist and what data each variant carries.

2. Open `src/terminal/tmux/layout.zig`. Read only the Layout struct definition and its Content union. Write down the three possible content types (pane, horizontal, vertical) and what fields each has.

3. Open `src/terminal/tmux/output.zig`. Read only the Variable enum and the `FormatStruct` function signature. Write down what kinds of tmux state the output parser can extract (cursor info, terminal modes, IDs, etc.).

4. Open `src/terminal/tmux/viewer.zig`. Read the State enum, the Action union, the Window struct, and the Pane struct. Read the ASCII lifecycle diagram (search for the large comment block near the top, approximately lines 55-144) carefully. Write down the four Viewer states and what triggers transitions between them.

5. Open `src/termio/stream_handler.zig`. Search for the tmux DCS handling section (approximately lines 389-461). Write down what happens for each notification type (enter, exit, other) and each action type (command, windows, exit).

6. Open `src/termio/backend.zig`. Read the Kind enum and Backend union. Note that there is only `exec` today.

**Success criterion:** You have a written summary (your own notes, not copied) of each file's public interface: what types it defines, what they represent, and how they connect to the types in adjacent files. You have identified the exact code location where the `.windows` action is dropped with a TODO comment.

#### Milestone 4: Read implementations with purpose

**Steps:**

1. In `control.zig`, read the `put` method (the main parsing loop). Trace the state transitions: idle receives a `%` byte and transitions to notification; notification accumulates bytes until a newline and calls `parseNotification`; `parseNotification` dispatches based on the notification name; `%begin` transitions to block state; block accumulates lines until a valid guard line is found.

2. In `viewer.zig`, read the `next` method (main dispatch), then `nextStartupBlock`, `nextStartupSession`, and `nextCommand`. For `nextCommand`, trace what happens when each command type's response arrives: `tmux_version` stores the version, `list_windows` triggers `syncLayouts`, `pane_history` feeds content to a Terminal, and so on.

3. In `viewer.zig`, read `syncLayouts` (how the Viewer reconciles its internal pane map with a new layout tree) and `initLayout` (how it creates Terminal instances for new panes and queues capture commands).

4. Read the tests in `viewer.zig` (search for `test "` to find them — they start approximately at line 1496). These are the best documentation of expected behavior. Read at least the "initial flow" test and the "two pane flow with pane state" test completely.

**Success criterion:** You can explain, step by step, what happens from the moment Ghostty detects `ESC P 1000 p` to the moment the Viewer has a fully initialized Terminal for each pane, including every command sent to tmux and every response processed. You can explain what `syncLayouts` does when a layout change adds a new pane: it walks the new layout tree, creates Terminal instances for pane IDs that did not previously exist, removes panes that are no longer in the layout, and queues capture-pane commands for the new panes.

---

### Approach 2: Bottom-Up Instrumentation ("Run It and Watch What Happens")

**When to choose this approach:** Choose this when you learn best by doing, not by reading. If abstract explanations do not stick until you have seen the concrete behavior, start here. This approach is particularly good if you have access to a Ghostty build environment and can compile and run Ghostty locally.

**Why it works:** The tmux control mode pipeline already works internally — the parser parses, the Viewer discovers windows and panes, the command queue sends and receives commands. You just cannot see any of it from the GUI because the `.windows` action is dropped. By adding logging and running experiments, you can observe the entire pipeline in action and build your understanding from concrete observations.

#### Milestone 1: Set up the development environment

**Steps:**

1. Clone the Ghostty repository and build it from source. Follow the build instructions in the repository's documentation. You need a working Ghostty binary that you can run from the command line.

2. Verify your build by running the Ghostty binary from a terminal. A Ghostty window should open. Type a command like `echo hello` in it to verify it works as a normal terminal.

3. Install tmux if it is not already installed. On macOS: `brew install tmux`. Verify with `tmux -V`.

4. Verify the test suite works:
   ```
   zig build test -Dtest-filter="tmux"
   ```
   All tmux-related tests should pass. If you see errors about Oniguruma, check the build documentation for how to install dependencies.

**Success criterion:** You have a working Ghostty build, tmux is installed, and `zig build test -Dtest-filter="tmux"` passes with no failures.

#### Milestone 2: Observe the control mode protocol directly

**Steps:**

1. In any terminal, create a detached tmux session:
   ```
   tmux new-session -d -s experiment
   ```

2. Start control mode with echo enabled:
   ```
   tmux -C attach -t experiment
   ```
   You will see protocol messages printed as plain text.

3. Observe the initial output: a `%begin`/`%end` block (the startup block) and a `%session-changed` notification.

4. Type `list-windows` and press Enter. Observe the `%begin` line (with timestamp, command number, and flags), the output line (containing session ID, window ID, dimensions, and layout string), and the `%end` line.

5. Open a second terminal and attach to the same session normally:
   ```
   tmux attach -t experiment
   ```
   In that terminal, type `echo hello`. Go back to the control mode terminal and observe the `%output` line.

6. In the attached session, run `tmux split-window`. Go back to the control mode terminal and observe the `%layout-change` notification. Note how the layout string changed to include a second pane.

7. In the attached session, run `tmux new-window`. Observe the `%window-add` notification in the control mode terminal.

8. Clean up: in the control mode terminal, type `kill-server` or `kill-session -t experiment`, or just press Ctrl-C and then run `tmux kill-session -t experiment` from a normal terminal.

**Success criterion:** You have seen every major notification type in the raw protocol: `%begin`/`%end` blocks, `%session-changed`, `%output`, `%layout-change`, `%window-add`. You can correlate tmux operations (split, new window, typing) to specific protocol messages.

#### Milestone 3: Observe Ghostty's internal processing

**Steps:**

1. Open two terminal windows (these can be in any terminal, not necessarily Ghostty).

2. In Terminal A, launch Ghostty from the command line with log output visible:
   ```
   /path/to/ghostty 2>&1 | grep -i tmux
   ```
   Replace `/path/to/ghostty` with the actual path to your built Ghostty binary (likely `./zig-out/bin/ghostty` or `/Applications/Ghostty.app/Contents/MacOS/ghostty`). This filters for tmux-related log lines only.

3. In the Ghostty window that opens, run:
   ```
   tmux -CC new-session -s logtest
   ```
   Note the double C — this uses DCS framing, which Ghostty will detect.

4. Watch Terminal A. You should see log lines containing phrases like "tmux control mode event", "tmux viewer action", or notification type names. These indicate that DCS detection, notification parsing, and Viewer processing are all working.

5. If you see log lines mentioning the Viewer and actions, the entire pipeline from DCS detection through parsing through the Viewer is working. The Ghostty window will appear to hang or show nothing because the `.windows` action is not acted upon.

6. In a third terminal, attach to the session normally:
   ```
   tmux attach -t logtest
   ```
   Type some commands and observe new log lines appearing in Terminal A (these are `%output` notifications being processed). Run `tmux split-window` and observe `%layout-change` log lines.

7. Clean up: detach from tmux (`Ctrl-b d`), then `tmux kill-session -t logtest`.

**Success criterion:** You have seen Ghostty's internal tmux processing in action via log output. You saw log lines for DCS detection, for notifications being received by the Viewer, and for actions being emitted. You understand concretely that the pipeline works internally but produces no visible result because the `.windows` action has no handler.

#### Milestone 4: Instrument the code to see deeper state

**Steps:**

1. Open `src/termio/stream_handler.zig` and find the `.windows` action handler (the TODO). Replace the TODO with a temporary log statement. For example, inside the `.windows` branch, add a line that logs the number of windows received. The exact Zig syntax will be something like calling `log.info` with a format string and the length of the windows slice. Rebuild Ghostty.

2. Repeat the experiment from Milestone 3. Now you should see a log line showing the actual number of windows that the Viewer discovered.

3. Open `src/terminal/tmux/viewer.zig` and find the `nextCommand` method. Add temporary log statements at each command type's handler (`list_windows`, `pane_history`, `pane_visible`, `pane_state`, `tmux_version`). Look for the switch statement on the command type. At the top of each branch, add a `log.info` call. Rebuild and run again.

4. Now you can see the complete command sequence in the logs: version query, window list, capture-pane for each pane (four times: primary scrollback, primary visible, alternate scrollback, alternate visible), and list-panes for terminal state.

5. Find the `receivedOutput` method in `viewer.zig` and add a temporary log statement that prints the pane ID and the length of the data received. This lets you see live output routing.

6. Rebuild, run the experiment one more time, and type commands in the attached tmux session. Confirm you see output routing log lines.

**Success criterion:** You have added instrumentation to every major stage of the pipeline (DCS detection, notification parsing, Viewer command processing, output routing, windows action emission) and observed data flowing through each stage in the logs. You can describe the complete startup sequence based on your log observations: DCS detected, Viewer created, initial block received, session-changed received, version queried, windows listed, captures performed, state synced.

#### Milestone 5: Use the test framework as an exploration tool

**Steps:**

1. Open `src/terminal/tmux/viewer.zig` and search for `test "initial flow"`. Read the test. Understand the TestStep structure: each step has input data (bytes simulating what tmux sends), expected actions, and optional check callbacks. The `testViewer` function drives the Viewer through the steps and verifies behavior.

2. Add your own check callback to the last step of the "initial flow" test. In Zig, a check callback is a function pointer. The existing tests show the pattern: you define a struct with a `check` function and reference it with a `.check = (struct { fn check(...) ... }).check` pattern. In your callback, access the Viewer's panes hash map by calling `v.panes.count()` to see how many panes exist. Use `std.debug.print` to print the count.

3. Run the specific test:
   ```
   zig build test -Dtest-filter="initial flow"
   ```
   Observe your debug output. It will be printed to stderr during the test run.

4. Create your own test case modeled after the existing tests. Start with a simple scenario: simulate a `%window-add` notification followed by a `list-windows` response showing two windows. Copy the TestStep structure from an existing test and modify the input bytes and expected actions. Verify that the Viewer emits a `.windows` action with two windows.

5. Create a second test case that simulates a `%layout-change` notification adding a second pane to an existing window. Verify the Viewer creates a new Terminal instance for the new pane by checking the pane count in a check callback.

**Success criterion:** You have used the Viewer's test framework to observe internal state and to construct your own scenarios. You can create a TestStep sequence for any scenario you want to explore, run it, and inspect the resulting Viewer state via check callbacks.

---

### Approach 3: Trace-a-Feature ("Follow One Byte Through the Entire System")

**When to choose this approach:** Choose this when you already have some orientation (perhaps from skimming the overview documents or completing a few milestones from another approach) but need to go deep on one specific flow to understand how the layers actually connect. This approach is especially good for understanding the integration boundary where the current implementation breaks down.

**Why it works:** Instead of trying to understand everything at once, you pick one concrete scenario and trace it through every layer of the code. This gives you deep understanding of the specific mechanisms (function calls, data transformations, thread boundaries) that connect the layers, which is exactly what you need to implement the GUI glue.

#### Milestone 1: Trace the DCS detection path

**Steps:**

1. Open `src/terminal/dcs.zig`. Find the `tryHook` function. Read it to understand: what parameters does it check? (parameter 1000, final byte `p`). What does it do when it matches? (Creates a `control.Parser`, returns an `.enter` notification). What is the return type?

2. Search the codebase for where `tryHook` is called. Use grep or your editor's search to find the call site. It will be in the broader VT parser infrastructure when a DCS sequence is encountered. Note the calling function and file.

3. Now read the `put` method in the same Handler struct. This is called for each subsequent byte after the DCS hook. It delegates to the tmux control Parser's `put` method. Note how it returns an optional Notification (in Zig, this is written as `?Notification` — a value that is either a Notification or null).

4. Read the `unhook` method. This is called when the DCS String Terminator (`ESC \`) arrives. It tears down the Parser and returns an `.exit` notification.

5. Write a one-paragraph summary in your own words: "When tmux sends `ESC P 1000 p`, the `tryHook` function in `dcs.zig` detects it and creates a tmux Parser. Subsequent bytes are routed to that Parser via `put`. When `ESC \` arrives, `unhook` destroys the Parser and emits `.exit`."

**Success criterion:** You can explain, citing specific function names and return types, how Ghostty transitions from general VT parsing into tmux control mode parsing and back again. You can name the three functions involved (tryHook, put, unhook) and what each returns.

#### Milestone 2: Trace one %output notification end-to-end

**Steps:**

1. Start at `control.zig`. Consider the notification `%output %0 hello\015\012` arriving as a stream of bytes terminated by a newline. Trace through the `put` method: the `%` byte transitions from idle to notification state. Each subsequent byte is accumulated in the buffer. The newline triggers `parseNotification`.

2. In `parseNotification`, find the branch that handles `%output`. It uses a regex to extract the pane ID (0) and the escaped data (`hello\015\012`).

3. The parsed Notification (variant: `.output`, carrying the pane ID and the escaped string) is returned from the Parser.

4. Now move to `stream_handler.zig`. The `dcsCommand` method receives this Notification and passes it to `viewer.next()` with the notification wrapped in an Input value.

5. In `viewer.zig`, `next` dispatches to `nextTmux`, which dispatches to `nextCommand` (assuming the Viewer is in the `command_queue` state). `nextCommand` checks if the notification is the `.output` variant and calls `receivedOutput`.

6. In `receivedOutput`, find where the pane is looked up by ID in the panes hash map. The escaped data is decoded: `\015` becomes a carriage return byte (0x0D), `\012` becomes a line feed byte (0x0A). The decoded bytes are fed into the pane's Terminal via its VT stream parser.

7. The Terminal processes these bytes and updates its screen buffer. The text "hello" appears in the buffer, followed by a cursor return to column zero and an advance to the next line.

**Success criterion:** You can trace one `%output` notification from raw bytes arriving at `control.zig` through every function call to the point where the decoded content appears in a Terminal's screen buffer. You can name every function in the chain: `Parser.put` -> `parseNotification` -> (returned to caller) -> `stream_handler.dcsCommand` -> `Viewer.next` -> `nextTmux` -> `nextCommand` -> `receivedOutput` -> Terminal VT stream.

#### Milestone 3: Trace the .windows action to the gap

**Steps:**

1. In `viewer.zig`, search for where the `.windows` action is created. It happens in at least two places: after `receivedListWindows` completes (during initial sync or after a `%window-add`), and after `layoutChanged` completes (when a `%layout-change` notification arrives). In both cases, the Viewer creates an Action with the `.windows` variant containing the current array of Window structs.

2. The Action is returned from the `next` method to the caller.

3. In `stream_handler.zig`, find the action processing loop (search for where it iterates over actions returned by `viewer.next`). It processes each action by switching on the variant.

4. Find the `.windows` branch. It contains a TODO comment and no implementation. This is the gap.

5. Now examine how the stream handler communicates with the rest of Ghostty. Look at what fields and methods are available on the stream handler's `self` parameter. It has access to a `termio` reference (for sending messages to the I/O thread) and can reach the surface's application runtime methods. Note specifically how the `.command` action handler sends data: it calls a write request method. This shows the pattern for how the stream handler communicates outward.

6. Read `src/termio/backend.zig` and note that Kind only has `exec`. A tmux-backed surface would need a different kind.

7. Read `src/apprt/action.zig` and search for `new_tab` and `new_split` action variants. These are the kinds of operations that the stream handler would need to trigger to create native GUI elements from tmux windows and panes.

**Success criterion:** You can explain exactly what the stream handler receives from the Viewer (an array of Window structs, each containing an ID, dimensions, and a Layout tree with pane IDs), where it currently drops this information (the TODO in the `.windows` branch), and what it would need to do with it (create apprt surfaces backed by a tmux backend). You can identify the three specific architectural changes needed: (1) a new Backend kind in `backend.zig`, (2) a way to create surfaces without subprocesses in the apprt layer, and (3) a communication channel between the parent surface's Viewer and the child surfaces for input routing and output delivery.

#### Milestone 4: Trace the command send path (the reverse direction)

**Steps:**

1. In `viewer.zig`, find where a `.command` action is created. For example, after startup completes, the Viewer creates a command action containing the string `display-message -p '#{version}'\n`.

2. This Action is returned from `next` to the stream handler.

3. In `stream_handler.zig`, find the `.command` action handler. It calls a write request method that queues the command string to be sent to the tmux process's standard input.

4. Trace the write request through the termio message system. The command string is packaged as a write request message, sent to the I/O thread, and written to the PTY file descriptor that connects to the tmux process. tmux, running as a subprocess, reads this on its standard input.

5. tmux processes the command and sends back a `%begin`/`%end` response block, which arrives as bytes on the PTY's read side, re-enters the VT parser, gets routed to `dcs.zig`, then to `control.zig`, and becomes a `block_end` Notification — completing the round-trip.

**Success criterion:** You can describe the full bidirectional communication loop: Viewer emits `.command` actions, stream handler sends them to tmux via write requests to the PTY, tmux sends responses as `%begin`/`%end` blocks, those bytes flow back through the parser pipeline into `block_end` Notifications, the Viewer processes the response and may emit further actions. You can trace one complete round-trip, naming the function or mechanism at each step.

---

### Combining Approaches

After completing the milestones of one approach, you will have strong understanding of one dimension of the system. To build complete understanding:

- If you did **Approach 1** (read the architecture), now do **Approach 2 Milestones 2-3** (run experiments) to ground your abstract understanding in concrete observations.
- If you did **Approach 2** (instrumented experiments), now do **Approach 1 Milestone 4** (read implementations) to understand the "why" behind the behaviors you observed.
- If you did **Approach 3** (traced specific flows), now do **Approach 1 Milestones 1-2** (product context and data flow) to understand how your traced flows fit into the bigger picture.

The ultimate test of understanding: you should be able to explain to the project maintainer exactly what happens today when someone runs `tmux -CC` in Ghostty, why nothing visible results from it, what architectural changes are needed to make it work, and what the first meaningful step would be.

---

## Part B: Terminal and Tooling Primer

This section explains every concept, term, and tool that someone new to terminals would need for this integration. Each explanation is pitched at an engineer who is technically strong (comfortable with systems programming, data structures, state machines) but has no terminal or Zig background.

The entries are ordered from most fundamental to most specific.

### Terminal Emulator

A terminal emulator is a program that pretends to be a hardware terminal from the 1970s-1980s. Back then, you interacted with a computer through a physical device: a screen and a keyboard connected via a serial line. The computer sent characters and control codes down the serial line; the terminal displayed them. The terminal sent keystrokes back up the serial line.

A terminal emulator does the same thing in software. It creates a window on your screen, runs a shell (like zsh or bash) as a child process, and connects to that child process through a pseudoterminal. The shell thinks it is talking to a real terminal. The terminal emulator renders the output and sends keystrokes.

Ghostty is a terminal emulator. So are iTerm2, Alacritty, kitty, and Windows Terminal. Understanding that Ghostty is fundamentally a "screen plus keyboard pretending to be a 1970s terminal" is essential context for everything that follows.

### PTY (Pseudoterminal)

A pseudoterminal, or PTY, is an operating system facility that creates a pair of connected file descriptors that behave like the two ends of a serial line to a hardware terminal. One end is called the master (or controller), and the other is called the slave (or secondary).

The terminal emulator holds the master end. The child process (the shell) holds the slave end. When the shell writes bytes to its stdout, those bytes appear on the master end for the terminal emulator to read and render. When the terminal emulator writes bytes to the master end (representing keystrokes), those bytes appear on the shell's stdin.

The PTY also handles some processing automatically: it translates between the terminal's raw byte stream and the kernel's line-editing mode, it manages terminal attributes (baud rate, character size, and many other settings from the serial terminal era), and it sends signals (like SIGWINCH for window size changes) to the child process.

In Ghostty, the Exec backend (`src/termio/Exec.zig`) creates and manages PTYs. For tmux control mode, the parent surface has a PTY (tmux runs as a child process in it), but tmux-backed child surfaces would not have their own PTYs — they get their content through the tmux control mode protocol instead.

### VT Sequences (Terminal Escape Sequences)

When a program running in a terminal wants to do more than just print plain text — move the cursor, change colors, clear the screen, switch to an alternate screen buffer — it sends special byte sequences called escape sequences, VT sequences, or control sequences. They are called "VT" after the DEC VT100 terminal, which standardized many of them.

An escape sequence starts with the ESC byte (0x1B, decimal 27). What follows depends on the type of sequence:

- A **CSI** (Control Sequence Introducer) sequence starts with `ESC [` and contains parameters and a final byte. For example, `ESC [ 31 m` means "set text color to red." CSI sequences handle cursor movement, colors, scrolling, and mode changes.
- An **OSC** (Operating System Command) sequence starts with `ESC ]` and typically sets the window title or handles clipboard data.
- A **DCS** (Device Control String) sequence starts with `ESC P` and is used for more complex data transfers, including tmux control mode.

Ghostty has a full VT parser that processes these sequences. The tmux control mode integration hooks into the DCS handling: when a DCS with parameter 1000 and final byte `p` arrives, it triggers the tmux control mode pipeline.

### TERM Environment Variable

When a terminal emulator starts a shell, it sets the TERM environment variable to tell programs what kind of terminal they are running in. Programs use this to look up the terminal's capabilities (what escape sequences it understands) in a database called terminfo.

Common TERM values include `xterm-256color`, `screen`, and `tmux-256color`. Ghostty sets its own TERM value (typically `xterm-ghostty` or `xterm-256color`).

This matters for tmux control mode because tmux sets `TERM=tmux-256color` (or `TERM=screen`) for programs running inside its panes. When the Viewer captures pane content via `capture-pane`, that content contains escape sequences for the tmux/screen terminal type, not for Ghostty's terminal type. The Terminal instances in the Viewer must be configured to interpret these sequences correctly. In practice, the tmux and xterm terminal types are similar enough that most sequences work the same way.

### DCS (Device Control String)

A DCS is a specific type of terminal escape sequence used for complex data exchanges between a program and a terminal. It starts with `ESC P` (or the equivalent single byte 0x90), contains parameters, a final byte that identifies the type, and then arbitrary data terminated by a String Terminator (ST, which is `ESC \`).

tmux uses DCS to frame its control mode session. When you run `tmux -CC`, tmux sends `ESC P 1000 p` to signal control mode entry. Everything between that opener and the closing `ESC \` is tmux control mode protocol data. Ghostty's `dcs.zig` detects this specific DCS and routes the enclosed bytes to the tmux control parser.

DCS is one of several types of escape sequences that Ghostty handles. Others include CSI (cursor movement, colors, modes), OSC (title, clipboard, hyperlinks), and APC (application program commands). Each has its own handler in the terminal parsing infrastructure.

### Alternate Screen Buffer

Terminals have two screen buffers: the primary screen and the alternate screen. The primary screen is where normal shell interaction happens and where scrollback history accumulates. The alternate screen is used by full-screen applications (like vim, less, or top) that want a clean drawing surface that will not pollute the scrollback.

When a program enters the alternate screen (via a specific escape sequence), the terminal saves the primary screen state and presents a blank screen. When the program exits the alternate screen, the terminal restores the primary screen state. This is why, after quitting vim, you see your previous shell output again.

tmux is an alternate-screen application. In normal mode, it uses the alternate screen to draw its TUI. This is relevant for the integration because the Viewer must capture both the primary and alternate screen content for each pane, since a pane might have a full-screen application (like vim) running that is using the alternate screen.

### Scrollback

Scrollback is the history of terminal output that has scrolled above the visible area. In a normal terminal, when the screen fills up and new text arrives, old text scrolls up. That old text is preserved in a scrollback buffer and can be viewed by scrolling up.

In normal tmux usage, scrollback is managed by tmux internally (you access it via tmux's copy mode with `Ctrl-b [`). In control mode, the terminal emulator (Ghostty) manages scrollback per pane. The Viewer populates initial scrollback for each pane by using tmux's `capture-pane` command with the `-S -` flag (which means "start from the very beginning of scrollback history").

Native scrollback is one of the key user experience benefits of control mode: instead of using tmux's copy mode keybindings, the user can just scroll up with their mouse or trackpad as they would in any normal terminal session.

### tmux

tmux is a terminal multiplexer. It runs as a server process in the background and lets multiple client sessions share a single connection. tmux manages windows (analogous to tabs) and panes (analogous to splits within a tab). Each pane contains a shell or other program.

tmux uses a server-client architecture. The server manages all the actual shell processes and persists even when all clients disconnect (this is the "session persistence" feature). A client connects to the server and provides the user interface. In normal mode, the client is a TUI (text user interface) that runs inside your terminal, drawing pane borders with box-drawing characters and rendering a status bar at the bottom. In control mode, the client sends structured text messages instead of drawing a TUI.

tmux uses stable numeric identifiers with sigils: `$` for sessions (`$0`), `@` for windows (`@1`), and `%` for panes (`%0`). These IDs are globally unique and persistent across reconnections.

### tmux Control Mode Protocol

The tmux control mode protocol is the structured text format that tmux uses to communicate with smart client programs (like terminal emulators) instead of drawing its own TUI.

Every message from tmux starts with a percent sign. There are three categories of messages:

1. **Command response blocks:** When the client sends a command (like `list-windows`), tmux wraps the response in `%begin` and `%end` (or `%error`) lines, with the response content in between. Each guard line contains a timestamp, command number, and flags field for correlation. The client must verify the full guard-line format to avoid false termination when payload lines coincidentally start with `%end`.

2. **Live output:** `%output` carries terminal data from a specific pane, with octal escaping for control characters (bytes below 32 decimal become three-digit octal escapes like `\015` for carriage return; the backslash character becomes `\134`). The client must decode these escapes before feeding the data to a VT parser.

3. **Async notifications:** Messages like `%session-changed`, `%window-add`, `%layout-change` that inform the client of state changes without being requested.

Flow control is an optional protocol feature where the client tells tmux to pause output for a pane if the client falls too far behind. Without flow control, a client that falls more than 300 seconds behind gets disconnected. With flow control enabled (via `refresh-client -f pause-after=N`), tmux uses `%extended-output` (which includes a "milliseconds behind" field) instead of `%output`, and sends `%pause`/`%continue` to manage throttling.

### Surface (Ghostty concept)

In Ghostty's architecture, a Surface is the fundamental unit of display. It is a rectangular area where terminal content is rendered and where the user can type. In the current implementation, every Surface has a one-to-one relationship with a subprocess running in a PTY: one Surface, one shell process.

Surfaces can be arranged in the GUI as tabs (multiple Surfaces in a window, with a tab bar to switch between them) or as splits (multiple Surfaces visible simultaneously in a tiled arrangement within a single tab).

For tmux control mode, the key challenge is that tmux panes need their own Surfaces, but those Surfaces are not backed by subprocesses. They get their content from the Viewer's Terminal instances and send input through tmux's `send-keys` command.

### Backend (Ghostty concept)

In Ghostty's terminal I/O layer, a Backend is the abstraction that provides data to a Surface and accepts input from it. The only backend that exists today is the exec backend, which manages a subprocess in a PTY. The backend is responsible for starting the subprocess, reading its output, writing input to it, and cleaning up when it exits.

For tmux control mode, a new backend kind is needed. A tmux backend would not have its own subprocess or PTY. Instead, it would be connected to a specific pane in the Viewer's state, reading content from that pane's Terminal instance and sending keystrokes back through the Viewer's command queue as tmux `send-keys` commands.

### Renderer (Ghostty concept)

The renderer is the component that reads a Terminal's screen buffer and draws it as pixels on screen. Ghostty uses GPU-accelerated rendering (Metal on macOS, OpenGL/Vulkan on Linux) to draw terminal content with proper font rendering, colors, cursor display, and selection highlighting.

Each Surface has its own renderer. The renderer does not care where the Terminal's content comes from — it just reads the screen buffer and draws it. This is important for the tmux integration: if a tmux-backed Surface's renderer is pointed at the Viewer's Terminal instance for a specific pane, it will render that pane's content without any changes to the rendering code itself. The challenge is purely in the plumbing: connecting the right Terminal to the right Surface.

### Terminal (Ghostty's internal type)

The Terminal type in Ghostty is a complete terminal emulator state machine. It contains everything needed to represent the state of one terminal session: a screen buffer (actually two: primary and alternate), a cursor with position and attributes, mode flags (like insert mode, autowrap mode, origin mode, and several mouse tracking modes), a scroll region, tab stops, and a VT parser.

The Viewer creates one Terminal instance per tmux pane. When `%output` data arrives for a pane, the Viewer decodes the octal escapes and feeds the raw bytes into that pane's Terminal through its VT parser. The Terminal processes the bytes exactly as if they came from a local subprocess, updating its screen buffer accordingly.

For the integration, these Terminal instances are what would be rendered by tmux-backed Surfaces. The key architectural question is whether the Viewer's Terminal instances should be shared with (or handed off to) the Surfaces, or whether the Surfaces should have their own Terminal instances that receive data through a different mechanism.

### Apprt (Application Runtime, Ghostty concept)

Apprt is Ghostty's abbreviation for application runtime. It is the abstraction layer that handles platform-specific GUI operations: creating windows, tabs, and splits; managing the application lifecycle; handling input events; and rendering.

Ghostty has multiple apprt implementations: one for macOS (using AppKit through Swift bindings), one for Linux (using GTK), and an embedded runtime for IDE integration. The apprt interface is defined by a set of types and methods that all implementations must provide.

For the tmux integration, the apprt layer needs to support creating Surfaces that are not backed by subprocesses. This is a fundamental change to the apprt contract, because today every Surface creation assumes an exec backend will be set up.

### State Machine

A state machine is a programming pattern where an object has a well-defined set of states and a well-defined set of transitions between them. At any given moment, the object is in exactly one state. Events or inputs cause transitions from one state to another.

Both the tmux control Parser and the Viewer are state machines. The Parser has four states (idle, notification, block, broken). The Viewer has four states (startup_block, startup_session, command_queue, defunct). Understanding these state machines is essential to understanding the tmux integration, because the correctness of the entire feature depends on handling state transitions correctly.

In Zig, state machines are typically implemented using an enum for the state set and a switch statement for the dispatch logic. The Parser's `put` method switches on the current state to determine how to process each byte. The Viewer's `next` method switches on the current state to determine how to process each notification.

### Tagged Union

A tagged union is a data type that can hold one of several variants, with a tag that identifies which variant is currently held. In Zig, this is declared with the `union` keyword and an associated enum for the tag.

Tagged unions are used extensively throughout the tmux integration. The Notification type is a tagged union (it can be `.enter`, `.exit`, `.output`, `.session_changed`, etc., and the tag tells you which). The Action type is a tagged union (`.exit`, `.command`, or `.windows`). The Layout's Content is a tagged union (`.pane`, `.horizontal`, or `.vertical`). The Backend type is a tagged union (currently just `.exec`, but would gain a `.tmux` variant).

You work with tagged unions in Zig using switch statements. When you switch on a tagged union, the compiler enforces that you handle every possible variant, which prevents you from forgetting to handle a case. This is a safety feature that the tmux integration benefits from heavily: adding a new variant to the Notification union causes a compile error everywhere that union is switched on until handling is added, making it impossible to silently ignore a new notification type.

### Zig: Error Handling

Zig uses explicit error handling rather than exceptions. Functions that can fail return an error union type, written as `!T` (meaning "either an error or a value of type T"). You handle errors with `try` (which propagates the error to the caller) or `catch` (which handles the error locally).

In the tmux integration code, you will see `try` frequently. For example, `try parser.put(byte)` means "call `put`; if it returns an error, immediately return that error from the current function." The Viewer's `defunct` method is called when an unrecoverable error occurs — it transitions the Viewer to the defunct state and emits an exit action.

You will also see `orelse` for handling optional values (see below).

### Zig: Optional Types

Zig has a built-in optional type, written as `?T`, meaning "either a value of type T or null." This is used when a function may or may not produce a result.

In the tmux integration, the Parser's `put` method returns `?Notification` — it returns a Notification when a complete message has been parsed, or null when it needs more bytes. The Viewer's `next` method returns `?Action` — it returns an Action when the Viewer has something for the caller to do, or null when processing is complete for this input.

You handle optionals with `if (value) |unwrapped|` syntax, or with `orelse` for a default. The `orelse return null` pattern means "if the value is null, return null from this function too."

### Zig: Slices

A slice in Zig is a pointer to a contiguous sequence of elements plus a length. Written as `[]T` (for a mutable slice) or `[]const T` (for a read-only slice). Slices are Zig's primary way of working with sequences of data, similar to Go slices or Rust slices.

In the tmux integration, the `.windows` action carries a `[]const Window` — a read-only slice of Window structs. Command strings are `[]const u8` — a read-only slice of bytes (Zig's string type). Block payloads are slices of bytes. Understanding that slices are pointer-plus-length (not owning containers) is important for understanding memory management in the Viewer.

### Oniguruma

Oniguruma is a regular expression library written in C. Ghostty's tmux control parser uses it to parse individual notification lines. For example, the `%output` notification is parsed with a regex that extracts the pane ID and the escaped data.

The build option `tmux_control_mode` is tied to Oniguruma availability. If Oniguruma is not available, the tmux module is compiled as an empty struct. In standard Ghostty builds, Oniguruma is available.

This dependency is a potential simplification target: the notification formats are simple enough that they could be parsed with basic string splitting instead of regular expressions, which would remove the Oniguruma dependency for tmux support.

### Compile-time Code Generation (comptime in Zig)

Zig has a powerful compile-time evaluation feature called comptime. Functions and values marked comptime are evaluated by the compiler during compilation, not at runtime. The result is baked into the compiled binary.

The tmux output parser (`output.zig`) uses comptime extensively. The `FormatStruct` function takes an array of Variable values at compile time and generates a struct type at compile time. The `comptimeFormat` function generates the corresponding tmux format string at compile time. This means there is no runtime overhead for format string construction or struct definition: the compiler generates the exact types and strings needed.

For someone new to Zig, comptime can be surprising because it blurs the line between types and values. A function that returns a type is perfectly normal in Zig. The Variable enum is a regular runtime value, but when passed to `FormatStruct` at compile time, it produces a type that can be used to declare variables and parse data at runtime.

### Arena Allocator

An arena allocator is a memory management pattern where allocations are grouped together and freed all at once. Instead of tracking each individual allocation and freeing them separately, you allocate from a contiguous region (the arena) and then free the entire region when you are done.

The Viewer uses arena allocators for layout trees. Each Window has a `layout_arena` that holds the memory for its Layout tree nodes. When a layout changes, the old arena is freed entirely and a new one is allocated for the new layout tree. This is efficient because layout trees are replaced wholesale rather than modified incrementally.

Arena allocation is common in Zig because Zig requires explicit memory management (there is no garbage collector). Arenas simplify the allocation and deallocation pattern for data structures that have a clear lifetime boundary.

### Circular Buffer (CircBuf)

A circular buffer (also called a ring buffer) is a fixed-size data structure that wraps around: when you reach the end, you go back to the beginning. Items are added at the tail and removed from the head.

The Viewer uses a circular buffer for its command queue. Commands to tmux are added to the queue, and the Viewer sends one command at a time, waiting for the response before sending the next. The circular buffer provides bounded memory usage for the queue even if many commands are queued up during operations like pane initialization (which queues multiple capture-pane and list-panes commands in sequence).
