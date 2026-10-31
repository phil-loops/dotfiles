# Navigation model

> **Decided 2026-10-31 — what canopy writes:** canopy reads and talks; Helix writes code by hand (`o` opens it at the cursor's line and name). canopy may make an edit that is one decision — apply a suggestion (`A`), rename (`space r`) — and it always lands as a commit you see first, never as loose changes in a worktree.
>
> **Decided 2026-10-31 (supersedes the zoom-ladder h/l below):** hjkl move the cursor in what you see; structure has its own keys. `h`/`l` are left/right — the old/new half of a split diff line, else the pane to that side. `ret` goes in, `-` goes up a level (vim-vinegar's parent), `C-o` retraces time, `esc` cancels. The old rule borrowed Miller columns' h/l without Miller columns' layout: canopy's levels are pages that replace each other, so "out" was never to the left of anything, and on the pages that do have a left and a right (a split diff, list ⇄ detail) h/l meant something you couldn't see.
>
> **Decided 2026-10-29:** Phil adopted every recommendation below (Q1–Q5) and both stated assumptions (one app-wide jumplist; `M-h/j/k/l` pane alias). This file is binding for every area; change it only by coordination.

## Keys by verb (decided 2026-10-29; binding)

**Keys belong to verbs; pages implement verbs.** One table, `Sources/CanopyCore/Keys/Verbs.swift`, owns every key in every mode. A command registers "I am <verb> in scope <s>" (`Command(verb: .mark, …)`) or names a key under its page's leader (`Command(leader: LocalKey(",f"), …)`). There is no way to hand a command a raw key, so a key can't mean two things on two pages: the table gives each key one verb, and every page doing that verb does it to its own things. Which-key, the `?` sheet and the `:` line say the verb first ("m · mark"), the page's title after it.

**Tiers, each with a fixed owner**

1. **Nav** — `f`, `g …`, `space …`, h/l, `-`, J/K, C-o/C-i, `:`, `/`, `?`, esc, and the review moves (`]`/`[`, `}`/`{`, `n`/`N`). Owned by the nav core and the same on every page. A page may *implement* a nav verb on its own things (Review's `next-sibling`, the map's `next`), never rebind one.
2. **Shared verbs** — bare letters (and C-k/C-j, the digits). A page implements the ones that fit; it never invents one. A new shared verb is a change to the table, by coordination.
3. **The page leader `,`** — an action with no general verb is the page's own: `, <key>`. The leader's namespace is per page (a surface and all its scopes), so it can't collide with another page's or a future global. Pick its keys mnemonically; a chord is fine (`, b p`). `,` alone opens which-key titled "this page's keys".
4. **Insert** — a fixed set: `esc` stops writing, `⌃↵` always sends or finishes what's typed, `⌥↵` is a newline (the field does it). Plain `↵` depends on the field: it finishes a one-line field (`:`, the menu, a picker, a filter, a description, a subject) and is a newline in a many-line box (a comment, a PR or commit body) — where the frequent act is a new line, sending must be deliberate. A field declares its kind (`app.beginInsert(id, lines: .multi)`) and the engine routes `↵` by it; no page decides per key. Everything else goes to the field. No page adds to it; a page action wanted mid-typing is esc, then its key.

**The verbs** (keys are the defaults; keys-native.toml moves them)

| verb | keys | meaning |
|---|---|---|
| *nav* | | |
| next / previous | `j` `↓` / `k` `↑` (typing in `:`, the menu, a picker: `↓` `C-n` `C-j` `⇥` / `↑` `C-p` `C-k`) | the next / previous row, line or item |
| first / last | `g g` / `G` | the first / last row (jumps) |
| half-down / half-up | `C-d` / `C-u` | half a page |
| left / right | `h` `←` / `l` `→` | across what you see: the old / new half of a split line, else the pane to that side |
| next / previous name | `w` / `b` | the next / previous name in the code, across lines; `g d`, `space k` and friends ask about it |
| in / out | `ret` / `-` | one level in / up on the ladder (forests → forest → branch → file → line) |
| cancel | `esc` | close the innermost transient thing — never changes page |
| next-sibling / previous-sibling | `J` / `K` | the next / previous branch in merge order, staying on this kind of page (jumps) |
| parent / child / root / tip | `g k` / `g j` / `g K` / `g J` | the branch's parent, child (labels at a fork), its stack's root, tip (jumps) |
| next-file / previous-file | `]` / `[` | the next / previous file (jumps) |
| next-hunk / previous-hunk | `}` / `{` | the next / previous hunk |
| next-thread / previous-thread | `n` / `N` | the next / previous conversation, open ones first (jumps) |
| face | `⇥` | the page's other face (story ⇄ branches, the next tab, web ⇄ jobs) |
| labels | `g w` `f` | label everything on screen; type a label to go there |
| find | `space f` | find something on this page by name |
| search | `/` | search this page's text |
| map | `space m` | the map around what you're on |
| type | `space k` | the type under the cursor (hover) |
| definition / type-definition / implementations / references | `g d` / `g y` / `g I` / `g r` | code navigation |
| symbols | `space S` | list the file's symbols |
| github | `g h` | open it on GitHub |
| preview | `g p` | preview it on a side port |
| go-forests / go-dashboard / go-todo / go-machine / go-wiki / go-tutor | `g f` / `g s` / `g o` / `g m` / `g i` / `g t` | go to that page |
| alternate | `g a` | the alternate place (where the last jump left from) |
| slot-1 … slot-9 | `g 1` … `g 9` | the Nth focus forest |
| jump-back / jump-forward / save-jump | `C-o` / `C-i` / `C-s` | the jumplist |
| branches / jumps / last-picker | `space b` / `space j` / `space '` | pickers: any branch, the jumplist, the last picker again |
| pane-left / -down / -up / -right / pane-next | `C-w h/j/k/l` `A-h/j/k/l` / `C-w w` | focus a pane |
| command / menu / keys / select | `:` / `space ?` / `?` / `v` | the command line, the menu, the key sheet, select mode |
| leader | `,` | this page's own keys follow |
| *shared* | | |
| main | `↵` | the thing's main action |
| write | `i` | start writing: the field for the thing under the cursor |
| mark / unmark | `m` / `M` | mark it (viewed, done, answered) and go on / take the mark off |
| put-away | `X` | put it away: archive, drop, delete, kill, forget, cut |
| apply | `A` | apply the suggested fix |
| copy | `y` | copy it |
| push | `p` | send it out: push to origin, send the draft |
| sync | `s` | sync it: fold or stash dirt, rebase onto its parent, shape the commits |
| words | `e` | the words: what's written about it, in full |
| editor | `o` | open it in Helix |
| comment / reply | `c` / `r` | comment on it / reply to it |
| extend | `x` | extend the selection a line (`x x c` comments on a range: three verbs, not a chord) |
| undo | `u` | undo the last change |
| move-up / move-down | `C-k` / `C-j` | move it up / down its hand-ordered list |
| nth-1 … nth-9 | `1` … `9` | the Nth one shown: a tab, a choice |
| *insert* | | |
| send | `⌃↵` always; `↵` in a one-line field (normal mode: `⌃↵`) | send or finish what's typed |
| newline | `⌥↵`; `↵` in a many-line box | a new line in what's typed (the field's own; nothing may bind it) |

**Each page's leader keys**

| page | `,` keys |
|---|---|
| Forests (home) | `f` focus · `w` workbench · `i` the whole forest's diff · `l` launch · `b` / `B` hold / release · `r` only what's ready · `a` the archive |
| a forest | `f` · `w` · `i` · `l` · `b` / `B` (as home) · `n` next ready branch · `e` every branch's words |
| Review | `o` outdated threads · `b p` / `b m` / `b o` diff against parent / main / origin · `h` history · `g` gate output · `p` send every draft · `a` address a thread · `r` resolve · `n` the second reader's note · `d` save the comment as a draft · `S` insert a suggestion · in the address layer, `l` list the commits |
| Tutor | `t` re-test · `q` wrap up · `s` stop the tutor's turn · `v` the session's evidence · `o` / `l` / `h` / `c` a credit's hit-miss / level / help / confidence |
| Machine | `r` restart · `w` swap the port's build · `x` kill every server · `c` reap orphans · `m` run main · `u` the Docker stack |
| Dashboard | `r` the range |
| Tracker | `s` start the item |

**keys-native.toml** (`~/.dotfiles/canopy/keys-native.toml`, this app's own) overrides a verb by name (`mark = "v"`, `put-away = ["D"]`, `leader = ";"`) and every page doing it follows; the table's rules are re-checked after (a key on two verbs is flagged atop `?`). It's a separate file because `keys.toml` is shared with v2, which keys it by command id and would flag a verb line there as "no such command" — and a `[native]` table too, since the server's `keymap.py` reads every top-level entry of `keys.toml` and reports a table as "native: wants a key or a list of keys". v2 never opens `keys-native.toml`. Native still reads `keys.toml` (from the server's bootstrap): its command-id lines are read past with a warning naming the verb to set in `keys-native.toml` (in `--dump` and dim atop `?`); a verb line left there still applies, with a warning to move it, and `keys-native.toml` wins over it. Saving `keys.toml` reloads both files (the server's asset signature moves); after saving `keys-native.toml` alone, `:keys.reload`.

**The keytutor** (`:keytutor`, `:keytutor <lesson>`; `/v2/keytutor`, native only — not the Socratic Tutor page) teaches this table by doing, vimtutor-style, in a practice app: a real AppModel on canned data whose every request a stub answers, so `m`, `⌃↵`, `p`, `X` and sync never reach git, the server or GitHub. A step finishes when the practice app's engine sees its *verb* fire (`KeyEngine.onVerb`) with the outcome it wants, so rebinding a verb moves the step's text and still finishes it. Lessons follow the tiers (modes → moving → the ladder → labels → the stack → pickers and the jumplist → pages and panes → reviewing → finding and code → writing → shared verbs → the leader → `:` and `?`); a test fails if a verb goes untaught beyond a justified few (slot-3…9, nth-4…9). Its own keys live under the leader (`, k s` skip, `, k n`/`, k p` lesson, `, k r` restart, `, k l` pick, `, k q` leave) and the recap's under `main`/`next`. The one exception to "esc never changes page": esc that cancels nothing inside the practice app leaves the keytutor, back to where you were (the jumplist). Progress: `~/Library/Application Support/canopy-native/keytutor.json`.

**What the tests guard** (`ShellTests`, `KeysTests`): no page source names a raw key; every verb has a meaning and keys; the table holds after keys-native.toml; a page's leader keys don't repeat or swallow each other; nothing is bound twice in one place; insert keeps its fixed set; keys-native.toml moves a verb on every page while keys.toml stays v2's.


---

# Keyboard navigation for canopy-native: research and proposed model

2026-10-29. Scope: what makes keyboard-only, modal navigation feel good, with evidence, and the navigation model canopy-native should use. Grounded in v2's actual keymap (`viewer-solid/src/v2`), canopy-native's `PORTING.md` conventions, and v2's own usage telemetry.

---

## 0. The headline

1. **Most of the missing ergonomics come from one gap: targeting a specific thing you can see.** v2's keyboard already handles stepping (`j`/`k`) well. When Phil wanted a particular row, file, commit or tab, he clicked. That gap is closed by **labels** (Vimium/flash/Helix `gw`), not by more step keys.
2. **One zoom axis, three ways back.** `ret` goes in and `-` goes up along a fixed ladder (Forests → Forest → Branch → File → Hunk → Line/Thread). `C-o`/`C-i` move through time. `esc` only cancels transient state. Each of these does one thing and they never overlap.
3. **Walk the stack without leaving it.** `J`/`K` move to the next or previous branch in merge order *from the review page itself*. Today that takes `h`, then `j`, then `l`, plus two page paints.
4. **The novice path is the expert path.** `space` (which-key), `:` (palette), `?` (sheet) and labels all show the actual key sequence. Pressing through the menu rehearses the shortcut.
5. **A key means one thing everywhere, and frequent moves cost one home-row key.** v2 already enforces the first rule with a test. canopy-native keeps that test and adds frequency-to-cost discipline.

---

## 1. First-party evidence: v2 telemetry (6 days, 1,240 commands)

From `~/coding/loops/.git/stack-telemetry-rollup.json`, v2 commands only, split by how each was invoked:

| command | n | via |
|---|---|---|
| cursor.down / cursor.up (`j`/`k`) | 192 / 94 | all key |
| branch.open (`l`) | 81 | key |
| review.tab.commits | 77 | **59 click**, 18 key (`2`) |
| cursor.set (pick a row) | 71 | **all click** |
| review.leave (`h`) | 56 | 38 key, 18 click |
| review.cursor.set (pick a diff line) | 46 | **all click** |
| history.select (pick a commit) | 46 | **all click** |
| forest.page | 38 | key |
| review.file.go (pick a file) | 34 | **all click** |
| review.down (`j` in diff) | 32 | key |
| review.tab.conversation | 31 | 17 click, 14 key (`1`) |
| review.back (`esc`) | 22 | key |
| review.map (`space m`) | 16 | key |
| review.definition (`g d`) | 8 | key |

Page navigations: review 159, forest 109, forests 64.

**What this shows**

- Relative motion is already keyboard-native: `j`/`k`/`l`/`h` account for about 450 key presses and almost no clicks.
- **Absolute targeting is where the mouse comes back.** cursor.set, review.cursor.set, history.select and review.file.go come to 197 clicks and **zero** key presses. Adding tab clicks brings it to about 280 clicks, roughly 23% of all commands. None of these has a keyboard way to say "that one", so the hand goes to the trackpad. This gap is canopy-native's biggest navigation problem, and labels fill it (§3.2).
- **Number-row keys are underused.** The tabs have `1`/`2`/`3` and were still clicked 81 of 122 times. That fits the reach-cost principle (§3.1): keys off the home row get skipped.
- **The core loop is Forests → Forest → Review → back.** forest (109) and review (159) page loads interleave, and `h` (review.leave, 56) is used heavily to get back to the forest so `j` can pick the next branch. A direct sibling-branch move (`J`/`K`) cuts that loop.

Caveat: this is 6 days of one user while v2 was still being built, so treat it as directional. The click-only targeting pattern holds across all four commands, though, and has a structural cause.

---

## 2. Prior art: what feels fast and what feels clumsy

### Modal editors
- **Helix.** Uses selection→action order (inherited from Kakoune). `space` opens a mnemonic picker menu (`space f` files, `space b` buffers, `space j` jumplist picker, `space '` last picker). `g` is goto (`gd`, `gr`, `ga` = last accessed file, `gg`/`ge`). An infobox shows what can follow a prefix. `gw` puts **two-character jump labels** on every visible word; it shipped in 24.03 and was modeled on Amp's jump mode [helix-24.03]. The jumplist is `C-o`/`C-i` with `C-s` to save a position manually, and it has its own picker [helix-jumplist]. What carries over: **prefix families with mnemonic second keys, a visible infobox, labels for absolute targets, and pickers as a first-class surface.**
- **Kakoune.** Object-then-verb: you see the selection before acting, so mistakes are caught before they happen, and there's no separate visual mode [kak-ficd][kak-guide]. In canopy terms, the cursor/selection *is* the object, and every verb applies to what's lit.
- **Vim/Neovim jump plugins.** flash.nvim attaches labels to search matches and guarantees a label is never a possible continuation of the search pattern [flash]. leap.nvim fixes the pattern at two characters so labels can be **previewed before they become active**: your eye finds the label while your fingers are still typing, which removes a pause [leap]. Lesson: **labels should be stable and visible before you need them.** Positional labels computed once per layer open give you this.
- **harpoon.** A small, *numbered* working set of about 4–10 files per project, each reachable with one key. The authors recommend fuzzy finding for anything bigger [harpoon]. Lesson: **a few hand-picked slots beat named marks.** canopy already has a hand-ordered list: the focus lane.
- **Vim jumplist complaints.** The common ones: unclear which motions count as jumps ("why didn't `C-o` go back?"), tree-shaped history, `C-i` colliding with Tab, and surprises when IDE navigation mixes with vim's list [vimtricks-jumps][vim-stack-patch][ideavim]. Vim 9.0.1921 added a stack option because of this [vim-stack-patch]. Lesson: **write down exactly what records a jump, use stack semantics, and always restore position exactly.**
- **Emacs magit / transient.** A git UI driven by keys: each verb opens a transient menu listing its flags and sub-verbs with their keys, so a novice reads the same keys an expert types [transient]. Criticism: a big transient is "too much information at once," and menus that introduce their own bindings don't help you learn the existing ones [emacsconf-casual]. Lesson: **use which-key/transient for verbs, keep each layer short and grouped, and make the menu key the same as the direct key.**
- **avy** (Emacs), **hop** and **flash** are the same label pattern as Vimium (below).

### Keyboard-first apps
- **Superhuman.** One palette key everywhere. The palette is the single place every command lives, uses forgiving fuzzy matching and synonyms, is context-aware (hide only commands that are fully irrelevant), and shows each command's shortcut next to it so using the palette teaches the key [superhuman-palette]. Users describe the onboarding as forcing shortcuts on you "without feeling condescending" [superhuman-forum].
- **Linear.** `G` then a letter to go somewhere (`G I` inbox, `G M` my issues…), `Cmd-K` for everything, a searchable `?` help [linear-guide][linear-changelog]. The `g`+letter goto layer is the same idea as Helix `g` and v2's `g f/s/o/m/i/t`.
- **Vimium / Surfingkeys.** `f` labels every clickable element with home-row hints, so the mouse isn't needed. Users call it the most valuable feature. One complaint: typing link text can beat typing hint letters when links are well named, which is why some implementations filter by text as well [vimium-reviews][colemak-forum]. Lesson: **labels for "that one", a picker for "the one named X".**
- **lazygit.** Panels are numbered `1`–`5`, `?` shows the keys for the focused panel, and **the same key means different things in different panels**, which guides describe as "the most important thing to understand" [lazygit-man][lazygit-guide]. That's a cost to learn and a source of mode errors, and canopy's same-move rule exists to avoid it.
- **k9s.** `:` plus a resource alias switches view (`:po`), with autocomplete. Esc backs out of view, command and filter levels. Hotkeys are aliases of `:` commands [k9s-hotkeys][k9s-guide]. Lesson: **the command line and the hotkey should be the same command**, which is already true of the canopy registry.
- **Graphite (`gt`).** Stack navigation is `gt up`/`gt down`/`gt top`/`gt bottom`, with a count (`gt up 2`). **When a branch has several children, `up` asks which child** [graphite-nav]. This is the DAG case: linear moves are cheap, and fan-out asks a question.
- **Raycast/Alfred, zoxide.** Frecency ranking. zoxide's specifics: +1 per visit, with the score multiplied at query time by 4 (visited in the last hour), 2 (last day), ½ (last week) or ¼ (older). Scores are aged by a global divisor once the total passes a cap [zoxide-man]. A critique proposes per-visit power-law decay for fast context switching [hn-zoxide].
- **Miller columns (ranger/yazi/Finder).** Left/right walk parent/child, so the whole tree is reachable with four keys [miller-wiki][onecommander]. One warning: if left/right also have to move between columns for accessibility, overloading them causes conflicts [kleopatra].

### Review tools
- **Gerrit.** `[`/`]` for previous/next file are described as "the most-used keys". `n`/`p` (or shifted variants) move between chunks and comments. `shift+m` marks the file reviewed and goes to the next unreviewed one [gerrit-ml][gerrit-shiftm][gitlab-59590].
- **Crucible.** `u`/`i` for next/previous unreviewed file, and `y` marks reviewed and advances [crucible].
- **Reviewable.** Reported to use `n`/`p` for next unreviewed file and `shift+j`/`shift+k` for unresolved comments [gitlab-59590] (secondhand).
- **GitHub.** Few native Files-changed keys (`t` file filter, `c` commits). j/k between diffs and n/p between comments come from the Refined GitHub extension, and people keep asking for them [gh-docs][refined-gh]. GitLab has open issues asking for the same [gitlab-431260].
- Lesson: the review vocabulary is settled across tools: **brackets for files, n/N for threads, and "mark reviewed and advance" as one key.**

### Human factors
- **Keystroke-Level Model.** About 0.2–0.28 s per keystroke and about **1.35 s per mental-preparation operator (M)** [klm-lmu][klm-cmn]. The cost that dominates is **deciding**, not pressing. A predictable 2-key sequence beats a context-dependent 1-key one. Stability is a speed feature.
- **Marking menus.** Kurtenbach and Buxton's principle of **rehearsal**: the novice's action should physically be the expert's action, so using the menu trains the shortcut. In the field, marks were about **3.5× faster** than menu selection, and experts still went back to the menu to refresh their memory [kurtenbach-94][kurtenbach-design]. A which-key layer that shows `space f` while you press `space f` is rehearsal. A palette you mouse through is not.
- **Hotkey adoption.** Users stall on menus and toolbars and don't switch to shortcuts [lane-2005]. Making shortcut information unavoidable during menu use (for example audio feedback, or disabling the menu item) speeds learning [grossman-2007]. ExposeHK: holding a modifier overlays hotkeys on the visible commands, so people use more hotkeys, use them more often, and are faster [exposehk][exposehk-news].
- **Spatial memory.** CommandMaps and related work found that interfaces laid out in a stable spatial arrangement are learned faster than hierarchical menus [scarr-dblp]. For canopy: **things stay where they are**, labels are assigned by position, and nothing reflows during navigation.
- **Modes.** Raskin: mode errors happen when you forget which state you're in. Remove modes, or turn them into **quasimodes** that only last while the user is actively doing something. Holding a key for long input was criticized as uncomfortable [raskin-wiki][raskin-rchi]. Helix-style modes work despite this because they're **few, always shown in the statusline, and the risky ones (layers) close themselves after one action.**
- **Reach.** The 136M-keystroke typing study (Dhakal et al.) finds big differences between typists and lots of rollover [dhakal]. I couldn't pull a clean home-row vs number-row figure from it, so the reach argument here rests on v2's own telemetry (the tabs) and on KLM.

---

## 3. Principles that hold up against the evidence

1. **Price keys by frequency.** The top ~10 moves get one unmodified home-row key. The next tier gets a two-key mnemonic sequence (`g x`, `space x`). Rare actions get the palette only. Measured: j/k/h/l are about 37% of all commands.
2. **Step for neighbors, label for targets.** Relative keys for "the next one". Labels for "that one, which I can see". A picker for "the one named X, which I can't see". All three, always.
3. **One meaning per key, everywhere.** The only exceptions are the *same-move* families (`next`, `in`, `out`, `main action`…) that v2's `bindings.ts` already declares and tests. lazygit's per-panel meanings are the counterexample.
4. **Rehearsal: the novice path is the expert path.** The which-key infobox, the `:` palette, the `?` sheet and labels all print the real key sequence. The palette always shows the key.
5. **Separate space, structure, time and cancel.** `h`/`l` move across the screen (space). `ret`/`-` move along the ladder (structure). `C-o`/`C-i` move through what you visited (time). `esc` drops transient state (cancel). v2 already mostly does this (`review.leave` = `h`, `review.back` = esc closes things). Make it a rule.
6. **Few modes, always visible, layers close themselves.** Normal, select, insert and command, with the mode in the statusline. `space`, `g`, labels, menu and picker are layers that close after one action.
7. **Everything is instant and nothing moves.** No smooth scroll (Phil already killed it in v1 as "painful"). Labels and layouts are computed once and stay put. A DAG restack must not reshuffle positions while you're navigating.
8. **Defined jump membership and stack semantics.** Spelled out in §4.4.
9. **Frecency for recall, slots for the working set.** The branch picker ranks by fuzzy score × zoxide-style frecency. The focus lane doubles as the harpoon list.

### Anti-patterns to avoid
- The same key meaning different things depending on focused pane (lazygit).
- Esc that changes page or loses work (that's `-`'s job). Esc only ever cancels.
- Spatial `h/j/k/l` over a *drawn DAG*: it's ambiguous at fan-in and fan-out, and node positions change on restack. Use merge order plus explicit parent/child moves.
- Jumplists where you can't predict what got recorded, or tree-shaped history.
- Frequent actions on the number row or behind modifiers (the tabs).
- Big transient dumps. which-key layers should be ≤ ~12 entries, grouped.
- Labels that reshuffle between presses, or that cover the thing you're reading.
- Holding a key for long input (Archy's Leap). Labels and pickers are one-shot layers, not held keys.
- Hover-only or click-only affordances (already banned in PORTING.md).
- Moving a frequent binding around. Muscle memory compounds, so treat binding changes as costly, and only make them now, before canopy-native ships.

---

## 4. Proposed navigation model

### 4.1 The zoom ladder (in/out)

```
Forests ─l→ Forest ─l→ Branch(review) ─l→ File ─l→ Hunk ─l→ Line / Thread
        ←h─        ←h─                ←h─      ←h─      ←h─
```
- `ret` goes in one level. `ret` keeps v2's "the thing's main action" meaning: on a branch row that's open, on a thread it's fold, and so on.
- `-` goes up one level. This is **deterministic**: `-` on a review page always lands on its forest with the cursor on that branch, however you got there (v2 `review.leave` already does this).
- A detail pane beside a list is space, not structure: `l` moves focus right into it and `h` back to the list, without changing the selection.

### 4.2 Movement grammar by scale

| scale | next / prev | first / last | notes |
|---|---|---|---|
| row / line | `j` / `k` | `g g` / `G` | `C-d`/`C-u` half page (shell already binds these) |
| hunk | `}` / `{` | | **new**: vim's paragraph keys, "a bigger j" |
| file | `]` / `[` | | keep v2 (Gerrit's most-used keys) |
| thread | `n` / `N` | | keep v2; open (unresolved) threads first, outdated only when shown |
| unviewed file | `m` = mark viewed **and** advance | | **new**: Gerrit `shift+m` / Crucible `y` semantics; `M` unmarks |
| commit (history view) | `j`/`k` in the list, `l` reads | | keep v2 |
| branch, merge order | `J` / `K` | `g K` / `g J` (root / tip) | **new**: works on Forest *and* Review, staying on the same level |
| branch, DAG | `g k` parent, `g j` child | | **new**: child at a fan-out shows labels over the children (Graphite asks too) |
| forest (focus lane) | `j`/`k` on Forests | `g 1`…`g 9` | **new**: the focus lane is the harpoon list |
| pane | `M-h/j/k/l` | `C-w w` cycle | **new alias** for Phil's tmux habit; keep `C-w h/j/k/l` (Helix) |

**`J`/`K` on a review page** opens the neighbor branch's review in the same tab (files/commits/conversation), on the same file if that file is in the neighbor's diff, otherwise at the top. That makes reviewing a stack an `n`…`]`…`J` rhythm with no trip back up. It records a jump.

### 4.3 The goto/jump layer

- **Labels: `g w` (Helix), plus a single-key alias (§6, Q1).** Opens a label layer over **every visible target in every visible pane**: rows, branches, map nodes, files in the file list, diff hunks, threads, commits, tabs, buttons. Labels use the home row (`a s d f g h j k l ;` and then the next row), are assigned top-to-bottom and left-to-right by on-screen position, are computed once when the layer opens, and drawn as small pills that sit beside the target rather than on top of it. One key picks when there are ≤ 10 targets. Otherwise labels are two characters, and the first character groups by pane so your eye narrows to a pane first, like leap's preview. Any other key or `esc` cancels. Picking does the same as `ret` on that target (a `C-ret` variant only moves the cursor). This one layer replaces all ~280 clicks in §1.
- **Pickers (`space` layer), Helix-mnemonic.**
  - `space f`: find on this page (files on review, branches on a forest, forests on Forests). This is *one move*, so it goes in a same-move family.
  - `space b`: every branch across every forest, **ranked fuzzy × frecency** (zoxide multipliers ×4/×2/×½/×¼, plus a context boost for the current forest). Mnemonic: Helix's buffer picker. *Needs `machine.main` moved off `space b`.*
  - `space j`: jumplist picker (Helix).
  - `space '`: reopen the last picker with its query.
  - `space S`, `g r`, `g d`, …: code pickers, kept as they are from v2.
- **Goto (`g` layer).** Places: `g f/s/o/m/i/t` (kept). Code: `g d/y/I/r` (kept). Outward: `g h` PR, `g p` preview (kept). New: `g w` labels, `g a` alternate (the last two places, Helix `ga`, good for parent⇄child comparisons), `g k/j/K/J` DAG, `g 1–9` focus slots, `g g` top.
- **Palette `:`.** Every command, fuzzy, with synonyms, showing its key (Superhuman). `space ?` stays as an alias.

### 4.4 History: back/forward semantics

- **`C-o` / `C-i`** form one **app-wide** stack covering both pages and code places. Extend `nav.ts`'s code-only jumplist to cover surface changes.
- **What records a jump** (written into the `?` sheet): any page change, label pick, picker pick, `g`-goto, `J`/`K`/`g k`/`g j`, `]`/`[`, `n`/`N`, `g g`/`G`. **What doesn't**: `j`/`k`, `{`/`}`, `C-d`/`C-u`, `h`/`l`, and opening layers. `C-s` saves a position by hand, as in Helix.
- **Stack semantics:** a new jump after going back truncates the forward list (v2 already does this). Two consecutive identical entries collapse into one. Each entry stores page, cursor key, tab, base and scroll, and is **restored exactly**.
- **`C-i` ≠ `tab`**: AppKit sees them as distinct key events, unlike a terminal, so `tab` keeps "the page's other face".
- **`-` is not history.** `-` climbs structure. `C-o` retraces time. `esc` cancels. This split is the main defense against the vim complaints.

### 4.5 Esc: cancel only (the v2 rule, made universal)
Esc unwinds exactly one level: pending chord → layer (label/space/g/menu/picker/sheet) → mode (insert/select/command → normal) → page transient (composer, overlay, filter, armed push, range mark). **It never changes page.** If there's nothing to unwind, it does nothing and shows a quiet line: "h goes up · C-o goes back". This keeps v2's `review.back`/`overlay.close` behavior and pulls `history.exit`/`commit.exit` in under the same rule: they close a sub-view, which counts as a layer.

### 4.6 How modes interact with navigation
- **Normal**: everything above.
- **Select (`v`)**: motion keys *extend* the selection (`j/k`, `}`/`{`, `]`/`[`, `G`). Labels extend to the picked target, as in Helix `gw` in select mode. Verbs apply to the range: mark viewed, comment on a range, archive these. `x` (extend a line) stays in the review scope.
- **Insert / command / picker**: text-entry. Navigation keys go to the field. Only non-printables are bound (`C-n`/`C-p`/`up`/`down` to move, `ret` to accept, `esc` to leave), as PORTING.md already requires.
- **Layers are one-shot**: `space`, `g`, labels and pickers close after one action. That's Raskin's "a mode you can't forget you're in", without holding a key.
- **Statusline** always shows the mode, any pending chord (`g…`), and the jumplist depth (`◀3 ▶1`).
- **which-key infobox** appears at once on a prefix, doesn't take focus and doesn't animate. Typing through it costs nothing.

---

## 5. Default keymap (keep / change / add / drop)

*Superseded where it differs by **Keys by verb** above (e.g. focus is `, f`, not `F`; `space` keys a page owned moved under `,`).*

| key | command | status | why |
|---|---|---|---|
| `j` `k` `↓` `↑` | next / previous row (same-move family) | **keep** | 37% of all commands; home row |
| `h` `l` `←` `→` | left / right in what you see | **changed 2026-10-31** | in/out moved to `ret` / `-` |
| `ret` | the thing's main action | **keep** | |
| `g g` / `G` | top / bottom | **keep** (shell) | |
| `C-d` / `C-u` | half page | **keep** (shell) | |
| `]` / `[` | next / prev file | **keep** | Gerrit's most-used keys |
| `}` / `{` | next / prev hunk | **add** | stepping a diff line by line is slow |
| `n` / `N` | next / prev thread (open first) | **keep**, adjust order | |
| `J` / `K` | next / prev branch in merge order, staying on the same page type | **add** | cuts the h-j-l loop (§1) |
| `g k` / `g j` | parent / child (child at fan-out → labels) | **add** | DAG moves, Graphite semantics |
| `g K` / `g J` | stack root / tip | **add** | `gt bottom`/`gt top` |
| `g w` | labels over every visible target | **add** | closes the click gap; Helix habit |
| `f` *(proposed alias)* | labels (single key) | **add** — see Q1 | Vimium convention; the highest-value key |
| `g a` | alternate (last two places) | **add** | Helix `ga` |
| `g 1`…`g 9` | Nth focus forest | **add** — see Q5 | harpoon from the existing focus lane |
| `C-o` / `C-i` | jumplist back / forward, app-wide | **keep**, widen scope | |
| `C-s` | save position to jumplist | **add** | Helix |
| `M-h/j/k/l` | focus pane | **add** alias | Phil's tmux muscle memory |
| `C-w h/j/k/l/w` | focus pane | **keep** (shell) | Helix |
| `tab` | page's other face | **keep** | |
| `1` `2` `3` | review tabs | **keep**, but labels and `tab` cover them | clicked 66% of the time today |
| `esc` | cancel one level, never navigate | **keep**, made universal | |
| `space` | which-key menu | **keep** | |
| `space f` | find on this page | **keep** (review), extend to other pages | |
| `space b` | every branch, frecency-ranked | **change** (was `machine.main`) | Helix buffer-picker mnemonic |
| `space j` | jumplist picker | **add** | Helix |
| `space '` | last picker | **add** | Helix |
| `space m` | forest map | **keep** | |
| `:` / `space ?` | palette | **keep** | |
| `?` | key sheet | **keep** | |
| `/` | search text on this page | **change** (was a second key for find-file) | Helix `/`; find-file stays on `space f` |
| `g d/y/I/r`, `space k`, `space S` | code navigation | **keep** | ported as they are |
| `g f/s/o/m/i/t`, `g h`, `g p` | places / PR / preview | **keep** | |
| `v` | select mode | **change on review** (was mark viewed) — see Q3 | shell already binds `v` to select |
| `m` / `M` | mark viewed and advance / unmark | **add** | Gerrit/Crucible |
| `x` | extend selection a line | **keep** | Helix `x` |
| `C-k` / `C-j` | reorder (focus lane / todo) | **keep** | |
| `f` (project.focus) | move forest to focus | **change → `F`** if `f` becomes labels | rare action (absent from top usage) |
| `i` `c` `r` `e` `p` `s` `u` `o` | write / comment / reply / words / push / sync / undo / open in Helix | **keep** | verbs, not navigation |

**Drop:** nothing outright. Two keys get repurposed: `/` loses its role as a second find-file key, and `v` stops meaning mark viewed on review. Every v2 id keeps working through the `:` palette.

---

## 6. Open questions for Phil (with recommendations)

1. **Single-key labels?** Options: `g w` only (pure Helix), or also a one-key alias. **Recommend `f`** as the alias (Vimium's key, left index finger, and it would be the most-used key after j/k), moving `project.focus` to `F`. Fallback if you'd rather not move focus: `'`.
2. **`v` conflict.** The shell binds `v` = select mode (Helix), but v2 review binds `v` = mark viewed. **Recommend `v` = select everywhere and `m` = "mark viewed and advance to next unviewed"** (`M` unmarks). Advancing on the same key turns per-file review into `m m m`, the way blessing used to work, and stays per-file with no bless-all.
3. **Esc never changes page?** **Recommend yes**: esc cancels only, `-` climbs, `C-o` retraces. k9s-style "esc goes up a level" saves a key, but it mixes cancel with navigate and turns an over-pressed esc into a page change.
4. **What `J`/`K` do on the review page.** Either stay on Review and hop to the neighbor branch (same tab, same file if present), or bounce up to the Forest. **Recommend staying on Review**, the "parallel move". It removes the h→j→l loop telemetry shows is the core path. Neighbor order is merge order, the same total order the forest page shows.
5. **Quick slots for the working set.** Options: `g 1–9` = Nth focus forest (opening the branch you last had open in it), `M-1–9`, or none (pickers only). **Recommend `g 1–9` bound to the focus lane.** You already hand-order it, so it costs no new state, and it's harpoon's 4–10-item sweet spot. Skip named marks (`m`+letter) for v1.

(Already decided in the proposal, push back if wrong: the jumplist is one app-wide stack, and `M-h/j/k/l` is a pane alias.)

---

## 7. Implementation notes for canopy-native
- Labels need a per-pane `targets()` on `SurfaceProvider` (rect + RowKey + primary). The label layer is a `KeyMode` layer (`.labels`) per PORTING §4, with a single renderer in the Shell.
- ~~Add the new ids to `Bindings.sameMove`~~ — superseded: the verb table (Keys by verb) replaced the same-move groups.
- Extend `CodeNav` (nav.ts port) into an app-wide `Jumplist` of `Place {surface, arg, cursorKey, tab, base, scroll}`. Record from the router and from the commands listed in §4.4 via a `recordsJump: true` flag on `Command`.
- Frecency: reuse the router's `nav` telemetry events as the visit log, so it's seeded from day one.
- Measure: telemetry already records `via`. The success metric is **the click share of cursor.set / review.cursor.set / history.select / review.file.go / tabs going from ~100% to ≈0**, plus fewer forest↔review round trips per reviewed branch.

---

## Sources
- [helix-24.03] https://helix-editor.com/news/release-24-03-highlights/
- [helix-jumplist] https://docs.helix-editor.com/master/jumplist.html
- [kak-ficd] https://git.ficd.sh/ficd/ficd.sh/raw/commit/7bd2f2cf861ada2c23fc9ec0ddbd5070bb7c1012/content/blog/why-kakoune.md
- [kak-guide] https://terminal.guide/tools/text-editor/kakoune
- [flash] https://github.com/folke/flash.nvim
- [leap] https://github.com/ggandor/leap.nvim
- [harpoon] https://github.com/ThePrimeagen/harpoon · https://www.mintlify.com/ThePrimeagen/harpoon/advanced/troubleshooting
- [vimtricks-jumps] https://vimtricks.substack.com/p/vimtrick-using-jumps
- [vim-stack-patch] https://gerrit.omnirom.org/plugins/gitiles/android_external_vim/+/87018255e3ad0f4dfa03e20318836d24af721caf%5E%21
- [ideavim] https://intellij-support.jetbrains.com/hc/en-us/community/posts/206105719-IdeaVIM-questions
- [transient] https://docs.magit.vc/transient/Introduction.html
- [emacsconf-casual] https://emacsconf.org/2024/talks/casual
- [superhuman-palette] https://blog.superhuman.com/how-to-build-a-remarkable-command-palette/
- [superhuman-forum] https://connect.superhuman.com/t/how-to-use-keyboard-shortcuts-effectively-in-superhuman-tips-for-faster-email-workflow/60310
- [linear-guide] https://linear.app/enablement/guides/navigating-linear
- [linear-changelog] https://linear.app/changelog/2021-03-25-keyboard-shortcuts-help
- [vimium-reviews] https://firefox.marketplace.browsertotal.com/en-US/firefox/addon/vimium-ff/reviews/?page=16
- [colemak-forum] https://forum.colemak.com/post/12314
- [lazygit-man] https://manpages.debian.org/unstable/lazygit/lazygit.1.en.html
- [lazygit-guide] https://toolsbase.dev/en/blog/lazygit-getting-started
- [k9s-hotkeys] https://k9scli.io/topics/hotkeys/
- [k9s-guide] https://kodekloud.com/blog/manage-k8s-with-k9s-kubernetes-cli/
- [graphite-nav] https://graphite.dev/docs/navigate-stack
- [zoxide-man] https://man.archlinux.org/man/zoxide.1
- [hn-zoxide] https://news.ycombinator.com/threads?id=jghub
- [miller-wiki] https://en.wikipedia.org/wiki/Miller_columns
- [onecommander] https://onecommander.com/help2/FolderColumnsandNavigationPane.html
- [kleopatra] https://dev.gnupg.org/rKLEOPATRA284b61fa77bb2472a3f771730bb90bc2a74cd8b2
- [gerrit-ml] https://lists.openstack.org/pipermail/openstack-dev/2015-December/082932.html
- [gerrit-shiftm] https://gerrit.googlesource.com/gerrit/+/30d54106e2756ed9d3386112baa5393f87b60b28%5E%21/
- [gitlab-59590] https://gitlab.com/gitlab-org/gitlab-ce/issues/59590
- [gitlab-431260] https://gitlab.com/gitlab-org/gitlab/-/issues/431260
- [crucible] https://confluence.atlassian.com/x/0w-PLg
- [gh-docs] https://docs.github.com/en/enterprise-cloud@latest/get-started/accessibility/keyboard-shortcuts
- [refined-gh] https://oss.issuehunt.io/r/sindresorhus/refined-github/issues/2893
- [klm-lmu] https://www.mmi.ifi.lmu.de/lehre/ws0809/mmi1/slides/tutorial5.pdf
- [klm-cmn] https://andrewclark.super.site/all-media/the-keystroke-level-model-for-user-performance-time-with-interactive-systems
- [kurtenbach-94] https://www.billbuxton.com/MMExpert.html · https://billbuxton.com/MMUserLearn.html
- [kurtenbach-design] https://research.autodesk.com/app/uploads/2023/03/the-design-and-evaluation.pdf_recCzWoTgz02K2Ubb.pdf
- [lane-2005] https://dblp.dagstuhl.de/pid/65/2289.html (Lane, Napier, Peres, Sándor, IJHCI 18(2) 2005; abstract not retrieved)
- [grossman-2007] https://www.dgp.toronto.edu/~ravin/papers/chi2007_learninghotkeys.pdf (findings via secondary summaries)
- [exposehk] https://hal.archives-ouvertes.fr/hal-01894253
- [exposehk-news] https://sciencedaily.com/releases/2013/09/130930093728.htm
- [scarr-dblp] https://dblp.org/pid/41/7247 (CommandMaps CHI 2012/2014; spatial-memory monograph 2013; timings not retrieved)
- [raskin-wiki] https://en.wikipedia.org/wiki/The_Humane_Interface
- [raskin-rchi] https://www.raskincenter.org/rchi/core-principles
- [dhakal] https://www.pokristensson.com/pubs/DhakalEtAlCHI2018.pdf
- First-party: `~/coding/loops/.git/stack-telemetry-rollup.json` (v2, 2026-10-22 → 10-29); `~/.dotfiles/scripts/viewer-solid/src/v2/*`; `~/.dotfiles/scripts/canopy-native/PORTING.md`.

**Evidence caveats:** the hotkey-learning (Grossman), Lane and CommandMaps findings come from abstracts or secondary summaries; I couldn't read the full PDFs here. The Reviewable and Gerrit key specifics are partly secondhand and the sources disagree on exact keys. The telemetry covers 6 days of a v2 still being built.
