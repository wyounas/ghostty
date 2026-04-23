Subject: tmux control mode update: what I think is working, the first MVP, and what I’ve managed to implement so far

Hi Mitchell,

I wanted to send a short update on where my head is with tmux control mode, what I think the first MVP should be, and how far I’ve managed to push that so far.

My current understanding is that the protocol and Viewer side are already in better shape than I initially thought. Ghostty is detecting the `tmux -CC` DCS entry, parsing control mode notifications, running the Viewer startup flow, sending the expected command sequence back to tmux, building window and pane state, creating a `Terminal` per pane, capturing pane content, and routing live `%output` into the right pane terminal.

The real gap seems to be later. The Viewer emits `.windows` with the right data, but that never turns into a visible native surface. And underneath that, Ghostty still assumes a visible surface is backed by the normal exec/PTTY path. So the first thing that seemed worth proving was not more parser work, but whether Ghostty can create a non-exec surface for tmux at all.

That’s the first MVP I aimed for: add a `.tmux` backend kind, use the first `.windows` action to request creation of one tmux-backed surface for the first pane, and bootstrap it with a static snapshot of the captured pane content. I kept the scope intentionally narrow: no live output forwarding yet, no input forwarding, no resize sync, and no multi-pane layout handling yet.

I went ahead and implemented that shape. The main pieces are now there: a `.tmux` backend path in `backend.zig`, a `Tmux.zig` backend stub, a new app-thread message to request tmux window creation, a shared surface-config payload that carries the tmux metadata across the Zig/runtime boundary, the runtime-side handling for that config, and the snapshot bootstrap path for the child surface. I also had to fix a few things that turned out to matter in practice: an action ABI ordering issue, making sure the target pane dimensions were actually applied, and a use-after-free bug where the Viewer was emitting `.windows` from temporary list storage instead of stable owned state.

On the validation side, the core build and tmux-targeted tests are passing, and the runtime logs got me to a more useful place. At this point I can see tmux control mode activate, the Viewer emit a sane `.windows` action, the stream handler receive it, and the code request creation of the tmux MVP window with the expected pane metadata. So I’m more confident now that the parser/Viewer side is not the main blocker.

Where it still looks shaky is the app-thread handoff. The remaining issue seems to be around the path from the tmux-side request into the app mailbox / runtime wakeup / actual native window creation. In other words, I think the code is now reaching the right boundary, but I do not have a clean end-to-end validation yet that the second window is being created reliably in the final path.

I’d really value your read on this. In particular:

1. Does the overall direction look sensible to you?
2. Does a dedicated `.tmux` backend still sound like the right abstraction for this?
3. Does the “static snapshot first, then live output/input/resize later” sequencing seem like a good way to de-risk the work?
4. Based on what’s implemented so far, does this feel like meaningful progress to you, or do you think I’m still pushing in the wrong layer?

If you think the direction is sound, I’ll keep narrowing the app-thread/runtime handoff until the first MVP actually shows the child surface reliably. If not, I’d much rather correct course now.

Best,

Waqas
