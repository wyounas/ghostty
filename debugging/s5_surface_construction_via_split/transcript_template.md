# S5 Transcript

Date:

Build used: `macos/build/Debug/Ghostty.app`

Split action used:

## Stop-by-stop notes

- `embedded.zig:1910`
- `embedded.zig:1541`
- `Surface.zig:549`
- `Surface.zig:654`
- `Surface.zig:700`
- `Surface.zig:708`

## Answers to success criteria

1. What runtime entrypoint is used when Ghostty creates another surface?
2. Which major pieces are installed into the child surface before threads start?
3. Why is this a useful baseline for future tmux child-surface creation?
4. Where does the exec backend enter the picture for the child?

## Review and corrections

- Did the split request clearly begin in runtime code?
- Did `ghostty_surface_new` appear as the ordinary child-creation entrypoint?
- Which stops best proved what the child surface already contained before child
  threads started?
- Did the exec backend appear as part of ordinary child birth, not as a later
  special case?

## Remaining confusion

- 
