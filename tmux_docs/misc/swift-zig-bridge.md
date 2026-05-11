# Swift/Zig Bridge in Ghostty

This note explains why Ghostty has `include/ghostty.h`, what ABI means, how the
Swift macOS app uses the C bridge, and why the tmux MVP had to update the C
header.

## The First-Principles Problem

Ghostty has two worlds:

```text
Zig core
  owns terminal logic, surfaces, termio, renderer-facing state, actions

Swift/AppKit macOS app
  owns native macOS windows, views, menus, app lifecycle, AppKit integration
```

These two worlds need to call each other.

But Swift does not naturally understand arbitrary Zig types:

- Zig tagged unions
- Zig optionals
- Zig comptime-generated types
- Zig's internal struct layout
- Zig's default calling convention

Swift does understand C imports very well. Zig can also expose C-compatible
functions and types. So Ghostty uses C as the shared language at the boundary.

The bridge looks like this:

```text
Zig core
  -> C-compatible exported functions and extern structs
  -> include/ghostty.h
  -> Swift imports those C declarations
  -> Swift/AppKit runtime calls back into Zig or handles Zig actions
```

`ghostty.h` is not just documentation. It is the shared contract between the Zig
core and the Swift app.

## What Is an ABI?

ABI means Application Binary Interface.

An API is the source-code shape:

```c
void foo(int x);
```

An ABI is the compiled binary agreement:

```text
What is the function called in the binary?
How is the argument passed?
Which register or stack slot is used?
How big is this struct?
What order are the fields in?
What is the enum's integer type?
How is a union laid out?
Who owns this pointer?
Who frees this memory?
```

The API is what the programmer reads. The ABI is what compiled code relies on.

If two compiled languages disagree about ABI, the code may still compile but
read the wrong bytes at runtime.

## What Is a C ABI?

C ABI is the platform's standard binary convention for C-shaped functions and
data.

On macOS, Swift, Objective-C, C, C++, Zig, and other languages can all agree on
C-compatible layout and calling rules.

For example:

```c
typedef struct {
  int tag;
  void* ptr;
  size_t count;
} example_s;
```

This has a predictable binary shape:

```text
field order is fixed
field sizes are known
alignment is known
struct size is known
```

Zig can mirror this with an `extern struct`. Swift can import it from a C
header. That is the bridge.

## Where `ghostty.h` Is Used

The public C header is:

```text
include/ghostty.h
```

The module map is:

```text
include/module.modulemap
```

That module map exposes `ghostty.h` as a C module. The macOS build packages it
into `GhosttyKit`, and Swift imports that module.

The practical path is:

```text
include/ghostty.h
  defines C-compatible types and functions

include/module.modulemap
  makes the header importable as a module

GhosttyKit / macOS build
  packages the header and compiled Zig library

Swift files
  import GhosttyKit
  see types such as ghostty_action_s and ghostty_surface_config_s
```

One important runtime path is action dispatch.

Zig sends an action through the runtime callback using the C type:

```c
ghostty_action_s
```

Swift receives it in:

```text
macos/Sources/Ghostty/Ghostty.App.swift
```

The handler has this shape:

```swift
static func action(
    _ app: ghostty_app_t,
    target: ghostty_target_s,
    action: ghostty_action_s
) -> Bool
```

For the tmux MVP, Swift now sees:

```swift
case GHOSTTY_ACTION_NEW_WINDOW_WITH_SURFACE_CONFIG:
    newWindow(app, target: target, config: action.action.new_window_with_surface_config)
```

That only works because `ghostty.h` defines both:

```c
GHOSTTY_ACTION_NEW_WINDOW_WITH_SURFACE_CONFIG
```

and:

```c
ghostty_surface_config_s new_window_with_surface_config;
```

Another important path is surface configuration.

Swift reads and writes:

```c
ghostty_surface_config_s
```

in:

```text
macos/Sources/Ghostty/Surface View/SurfaceView.swift
```

That is how Swift can receive fields such as:

```c
backend
tmux_mvp_source_surface
tmux_mvp_pane_id
tmux_mvp_cols
tmux_mvp_rows
```

## What Changed for the tmux MVP

The MVP added a Zig action:

```zig
.new_window_with_surface_config
```

and a Zig config:

```zig
apprt.surface.SurfaceConfig
```

The C header had to mirror that.

In `include/ghostty.h`, we added:

```c
typedef enum {
  GHOSTTY_SURFACE_CONFIG_BACKEND_EXEC = 0,
  GHOSTTY_SURFACE_CONFIG_BACKEND_TMUX = 1,
} ghostty_surface_config_backend_e;
```

That lets Swift and Zig agree on the backend choice.

We also added fields to `ghostty_surface_config_s`:

