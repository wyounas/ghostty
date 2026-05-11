# An Oxford Tutorial on `fullmvp_manual_validation.md`

Let us begin with the simplest point.

The first MVP is trying to prove one narrow thing:

- Ghostty can enter tmux control mode
- Ghostty can notice tmux pane `%0`
- Ghostty can open a second native Ghostty window for that pane
- that second window starts from a captured snapshot
- that second window does not keep live-updating
- typing into that second window does not send input back to tmux

This tutorial explains the manual validation flow in
`tmux_docs/firstmvp/validation/fullmvp_manual_validation.md` and the scripts
that support it.

## 1. Three Programs, Three Jobs

You only need three ideas.

`Ghostty`

- a terminal emulator
- it draws terminal text in native windows

`tmux`

- a terminal multiplexer
- it keeps shells and panes alive
- it can describe those panes to another program

`tmux control mode`

- a machine-readable mode of tmux
- instead of drawing a user interface, tmux sends structured events and replies
- Ghostty reads those events and decides what to do

For this MVP, Ghostty does not try to become a full tmux UI. It does one small
thing: when tmux reports its first pane, Ghostty opens a second window and fills
that window with a one-time pane snapshot.

## 2. Why the Validation Uses Markers

The manual proof uses three short strings:

- `FULLMVP_SNAP_A`
- `FULLMVP_LIVE_B`
- `FULLMVP_CHILD_INPUT`

They are chosen so each one answers one question.

`FULLMVP_SNAP_A`

- Was the child window seeded from a captured tmux pane?

`FULLMVP_LIVE_B`

- Did the real tmux pane continue changing after the snapshot?
- Did the child window wrongly keep following those changes?

`FULLMVP_CHILD_INPUT`

- If I type into the child window, does that input leak back into tmux?

Without markers, the test becomes guesswork. With markers, each step has a
clear yes-or-no answer.

## 3. The Supporting Scripts

There are three validation scripts in this directory.

`ghostty_tmux_fullmvp_attach.sh`

- This is the simplest one.
- It tells Ghostty to run:
  - `tmux -L ghostty_fullmvp -f /dev/null -CC attach -t fullmvp`
- In plain language: attach to the already prepared tmux session in control
  mode.

Why this matters:

- We want the tmux pane to exist before Ghostty attaches.
- We want `FULLMVP_SNAP_A` to already be in tmux history.
- That removes the race where Ghostty asks for a snapshot too early.

`ghostty_tmux_mvp.sh`

- This is the older, smaller launcher used by `validat_w_build_nu.md`.
- It starts a fresh tmux control-mode session with one marker.
- It is useful for basic “does Ghostty enter control mode and open a second
  window?” checks.

`validate_remaining_mvp.sh`

- This is the repeat runner.
- It performs the same proof shape as the manual doc, but automatically.
- It repeats the flow five times by default.

What it actually does:

- closes Ghostty
- clears the dedicated tmux server
- pre-creates a tmux session with a unique snapshot marker
- launches Ghostty through `ghostty_tmux_fullmvp_attach.sh`
- waits for exactly two Ghostty windows
- advances the source tmux pane with a unique live marker
- copies text from Ghostty terminals to identify the child window
- checks that the child shows the snapshot marker but not the live marker
- checks that the real tmux pane shows both markers
- sends input to the child window
- confirms that input never appears in tmux
- repeats

So the script is not a different test. It is the manual test done carefully and
repeatedly.

## 4. What Happens in the Manual Validation

Now let us walk through the manual proof one step at a time.

### Step 1: start clean

We quit Ghostty and make sure no old Ghostty process is still running.

Why:

- old windows can be restored
- if old windows are present, the “exactly two windows” check becomes useless

### Step 2: build the exact app

We first show the current branch and commit, then clean stale build outputs, then
build the Zig core, run the targeted tests, and rebuild the macOS app.

Why:

- the behavior we are validating lives in the current source tree
- the app bundle must match the code we are discussing
- old app bundles or Zig artifacts from another branch would make the demo
  ambiguous

The important detail is that we clean build outputs directly:

- `macos/build.nu --scheme Ghostty --configuration Debug --action clean`
- `rm -rf zig-out .zig-cache`

We do not use `git clean -fdx` for this proof, because that can delete local
notes and untracked docs.

### Step 3: clear stale tmux state

We kill the dedicated tmux server on socket `ghostty_fullmvp`.

Why:

- tmux remembers sessions
- old sessions can contain stale panes and stale history
- this proof must start from known state

### Step 4: pre-create the tmux session

We create tmux session `fullmvp` before Ghostty attaches, and we print
`FULLMVP_SNAP_A` into the pane immediately.

Why:

- later, Ghostty will ask tmux for a pane snapshot
- the pane snapshot can only contain text that already exists in tmux history
- therefore the marker must exist before Ghostty starts

This is one of the most important steps in the whole proof.

### Step 5: use the checked-in attach script

Ghostty is told to run `ghostty_tmux_fullmvp_attach.sh`.

Why:

- the script is deterministic
- it always attaches to the same dedicated tmux server and session
- it keeps the manual proof reproducible

