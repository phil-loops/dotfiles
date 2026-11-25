+++
title = "Jump from a GitHub PR straight to its branch's tmux pane"
kind = "build"
state = "done"
area = "review"
size = "S"
why = "⌘⇧O then Ctrl-Space is two hops to reach the conversation working on a PR; one chord should land there"
incarnation = "i_df5739f5a8fa40919151b8e478cf6981"
created = "2026-11-25"
updated = "2026-11-25"
+++

From a GitHub PR, one chord should land on the tmux pane of the Claude session working on that PR's branch — today it's ⌘⇧O (opens canopy) then Ctrl-Space (tmux.switch).

Sketch: a second extension command (its own chord) POSTs the tab URL to /open-url with `then: "tmux"` (or a dedicated route). The server resolves PR → branch exactly as the ⌘⇧O path does, then asks Show to run tmux.switch for that branch (PaneBranches.toTmux — the @pane_branch map). No pane on that branch → open canopy on it as ⌘⇧O does, and say so in the badge.

Owner note: PaneBranches.swift / pane-branch were mid-edit by the canopy lane on 2026-11-25 when this was filed.