```c
ghostty_surface_config_backend_e backend;
ghostty_surface_t tmux_mvp_source_surface;
size_t tmux_mvp_pane_id;
size_t tmux_mvp_cols;
size_t tmux_mvp_rows;
```

Those carry the tmux child-surface metadata across the Swift/Zig boundary.

Then we added the action tag:

```c
GHOSTTY_ACTION_NEW_WINDOW_WITH_SURFACE_CONFIG
```

and the action payload:

```c
ghostty_surface_config_s new_window_with_surface_config;
```

That lets Zig say:

```text
Please create a new window, but use this explicit surface config.
```

The old `new_window` action could not carry that information.

## What Could Have Happened If `ghostty.h` Was Not Updated?

Best case: the macOS app would fail to compile.

Swift would not know:

```text
GHOSTTY_ACTION_NEW_WINDOW_WITH_SURFACE_CONFIG
new_window_with_surface_config
tmux_mvp_pane_id
tmux_mvp_cols
tmux_mvp_rows
```

So the build would stop.

Worse case: Swift would compile against stale layout and read the wrong memory.

For example, Zig might send:

```text
action tag = new_window_with_surface_config
payload = SurfaceConfig
```

But Swift's imported C header might not know that payload exists. Then Swift
could:

- ignore the action
- handle the wrong action
- read the wrong union field
- lose the tmux backend choice
- lose the pane id
- read a bad pointer
- crash
- silently create the wrong kind of surface

The deeper rule is:

```text
Compiled programs cannot guess each other's structs.
```

If Zig says:

```text
field 15 is backend
field 16 is tmux source surface
field 17 is pane id
```

but Swift says:

```text
this struct ends at field 14
```

then Swift and Zig are no longer speaking the same binary language.

## Why Not Just Use Zig Types Directly From Swift?

Because most Zig types are not stable foreign-language contracts.

Inside Zig, it is fine to use:

- tagged unions
- slices
- optionals
- comptime-generated types
- normal Zig structs
- Zig error unions

At the Swift boundary, those are the wrong tools. Swift needs simple,
predictable, C-compatible shapes.

So Ghostty keeps rich Zig types inside Zig, and exposes a smaller C-shaped
surface to Swift.

## When This Pattern Is Good

Use a C ABI bridge when:

- two different languages need to call each other
- one side is Swift, Objective-C, C, C++, Rust, Zig, or another native language
- data crosses a compiled binary boundary
- the layout must be stable and predictable
- callbacks need to cross language boundaries
- one language owns core logic and another owns platform UI
- you need a small, explicit contract between modules

Good examples:

```text
Zig core -> Swift macOS app
Rust library -> C app
C++ engine -> C-compatible plugin API
native library -> Python/Ruby/Node FFI wrapper
```

Use simple C-compatible types:

- integers with explicit sizes
- `bool`
- pointers
- null-terminated strings when appropriate
- `extern struct`
- `extern union`
- enums with fixed integer representation
- opaque handles like `void*`

## When This Pattern Is Not Good

Do not use a C ABI bridge inside normal same-language code.

If Zig is calling Zig, use Zig types.

Do not force C ABI into internal code just because it feels "stable." You lose
type richness and make code harder to work with.

Avoid C ABI for:

- internal implementation details
- fast-changing private structs
- complex ownership-heavy data
- rich language-native types
- data where lifetimes are unclear
- APIs where the caller cannot safely know who frees memory

Also be careful with:

- structs containing pointers to temporary memory
- strings whose lifetime is only valid inside a callback
- unions where the tag and payload can get out of sync
- enums where new values are inserted in the middle
- changing field order after another language already imports the struct

The bridge should be small and boring.

## A Useful Rule

Inside one language:

```text
Use that language's best types.
```

Across languages:

```text
Use the simplest stable ABI contract you can.
```

For Ghostty, that means:

```text
Zig internals stay Zig.
Swift/AppKit stays Swift.
The boundary between them is C ABI through ghostty.h.
```

## How This Applies to Future tmux Work

If future tmux work changes only Zig internals, `ghostty.h` probably does not
need to change.

Examples:

- changing how `Tmux.zig` stores state internally
- changing how `%output` is routed inside Zig
- improving the Viewer state machine
- changing snapshot buffering inside `Surface.zig`

If future tmux work crosses into the macOS runtime, Swift, or embedding API,
then `ghostty.h` probably does need to change.

Examples:

- adding a new runtime action
- adding fields to `SurfaceConfig`
- adding a new callback from Swift to Zig
- adding a new C-visible enum value
- changing any struct consumed by Swift
- adding a new message payload handled by Swift

The practical question is:

```text
Does Swift or another non-Zig consumer need to see this value?
```

If yes, it probably belongs in the C ABI.

If no, keep it in Zig.
