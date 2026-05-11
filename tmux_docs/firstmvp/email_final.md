Subject: tmux control mode first MVP: non-exec surface proof and validation

Hi Mitchell,

I hope you're well. I wanted to share an update on the tmux control mode work and ask for your guidance on the next step.

This has taken me longer than I first expected. Had to work on this in in between familiy and work. Also, Ghostty is a serious feat of engineering and I commend you and other contributors for their contriibutioins. I am also new to this domain and to Zig, so most of my time went into understanding the existing architecture rather than writing code. I spent a lot of time in LLDB, and I am attaching my hand-typed debugging notes, validation notes, and a short screencast of the MVP demo.

I did use Codex as an assistant while working through this, but I tried hard not to outsource the reasoning to it. I used it more as a tool to ask questions, challenge assumptions, and check my understanding, and for Zig specifics. I still expect there may be gaps in my thinking, so I would value your correction where I am off.

My goal for this MVP was deliberately small: prove that Ghostty can create and render a tmux-backed native surface that is not backed by the normal exec/PTTY path.

What I have implemented so far (have attachced a diff):

- added a '.tmux' backend path and a small 'Tmux.zig' backend stub
- used the first '.windows' action to request one native child window for the first tmux pane
- crossed from the tmux/read-thread side to the app thread before creating the window
- added a surface config payload to carry the source surface, pane id, cols, and rows across the Zig/runtime boundary
- made the child surface own its own 'Termio' and 'Terminal', with no subprocess, PTY, or exec read thread
- bootstrapped the child with a static pane snapshot by sending bytes through '.process_output'
- kept the child read-only and static for this MVP
- fixed a few issues found along the way, including action ABI ordering, pane dimensions, and a Viewer lifetime bug where '.windows' was emitted from temporary storage instead of stable owned state

This is not full tmux control mode integration. There is no live output forwarding yet, no input forwarding, no resize sync, and no multi-pane/native split reconstruction yet. The point was to prove the smallest meaningful architectural step first.

To verify that it works, the manual validation I used was:

- build the core and app, and run the tmux-focused tests
- start from a clean Ghostty state with window restore disabled
- start a fresh tmux server/session and make sure 'FULLMVP_SNAP_A' is already present before Ghostty attaches
- launch Ghostty into 'tmux -CC' through the checked-in attach script
- require exactly two native Ghostty windows
- verify that the child window shows 'FULLMVP_SNAP_A'
- send 'FULLMVP_LIVE_B' later to the real tmux pane and verify the child stays static
- type 'FULLMVP_CHILD_INPUT' into the child and verify it does not reach the real tmux pane
- repeat the clean validation flow for stability

The attached validation notes have the exact commands and marker checks.

The main questions I have are:

1. Does this look like the right smallest step toward tmux control mode integration?
2. Does a dedicated '.tmux' backend still seem like the right abstraction, or would you prefer a different shape?
3. Is the "static snapshot first, then live output/input/resize later" sequencing reasonable?
4. What next path would you prefer: live '%output' forwarding, input via 'send-keys', resize propagation, or pane/window lifetime handling?
5. Do you think this is ready to open as a PR for review? If not, that is completely fine. What would make it PR-shaped enough?

I am determined to help with tmux control mode integration and am very willing to change the approach and also change any Zig related constructs or style. Please let me know what you think of the progress so far.

All my best,
Waqas
