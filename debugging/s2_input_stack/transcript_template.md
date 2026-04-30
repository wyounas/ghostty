# S2 Transcript

Date:

Build used: `macos/build/Debug/Ghostty.app`

Characters typed:

## Stop-by-stop notes

- `embedded.zig:1765`
- `embedded.zig:183`
- `Surface.zig:2607`
- `Surface.zig:2649`
- `Surface.zig:2752`
- `Surface.zig:3139`
- `Surface.zig:2765`
- `termio/Thread.zig:336`
- `Exec.zig:408`
- `Exec.zig:457`

## Answers to success criteria

1. Where does a surface key event first enter Zig?
2. What runs before Ghostty decides to write anything to the PTY?
3. Why does the shell not visibly respond until output comes back later?
4. Where does Ghostty first enter the concrete exec backend write path?
5. Where does Ghostty hand a concrete byte slice to the PTY-side write stream?

## Input vs output clarification

- When the IO thread drains `write_small` from the mailbox, the PTY write has
  not happened yet.
- The PTY first becomes concretely involved at `Exec.queueWrite`, and the
  closest useful Ghostty-side proof of the PTY-master write handoff is
  `Exec.zig:457`, where `exec.write_stream.queueWrite(...)` is called.
- The IO thread may wake the renderer after draining, but that does **not** mean
  Ghostty locally echoed the typed character.
- The visible `l` or `s` comes later from the PTY read side:
  the shell/tty emits bytes, Ghostty's read thread reads them, `Termio`
  processes them, terminal state changes under the renderer mutex, and only
  then does the renderer draw the result.
- The architectural rule is:
  input path writes outward to the PTY, output path updates terminal state and
  makes characters visible.

## Review and corrections

- Was the first stop the surface-key export boundary in `ghostty_surface_key`?
- Was the keybinding-versus-encoding split visible in `Surface.keyCallback`?
- Did `Exec.queueWrite` appear only after the IO-thread dispatch stop?
- Did `Exec.zig:457` make the "no more backend selection, now concrete PTY
  stream write" step visible?
- If a value printed as opaque, unavailable, or noisy, which source location or
  backtrace answered the question instead?

## Remaining confusion

- 

 So for l at a normal shell prompt, what you usually see is:

  1. Ghostty writes l to the PTY master
  2. the slave-side tty/program echoes or emits l
  3. Ghostty’s read thread reads that output back from the PTY
  4. processOutput -> nextSlice updates terminal state
  5. renderer draws it
