Subject: tmux control mode: what I understand so far and the first MVP I want to try

Hi Mitchell,

I wanted to send a short update after spending time reading through the tmux control mode code and tracing the current path more carefully.

My current understanding is that a lot more of the tmux side is already working than I first expected. Ghostty is detecting the `-CC` DCS entry, parsing control mode notifications, driving the Viewer state machine, issuing the startup command sequence back to tmux, building pane/window state, creating a `Terminal` per tmux pane, capturing initial pane content, and routing live `%output` into the correct pane terminal.

The part that seems to stop the feature from becoming visible is later in the pipeline. The Viewer emits `.windows` with the right data, but `stream_handler.zig` drops it. And more importantly, Ghostty still assumes that every visible surface is backed by the normal exec/PTTY path. So even if the tmux state is correct, there is no way yet to create a Surface whose content comes from tmux pane state rather than from a subprocess.

Because of that, my instinct is that the first MVP should not be more parser work. The first real thing to prove is that Ghostty can create a non-exec surface for tmux at all.

The smallest version of that I have in mind is:

1. add a `.tmux` backend kind,
2. wire the first `.windows` action to create one new Ghostty surface for the first pane,
3. bootstrap that surface with the pane's captured content as a static snapshot,
4. leave it read-only for now, with no live output forwarding, input routing, resize sync, or multi-pane layout yet.

If that works, then the architecture is probably viable and the next steps become much clearer: live `%output` forwarding, input via `send-keys`, resize propagation, then multi-pane/native split handling.

I may still be missing some constraint here, so I wanted to ask a few things before I go deeper:

1. Does adding a new backend kind for tmux-backed surfaces sound like the right direction, or are you thinking about this through a different abstraction?
2. For the child tmux surface, would you prefer that it owns its own `Terminal` and gets populated by feeding VT bytes, rather than trying to share or copy the Viewer's terminal state directly?
3. What would be your preferred way to cross the thread boundary when `.windows` arrives on the tmux side but surface creation has to happen on the main/app side?
4. For the first MVP, would you rather see the pane appear as a new window, a tab, or do you not care as long as the non-exec surface path is proven?

If this direction sounds reasonable, I’ll start with that smallest proof first. If I’m aiming at the wrong layer, I’d much rather correct that now than build the wrong thing cleanly.

Best,

Waqas
