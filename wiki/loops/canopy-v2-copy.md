---
title: Saying less
section: Canopy v2
order: 63
project: canopy-v2
lede: The terse pass over every on-screen string in v2 (2026-10-25, 13f2d80) — before and after, for review. Command titles in the ? sheet and the menu keep their full wording.
---

**The hint line is gone** (see [Keys like Helix](canopy-v2-keys)); the copy rules below still hold.

**Rules.** Pair opposites into one hint (`j/k line`). One word, no next/previous when the pair implies it. Cut what the page already shows. A glyph or a count over a phrase. Terse and lowercase; notes end in `· u undoes`.

| where | before | after |
|---|---|---|
| App · header | space · commands   ? · keys | space menu · ? keys |
| Commits · drafts lost | N edits were on commits that no longer exist — the branch moved; they won't be saved | N edits dropped · branch moved |
| Commits · words | lands on main as | lands as |
| Commits · PR body placeholder | a line of why (optional), then the template | why |
| Commits · no commits | no commits of its own | no commits |
| Commits · read-only | read-only: on a remote — rewording it would force-push | on a remote — rewording it would force-push |
| Commits · body placeholder | why, in a line (optional) | why |
| Commits · save | Save 2 changes ⌘↵ | save 2 ⌘↵ |
| Commits · save note | rewrites the unpushed commits in place · u undoes | u undoes |
| Forest · branch facts | 2 ahead of origin | 2 to push |
| Forest · branch facts | 1 open conversation | 1 open |
| Forest · missing forest | no such forest — h goes back to Forests | no such forest |
| Forest · header | focus · 7 branches · 5 ready for you · ⇥ the story · e the words · l opens · h back | focus · 7 branches · 5 ready |
| Forest · counts | 5 ready for you | 5 ready |
| Forests · launch done | ✦ the whole forest is on GitHub | ✦ all on GitHub |
| Forests · launch progress | 3 of 7 on GitHub — p pushes, g h opens its PR on its parent's · esc | 3/7 on GitHub |
| Forests · ready banner | ready · 3 things you can do now · F shows everything | ready · 3 · F all |
| Forests · ready banner | (above) | (above) |
| Forests · empty focus | nothing in focus — f on a forest puts it here | empty |
| Forests · empty bench | the workbench is clear | empty |
| Forests · archive fold | archive · 84 — ⇧a opens it | archive · 84 |
| Forests · empty archive | the archive is empty | empty |
| KeySheet · nothing under cursor | nothing here takes a key — move the cursor onto something | nothing under the cursor |
| KeySheet · section | On this page, not right now | not here |
| KeySheet · footer | Your keys: ~/.dotfiles/canopy/keys.toml — underlined ones are yours. | yours: canopy/keys.toml (underlined) |
| Menu · no match | no command matches | no match |
| Story · no body | no body — the title is the whole story | no body |
| Todo · header | 31 open · ↵ opens one, I starts, D done, X drops, ⌃k/⌃j reorder · /next ranks the rest | 31 open · /next ranks |
| Todo · empty | nothing tracked — canopy-todo add "…" | nothing tracked |
| Conversation · no PR | this branch has no open PR on GitHub — nothing to converse about yet | no PR |
| Conversation · pending | comment on a line in Files changed — it goes into your pending review, which you submit on GitHub | no pending comments |
| Conversation · submit | Open on GitHub to submit ⇧s | submit on GitHub ⇧s |
| Outgoing · head | 2 commits leave for origin/add-domain-reenable-queries | 2 to push |
| Outgoing · head | nothing to push — origin has every commit | nothing to push |
| Outgoing · head | · follow-ups onto #11132 · tip 39dd2c0 · gates green on it | · onto #11132 · 39dd2c0 · gates ✓ |
| Outgoing · not local | this branch isn't local | not local |
| Outgoing · gates | gates on this tip | gates |
| Outgoing · gates | no gates run for this tip yet | not run |
| Outgoing · gate row | stopped, no result | stopped |
| Outgoing · replies | replies that ride the push | replies |
| Outgoing · reply offer | nalanj on sending-domain.test.ts:599 — addressed by 14adf15, nothing drafted · draft "done in 14adf15" | nalanj on sending-domain.test.ts:599 · draft "done in 14adf15" |
| Outgoing · reply state | waits for a commit that addresses it / into your pending review once the push lands | waits for its fix / after the push |
| Outgoing · section | the change, commit by commit | commits |
| Outgoing · loading | reading its diff… | … |
| Outgoing · fold | 3 files · +240 −80 · folded (over 150 lines) — show it | 3 files · +240 −80 · show |
| Outgoing · fold | fold it | fold |
| Outgoing · push button | Push 2 commits p / p again sends 2 commits to origin | push 2 p / p again to push |
| Outgoing · push blocked | waits for the gates to go green on this tip | gates not green |
| Outgoing · pushing | ◌ pushing 2 commits to origin · 3.1s | ◌ pushing · 3.1s |
| Outgoing · landing | ✓ on origin · the page is catching up · 4.0s | ✓ pushed · 4.0s |
| Overlays · words head | The words · e closes | words |
| Overlays · map head | The forest · j/k · ↵ opens · esc · p its page | forest · p page |
| Overlays · map head | (above) | (above) |
| Overlays · map empty | nothing else to review | nothing else |
| Overlays · address | Hand it to Claude — drafted into a new session in the branch, you send it | claude |
| Overlays · address | Fix it yourself in Helix — then E here picks the commit | helix |
| Overlays · address | Pick the commit that fixes it | pick its commit |
| Overlays · address | no unpushed commit to pick — commit the fix first (esc) | no unpushed commits |
| Review · no changes | nothing changes on this branch | no changes |
| Review · drafts | 2 drafts only here · ⇧p sends | 2 drafts · ⇧p send |
| Review · no PR | no open PR — the diff, without conversations | no PR |
| Review · history head | j/k steps · l reads it · esc what a push sends | (gone — the hint line has it) |
| Review · history | What a push sends | to push |
| Review · commit head | · read-only · esc all changes | · read-only |
| Review · viewed | 4 of 10 changes viewed | 4/10 viewed |
| Review · elsewhere | conversations on files this branch no longer changes | threads on files it no longer changes |
| Thread · fixed chip | addressed by 14adf15 — check the domain is actually re-enabled | fixed in 14adf15 |
| Thread · changed chip | addressed by 14adf15? | changed in 14adf15? |
| Thread · note row | · i inserts its reply | (gone — the hint line has it) |
| Thread · waits | waits for a commit that addresses it | waits for its fix |
| Thread · waits | waits for 14adf15 to reach origin | waits for push |
| review · note | drafted into a new Claude window — read it and send it there; the reply waits for its commit | claude window ready — send it there |
| review · note | fix it there and commit; then E here picks the commit | fix, commit, then ⇧e to pick it |
| review · note | 14adf15 addresses it now — the reply waits for your push · u takes it back | 14adf15 addresses it · u undoes |
| review · note | drafted — it goes into your pending review with the push | reply drafted |
| review · note | the trailer and its reply are gone | undone |
| review · note | draft deleted — u puts it back | draft deleted · u undoes |
| review · note | applied as a local commit — u drops it | applied · u undoes |
| review · note | nothing to back out of — h goes back to Forests | nothing to close |
| project · note | archived X — u puts it back | archived X · u undoes |
| words · note | reworded 2 commits — u puts it back | reworded 2 commits · u undoes |
| words · note | messages put back | undone |
| HintLine · miss | p — nothing to do here | p · nothing here |
| Thread · second reader | · same issue in 3 places | · 3 more like it |
| hint line · pairs | j next line · k previous line · n next conversation · ⇧n previous conversation · ] next file | j/k line · n/⇧n thread · ]/[ file |
| hint line · labels | x extend the selection a line · c comment on the line | x range · c comment |
| hint line · Commits | … · 2 commits · p push (nothing to push) | (gone — the tab you're on, and a push with nothing to send, don't claim the line) |