### Step 6: launch Ghostty

Ghostty starts with:

- `--window-save-state=never`
- `--initial-command='direct:.../ghostty_tmux_fullmvp_attach.sh'`

Why:

- `--window-save-state=never` stops old windows from reappearing
- `direct:...` tells Ghostty to run the tmux control-mode attach script directly

Now Ghostty begins reading tmux control-mode output.

### Step 7: Ghostty should create two windows

Why two?

- window one is the original control-mode Ghostty surface
- window two is the new child Ghostty surface for tmux pane `%0`

If there is only one window:

- Ghostty did not create the child window

If there are three or more windows:

- the run is contaminated by old or unrelated windows

### Step 8: the child should show `FULLMVP_SNAP_A`

This is the first real behavioral proof.

At this point the path is:

1. tmux sends window information
2. Ghostty's tmux viewer emits a `.windows` action
3. Ghostty asks the app thread to open a new tmux child window
4. tmux capture output becomes a `.pane_snapshot`
5. Ghostty flushes that snapshot into the child surface

If the child window visibly shows `FULLMVP_SNAP_A`, that chain worked.

### Step 9: change the real tmux pane

Now we send `FULLMVP_LIVE_B` into the source tmux pane.

Why:

- we need to prove the source pane is still live
- we also need to create a change that the child must not follow

This step is the contrast step:

- source pane changes
- child snapshot must not change

### Step 10: the child must stay static

We look back at the child window.

Correct result:

- it still shows `FULLMVP_SNAP_A`
- it does not show `FULLMVP_LIVE_B`

This proves a very specific design claim:

- the child is a one-time snapshot surface
- it is not a live mirror of the tmux pane

### Step 11: the child must be read-only

We click into the child window, type `FULLMVP_CHILD_INPUT`, and press Enter.

Then we inspect the real tmux pane.

Correct result:

- `FULLMVP_CHILD_INPUT` does not appear in tmux

This proves:

- the child window can receive focus like a normal Ghostty window
- but Ghostty is not forwarding that input back to tmux for this MVP

### Step 12: Ghostty must stay alive

The launch terminal must not show a crash or sudden exit.

Why:

- a feature that only works before crashing is not validated

### Step 13: repeat

One good run is not enough.

Why:

- races can pass once and fail later
- repeated clean runs give stronger evidence that the sequence is stable

That is why `validate_remaining_mvp.sh` exists.

## 5. The Data Flow, in Plain Language

Here is the whole flow in short form.

### Before Ghostty starts

1. tmux session `fullmvp` is created
2. the pane already contains `FULLMVP_SNAP_A`

### When Ghostty attaches

1. Ghostty starts tmux control mode
2. tmux reports its windows and layout
3. Ghostty picks the first pane from the first window
4. Ghostty asks the app thread to open a new child window for that pane
5. Ghostty asks tmux to capture that pane
6. tmux returns snapshot text
7. Ghostty sends that snapshot text into the new child surface

Result:

- the child window shows `FULLMVP_SNAP_A`

### After the source pane changes

1. tmux source pane receives `FULLMVP_LIVE_B`
2. the real pane now contains both snapshot and live markers
3. the child window is not updated with the new live marker

Result:

- source is live
- child is static

### After typing into the child

1. you type into the child window
2. Ghostty does not forward that input back into tmux
3. the real tmux pane remains unchanged

Result:

- child is read-only in practice

## 6. What Is Actually Being Validated

This validation is not trying to prove everything about Ghostty or tmux.

It is only trying to prove these first-MVP claims:

- control mode enters correctly
- the first pane is detected
- a second native Ghostty window is created
- the child is seeded from a pane snapshot
- the child stays static after later tmux changes
- the child does not send input back to tmux

It is not trying to prove later goals such as:

- live tmux pane mirroring
- typing through the child into tmux
- multi-pane rendering
- full tmux UI parity inside Ghostty

That narrowness is a strength. A small claim is easier to prove correctly.

## Q&A

### Why do we create the tmux session before launching Ghostty?

Because the child window is seeded from `capture-pane`. If the text is not
already in tmux history, the snapshot can be empty.

### Why do we need exactly two windows?

One window is the original tmux control-mode surface. The second is the new
child window for pane `%0`.

### Why is `FULLMVP_LIVE_B` sent after the child appears?

Because we want a clean before-and-after test. The child should contain the old
snapshot, not later live changes.

### Why do we type into the child window at all?

To prove that focus and normal Ghostty window behavior exist, while input still
does not leak back into tmux.

### Why is the repeated script important if the manual flow already works once?

Because races often pass once. Repetition is how we learn whether the proof is
stable.

### Does the child window talk directly to tmux?

Not in this MVP. The child is seeded with captured output. It is not a live tmux
client.

### If the child shows `FULLMVP_LIVE_B`, what does that mean?

It means the child is live-updating, which violates this first MVP.

### If `FULLMVP_CHILD_INPUT` appears in the tmux pane, what does that mean?

It means child-window input leaked back into tmux, so the read-only claim is
false.
