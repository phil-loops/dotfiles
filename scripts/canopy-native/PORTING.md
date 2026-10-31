# Porting canopy v2 to canopy-native

Phase 1 built the foundation. In phase 2, each agent ports one **area** of the SolidJS app
(`scripts/viewer-solid/src/v2/`) into its own folder here. The app talks to the same, unchanged
Python server. Its HTTP contract is in [API.md](API.md).

## 0. Hard rules

**Safety (non-negotiable)**
- Edit only under `scripts/canopy-native/`. `scripts/viewer-solid/` and `scripts/srv/` belong to another
  live session: read them, never modify them.
- GET reads against the live server are fine. **Never POST to a mutating endpoint with a real branch
  name** (sync, prep-push, push-origin, restack, squash, seal, gates, outline, review-*, project-state,
  focus, todo-item, viewed, preview*, anything that writes). To exercise a write path, use branch
  `__probe__` or an empty body and expect 400/404. Better still, test writes against the `Stub` URLProtocol
  (`Tests/CanopyCoreTests/RunnerTests.swift`), never the live server.
- Never write `branch.*.stack-gates-green-tree`. Note that `GET /gates-progress` writes that key itself when a
  finished run is green (API.md §3), so don't poll it for real branches from tests.
- In `~/.dotfiles` never `git add -A` / `git add .`. Commit only your own paths.
- Don't screenshot, osascript or otherwise look at Phil's screen. Verify with `canopy --dump`, the log
  (`~/.cache/canopy-native/canopy.log`) and tests.

**Mouseless and modal (binding on every area; Phil's design direction)**

canopy-native is a Helix-style modal app, not a click UI with shortcuts added on top.
1. **Every key goes mode → keymap → command.** Register commands with the modes they bind in. Never
   install raw `NSEvent` monitors, `.onKeyPress`, `.keyboardShortcut` (⌘ menu-bar items in
   `CanopyApp` excepted) or `onSubmit` key logic in a page. The shell's `KeyMonitor` is the only key listener.
2. **Every action is reachable by key and discoverable.** Give it a key (shown by which-key and the `?` sheet), or
   leave it keyless and it's still runnable from `:` with fuzzy completion. A command that only runs with
   an argument from another view (`needsArg: true`) must be reached through a keyed route: `ret`/`pane.open`
   → your surface's `primary(for:)`, the menu, or the picker.
3. **Nothing requires the mouse.** No hover-only information (`.help` tooltips may repeat what's visible,
   never be the only place it lives), no click-only affordances, no drag-only interactions. v2's drag
   reorders (`drag.ts`) become key commands (`focus.up`/`focus.down` already exist in v2). Clicks and scroll
   wheels may still work, but don't design any UI around them.
4. **Focus is always visible.** Every list is a pane (`SurfaceProvider.panes`) drawn with `PaneList`, or
   with the same three rules: a focus ring on the focused pane, the cursor row lit, the cursor kept on screen.
5. **Keys belong to verbs; pages implement verbs** (NAV.md "Keys by verb" is binding). A command says
   `verb: .mark` — "I am mark here" — and gets the verb's keys from the one table (`Keys/Verbs.swift`). An action
   no verb names goes under the page leader: `leader: LocalKey(",c")`. There is no raw-key path for a page.
   Implement a verb only when its one-line meaning is what your command does; never invent one (a new verb is
   a table change, by coordination). Insert mode is a fixed set (esc, ⌃↵ send — ↵ too in a one-line field — ⌥↵ newline): don't bind in it.
6. **Every area adds a test** that `KeyboardRule.violations(app) { $0.hasPrefix("<yourprefix>.") }` is
   empty, alongside the app-wide `everyCommandIsReachableByKey`, `keysMeanOneThingEverywhere`,
   `noPageSourceNamesARawKey` and `leaderNamespacesDontOverlapWithinAPage`.

## 1. Layout

```
canopy-native/
  Package.swift            SwiftPM; macOS 14; Swift language mode 5
  canopy                   launcher: builds release if sources changed, wraps Canopy.app, opens it
  API.md                   every endpoint v2 calls (method, body, response, caller, READ/MUTATING)
  PORTING.md               this file
  Sources/
    CanopyCore/            no UI: SHARED, change only by coordination (see §9)
      Transport/           Transport (getJSON/getText/ask/post/streamPost/events), SSE, EventStream + Pulse, Bootstrap
      Store/               Store (@Observable store.ts), Wire (Snapshot, Patch, LossyTable, checkVersion)
      Models/              Entities.swift (types.ts), LSP.swift (review/types.ts answers)
      Router/              Route (every v2 address), Router (back/forward)
      Keys/                Verbs (the verb table, LocalKey), Registry (Command, Scope, KeyMode, Write), Keymap/KeyName/sheetNow, Bindings, KeyEngine
      Runner/              Runner (runner.ts: dispatch, optimistic writes, FIFO, undo), Telemetry
      Support/             JSONValue, OpenString, CodeNav (nav.ts jumplist + picker), pickScore/ranked
    CanopyUI/
      Shell/               SHARED: AppModel, Area protocols, ShellCommands, KeyMonitor, RootView, Statusline,
                           PaneList + ModalTextField, KeyboardRule, Dump, Areas.swift (pre-populated)
      Theme/               SHARED: Theme (tokens.css dark + light), Fonts (bundled Plex Mono + Fraunces)
      Pages/<Area>/        OWNED: one folder per area, see §8
      Resources/Fonts/     the web app's woff2 latin subsets (OFL); CoreText registers woff2 directly
    Canopy/main.swift      the executable: --dump → Dump, else CanopyApp
  Tests/
    CanopyCoreTests/       wire/store/route/keys/runner tests + Fixtures/ (a real /state, a real SSE capture)
    CanopyUITests/         ShellTests + ModalTests over the whole installed app; add <Area>Tests.swift here
```

## 2. Build, run, test

```bash
cd ~/.dotfiles/scripts/canopy-native
swift build                     # debug
swift test                      # all suites; must stay green at every commit
./canopy                        # release build (if sources changed) → ~/.cache/canopy-native/Canopy.app → open
./canopy /v2/b/loops/<branch>   # open on a route; a running app is routed through canopy://
./canopy --dump [--dump-wait 5] # headless: hydrate + listen + exercise keys, JSON on stdout, exit 1 if no hello
./canopy --build >/dev/null; .build/debug/Canopy --shoot <dir> --shot "name=/v2/b/loops/<b> 2 k" [--size 1280x800]
                                # headless: draw each shot offscreen into <dir>/name.png (keys after the route; never a write key)
./canopy --repo ~/coding/monotoad --appearance light
tail -f ~/.cache/canopy-native/canopy.log   # what the running app is doing (hydrate, events, nav, key problems)
```

Port discovery: `--port` takes priority. Otherwise the launcher runs `stack-review-port` in `--repo`, or in the current git repo if a
server is listening there, or in `~/coding/loops` (62497 today). Deep links: `canopy://v2/p/loops/x`, `canopy:///v2/...`,
`canopy://open?path=/v2/...`, or a bare `/v2/...` argument.

## 2½. The look

Calm ledger, not a control panel. Check a change by `--shoot`ing it, never by guessing.
- **No boxes.** Panes, pages and chips carry no stroked border; focus shows as the lit cursor row (PaneList) or a 1pt
  goldDeep hairline on the focused pane's leading edge. Floating layers (picker, menu, sheet, which-key) keep their edge.
- **Use the width.** No `maxWidth` caps on lists; put secondary facts right-aligned on the row. Reading prose may cap.
- **Minimal text.** No key-hint prose in content (`↵ open · e words`); keys live in which-key, `?` and on KeyButtons.
  Say a fact once (the loop rail names only the step in the way; the push button carries the count).
- **Buttons are washes**, not outlines: `KeyButton` / `Lever` fill vellumRaise (goldWash when it's the next move).
- **Order follows the work.** Lists read the way the work happened (commits oldest first, their sum at the foot).

## 3. The page contract

Each area is an `enum <Name>Area: PageArea` in `Pages/<Area>/<Name>Area.swift`. `install(app)` runs once at
launch, in `Areas.all` order. That list is pre-populated with every area, so nobody edits it. Inside
`install` you:

- `app.addSurface(MySurface())` for each routed page you own (`Surface.all` ids: forests, dashboard,
  review, todo, forest, machine, wiki, tutor, keytutor — the last native only, `Pages/KeyTutor/`).
- `app.registry.register(Command(...))` for your commands (§4).
- `app.registry.addScopes([...], to: "<surface>")` if you add a scope (`extension Scope { static let x: Scope = "x" }`).
- `app.addCloser(isOpen:close:)` for anything `esc` in normal mode should back out of (v2's armed push, a launch).
- `app.state { MyAreaState() }` makes your area's `@Observable` state once and returns it every time after
  (the port of page.ts, tutoring.ts, workstation.ts, …). Never use globals or singletons.

`SurfaceProvider` is the per-page half of model.ts:

| member | v2 equivalent | default |
|---|---|---|
| `view(app, route)` | the surface's component | required |
| `panes(app)` → `[Pane]` | the regions the cursor walks; `Pane(id:title:rows:column:row:pageSize:)` | one pane `"main"` holding `rows` |
| `rows(app)` | `model.rows()` for this surface | `[]` |
| `scopes(app)` | `liveScopes()` narrow part (shell appends the surface id and `global`) | `[]` |
| `target(for: scope, app)` | `targetFor(scope)` | shell: `row` → selected, `project` → `p:`, `branch` → `b:` |
| `primary(for: row, app)` → `RouteTo?` | the row's main action (what `ret` does) | nil |
| `crumbs(app, route)` | `Crumbs` in App.tsx | the surface title |

Row keys follow model.ts (`RowKey.project/branch/todo/landed/server/wiki/concept/lesson`: `p:<id>`,
`b:<id>`, `t:`, `d:`, `m:`, `w:`, `c:`, `s:`). The shell keeps a cursor and a select anchor **per pane**:
`app.selected`, `app.selection` (the range in select mode), `app.pane`, `app.isFocused(paneID)`,
`app.setCursor`, `app.cursorTo`, `app.focus(pane:)`, `app.focus(.left)`.

Until a page is ported it is a `PlaceholderSurface` that returns a `Placeholder(title:area:sources:notes:)`.
That gives it two real panes, facts and sources, so j/k, gg/G, C-w h/l, v and the statusline already
work. Replace it with your own `view` and `panes`. `Pages/Forests/` is the worked example: rows from
the store, `PaneList`, and `primary` → `find.forest` / `find.branch`.

## 4. Keys, modes and commands

```swift
app.registry.register(Command(
    id: "todo.up", title: "Move the item up the queue", scope: .item, budget: .configWrite,
    verb: .moveUp,                     // its keys come from the verb table (C-k); or leader: LocalKey(",s")
    modes: [.normal],                  // default; motion commands also take .select
    label: "up", pair: "todo.down",
    available: { id in id != nil },
    write: { id, _ in Write(ops: [Op(type: .todo, id: id, fields: ["rank": 3])], path: "/todo-item",
                            body: ["id": .string(id), "rank": 3], settled: { … }, failed: "couldn't move it") }))
```

- **Command** mirrors registry.ts: `local` (throw `Refusal("…")` to refuse with a quiet line), `write`
  (an optimistic `Write`: ops overlay → POST on the FIFO queue → kept until `settled()` or 5s → rolled back
  on refusal), `route` (a key that means "the right thing here", for example `ret`, returns `RouteTo(id, target:, arg:)`),
  `available`, `quiet` (left out of the space menu but still in `:`), `needsArg`, `hint`, `v1`.
- **Dispatch** only through `app.runner.dispatch(id, via:target:arg:)`. Views never call `transport.post`
  for a write: a write is a command, so it's timed, undoable, rolled back and reachable by key.
  `app.runner.runOf(id, target)` gives a button its live state (sending/landing/done/failed).
- **Modes** (`KeyMode`): `normal`, `insert`, `select` and `command` (the `:` line); the layers are `menu` (space menu),
  `sheet` (`?`) and `picker`. `app.keys.active` is the layer if one is up, else the mode. Bind keys in the modes
  where they make sense. Text-entry modes (insert, command, menu, picker) hand every key nobody bound in that
  mode to the focused field, so bind only non-printables there (`ret`, `tab`, `up`, `C-n`). KeyboardRule
  enforces this.
- **Insert mode**: put the field on screen as `ModalTextField("<field id>", text: $draft)` and enter it with
  a `verb: .write` command calling `app.beginInsert("<field id>")`. Esc leaves insert, and the field loses focus.
  Finishing is a `verb: .send` command with `modes: [.insert]`; ⌃↵ always sends, ⌥↵ is the field's newline, and ↵
  follows the field's kind: a one-line field finishes on it, a many-line box (`beginInsert(id, lines: .multi)` — a
  comment, a body) takes it as a newline. Nothing else
  binds in insert — two sends live in one scope at once need a narrower scope for one (Review's `filter`).
- **Select mode**: `v` drops an anchor at the cursor, `j`/`k` extend it, and `app.selection` is the range. Make
  multi-row commands (archive these, hold these) act on `app.selection`, and list `.select` in their modes.
- **Esc** backs out exactly one level, innermost first: pending chord → layer → mode → your page's own
  `esc` in normal (`overlay.close` closers, `review.back`, `wiki.back`, …). Don't bind esc in other modes.
- **Your own layer** (a composer, a confirm step): `extension KeyMode { static let confirm: KeyMode = "confirm" }`,
  then `app.keys.openLayer(.confirm)` / `closeLayer()`, and bind its keys with `modes: [.confirm]`. If it
  takes text, add it to `KeyMode.textEntry` in your install.
- **Picking keys** (NAV.md "Keys by verb"): find the verb whose meaning is your command's and pass `verb:`
  (`.next`, `.into`, `.main`, `.putAway`, `.write`, `.send`, …). A page command implementing a verb wins over the
  shell's in its scope (`review.down` over `cursor.down`, both `next`). Several verbs at once is `verbs: [.main, .into]`.
  No verb fits → `leader: LocalKey(",x")`, mnemonic, unique on your page (all its scopes), never a prefix of
  another of your page's leader keys. The nav tier (`f`, `g …`, `space …`, h/l, J/K, C-o/C-i, `:`, `/`, `?`,
  esc, `]`/`[`, `}`/`{`, `n`/`N`) is the nav core's: implement those verbs, never claim their keys. A page's
  own layer (Review's map, its address sheet) binds verbs and leader keys in that mode the same way.
- **Hints in copy**: say a key through the registry — `app.registry.keyOf("<id>")`, or `verbKey(.mark)` — so
  keys.toml moves the copy too.
### Navigation seams (NAV.md is binding; the shell implements the rest)

- **Labels (`f` / `g w`) come free from `PaneList`**: every visible row is a target, and picking it moves
  the cursor there and runs your `primary(for:)`. Anything else you can see that Phil would click (tabs,
  files in a tree, hunk headers, buttons, map nodes) wears `.labelTarget(pane: "tabs", key: "tab:files",
  title: "files", run: RouteTo("review.tab.files"))`. A custom list that isn't a `PaneList` wears
  `.labelTarget(pane: <pane id>, key: <row key>)` on each row (no `run`: it's a row) and `.labelPane(<pane id>)`
  on its scroll view. Override `targets(app)` only for something that can't wear the modifier; start from
  `app.visibleTargets()`.
- **Row text**: override `title(for: row, app)` if the shell's guess (branch/forest name, else the key)
  is poor — `/` searches it.
- **The jumplist** records every page change and every command implementing a jump verb on its own (the
  registry sets `recordsJump`); set `recordsJump: true` on any other command that moves somewhere far.
  Code jumps through `app.nav.go(loc)` record too. To put your page back exactly, implement
  `remember(_ place: inout Place, app)` (set `place.tab`, `place.scroll`) and `restore(_ place:, app)`
  (apply them). The shell restores route, pane, cursor and `place.loc` (via `app.nav.open`) first.
- **Jump verbs record jumps**: a command implementing `first`/`last`, `next-sibling`/`previous-sibling`,
  `parent`/`child`/`root`/`tip`, `next-file`/`previous-file` or `next-thread`/`previous-thread` gets
  `recordsJump` from the verb. `mark` on Review marks viewed **and advances**; `J`/`K` on Review stay on
  review (same tab, same file if present).
- **Esc only cancels.** A page change while esc runs is refused (logged); with nothing to cancel, esc says
  "h goes up · C-o goes back". Your `esc` command closes things; `h` climbs.
- **Pickers**: feed `app.nav.pick(title, items) { index in … }` with `PickItem(label:text:)`; picks that
  navigate record a jump through the router. Wrap a pick that only moves the cursor in `app.jump { … }`.

- **keys-native.toml** (`~/.dotfiles/canopy/keys-native.toml`, read from disk by `app.applyKeyFiles`) overrides a
  **verb** by name (`mark = "v"`, `leader = ";"`), applied by `registry.applyUserKeys` to every command implementing it.
  `keys.toml` stays v2's (command ids, injected by the server's bootstrap script, or read directly if that fails):
  native reads its command-id lines past with a warning naming the verb to set instead (`keyWarnings`, in `--dump` and
  dim atop `?`), and applies a verb line found there with a warning to move it. Both are re-applied whenever the
  server's asset signature moves (saving keys.toml moves it) and on `:keys.reload`. Problems (a key on two verbs, a
  leader clash) show at the top of the `?` sheet, in `--dump` and in the log. Tests point `app.nativeKeysPath` at a
  temp file; never at the real one.

## 5. Calling the server

`app.transport` is the only door (sync.ts):

| call | use | v2 |
|---|---|---|
| `try await getJSON(path, as: T.self)` | reads; throws `HTTPError` on non-2xx | `getJSON` |
| `await getText(path)` | a file at a commit; nil on failure | `getText` |
| `await ask(path, body, as: T.self)` | read-POSTs (`/lsp/*`, `/integrate`); nil on failure | `ask` |
| `await post(path, body, via:)` → `Sent` | **writes, only from a command's `Write`** (the runner calls it) | `post` |
| `try await streamPost(path, body) { frame in … return done }` | SSE answers to a POST (`/tutor`, `/chat`) | `streamPost` |
| `app.pulse.onProcs { … }` → unsubscribe | previews/agents/chat moved (`/events` `procs`) | `onProcs` |
| `transport.atRepo(repo, path)` | `/<repo>/path` prefix for repo-pinned reads | `atRepo`/`atRepoPath` |

Every request carries `X-Stack-Actor: browser` and `X-Request-Id: <launch>-<n>`. Writes add `X-Stack-Via`.
A write's answer follows sync.ts: 2xx with no `ok:false` is ok; 2xx `{ok:false}` or a 4xx is **refused**
(the reason is in the `X-Stack-Refused` header, with the sentence in body `err`, sometimes `error`); a 5xx
or no answer **failed**. Build query strings with `String.uriComponent` (encodeURIComponent).

**Response types are yours.** Declare the `Decodable` for an endpoint you call in your own folder
(`Pages/Machine/MachineWire.swift`), not in CanopyCore. API.md has the shapes. Re-check one against the
live server with a GET before you trust it, and save it as a fixture next to your test.

## 6. The store

`app.store` (`@Observable`, store.ts) holds the entities of `/state` + `/v2/events`:
`store.list(Branch.self)`, `store.view(Branch.self, id)` (overlay applied), `store.table(T.self)` (server copy),
`store.conn`, `store.ready`, `store.versions`. Reading these in a view's body subscribes it.

- **A field the shared models lack**: don't edit `Entities.swift`. Read it raw in your folder:
  `extension Branch { @MainActor func foo(_ s: Store) -> String? { s.rawView("branch", id)?["foo"]?.string } }`.
  `JSONValue.decode(T.self)` turns a raw object into your own type. The store keeps every entity raw,
  including entity types the client doesn't model.
- Optimistic overlays are made only by `Write.ops`. String unions are `OpenString` structs (`Gates.green`), so an
  unknown server value decodes instead of dropping the entity. An entity that fails to decode is
  dropped and listed in `store.decodeFailures` (shown by `--dump`).

## 7. Theme, fonts, big text

- `@Environment(\.theme) var theme`: `vellumNight/Raise/Edge`, `ink/inkDim/inkFaint`, `goldLeaf/Deep/Wash`,
  `ember(+Wash)`, `patina`, `rule`, `add/addBg`, `del/delBg`, `diffInk/diffBg`. `Theme.dark` is tokens.css
  value for value; `Theme.light` is the daylight counterpart. The default appearance is dark, like the web app.
- `Theme.mono(size, weight:)` is IBM Plex Mono (body 13), `Theme.display(size)` is Fraunces italic, and `Theme.nsMono` is for AppKit.
- **`CodeTextView`** (`Pages/Review/CodeTextView.swift`) is the seam for big code and diff views. It's a read-only
  NSTextView in an NSViewRepresentable; SwiftUI `Text` can't hold a 5k-line diff. The Review area grows it
  (attributed lines, gutters, line ↔ stop mapping, the cursor stop drawn as focus, the position under the cursor
  for `/lsp/*`), and Tutor reuses it. Because it's read-only it never takes the keyboard, so the diff's cursor is the
  pane cursor, driven by keys.

## 8. The six areas

Sizes are TypeScript lines (excluding tests). Every area owns its `Pages/<Folder>/` and its
`Tests/CanopyUITests/<Area>Tests.swift`.

### A. Forests: `Pages/Forests/` (~1,900)
The home (focus lane, workbench, archive fold, expanded branches, ready filter), one forest's page and its
story face, and the forest-level writes.
`Forests.tsx` 327 · `Forest.tsx` 161 · `Story.tsx` 96 · `LoopStrip.tsx` 52 · `loop.ts` 57 · `ship.ts` 171 ·
`integrate.ts` 52 · `drag.ts` 53 (→ key commands) · `motion.ts` 55 · `Key.tsx` 13 · `model.ts` 267 (projects,
forests, branchView, landedOf, rows) · `ui.ts` (forest bits) · `commands/project.ts` 374 · `commands/branch.ts` 364.
**Publishes** `ForestModel` (an `app.state` object: `forests`, `branchView(id)`, `stand`), which Ship reads.

### B. Review (the diff): `Pages/Review/` (~2,500)
The branch page's files tab: diff parsing, cursor stops, folds, split/unified view, base switch (`?base=`
via `router.replace`), file tree, viewed blocks, the map, code navigation (hover/definition/references/symbols via
`ask` + `app.nav`), and `CodeTextView`.
`review/Review.tsx` 552 · `review/page.ts` 463 · `review/diff.ts` 237 · `review/InlineDiff.tsx` 97 ·
`review/inline.ts` 45 · `review/side.ts` 42 · `review/highlight.ts` 43 · `review/Overlays.tsx` 153 ·
`review/types.ts` 206 · `review/TypesPop.tsx` 28 · `CodePane.tsx` 57 · `nav.ts` 126 (core done: `CodeNav`) ·
`commands/review.ts` diff half: `review.{down,up,thread.next/prev,file.*,cursor.set,extend,tab*,split,outdated,base.*,map*,filter,
expand,fold,leave,back,types,definition,type-definition,implementation,references,symbols,side.close,open,viewed*}`,
`inline.*`.
**Publishes** `ReviewPageState` (target branch, base, the stop under the cursor) and an LSP helper for Tutor.

### C. Ship and words: `Pages/Ship/` (~2,800)
Everything that gets a branch out the door, shown inside the review page through `ShipStripView`,
`ConversationPanel` and `CommitsPanel` (already referenced by `ReviewPage`, so B and C never edit each other's
files): sync/gates/prep/push, the conversation and threads, the review ledger (comment, compose, pending, send,
reply, resolve, apply suggestions, address), the words (description, outline, packet), and the commits/history tab.
`review/Ship.tsx` 417 · `review/Conversation.tsx` 102 · `review/Thread.tsx` 320 · `review/markdown.ts` 189 ·
`Commits.tsx` 347 · `syncing.ts` 122 · `gates.ts` 46 · `words.ts` 128 · `outlineHints.ts` 150 ·
`commands/sync.ts` 414 · `commands/words.ts` 111 · `commands/review.ts` ship half: `review.{push,words,history,address*,comment,gutter,
pending.*,compose.*,send*,reply,note.*,thread.show,resolve,apply,unapply,finish,preview,github}`, `history.*`, `commit.*`,
`branch.pr`, `branch.preview`, `forest.preview`.
**Publishes** a markdown renderer (from markdown.ts), which Wiki uses. The composer is a `ModalTextField` in insert mode.

### D. Tutor: `Pages/Tutor/` (~2,700)
The concept graph, sessions, the Socratic turn stream (`POST /tutor` via `streamPost`), the code pane
(reuses `CodeTextView` + B's LSP helper), the simulator.
`Tutor.tsx` 907 · `tutoring.ts` 344 · `lesson.ts` 329 · `TutorSim.tsx` 123 · `sim.ts` 381 · `simScenarios.ts` 240 ·
`commands/tutor.ts` 399.

### E. Machine, dashboard and tracker: `Pages/Machine/` + `Pages/Todo/` (~1,300)
Previews, servers, footprint, logs (the `procs` pulse); the telemetry dashboard vs budgets; the todo tracker.
`Machine.tsx` 364 · `workstation.ts` 167 · `commands/machine.ts` 257 · `Dashboard.tsx` 238 · `budgets.ts` 12 ·
`dashboard.range` (from `commands/app.ts`) · `Todo.tsx` 82 · `tracker.ts` 53 · `commands/todo.ts` 127.

### F. Wiki and the palette chrome: `Pages/Wiki/` + `Pages/Palette/` (~850, plus the chrome polish)
The wiki (page list, markdown via C's renderer, citations), and the shell overlays brought up to v2: the space menu
with finds (branches, forests, wiki pages, concepts from `/state?archived=1`), the `?` sheet's sections,
the picker, which-key. Also polishing the `:` completion list look and the statusline (logic stays in the shell).
`Wiki.tsx` 187 · `wikiread.ts` 43 · `wikitext.ts` 67 · `commands/wiki.ts` 75 · `Menu.tsx` 142 · `find.ts` 68 ·
`KeySheet.tsx` 145 · `Picker.tsx` 61 · `WhichKey.tsx` 49 · `pick.ts` 30 (core done).

**Cross-area seams.** B ↔ C go through the three Ship views on the review page and B's `ReviewPageState`.
A → C go through `ForestModel`. C → F go through the markdown renderer. B → D go through the LSP helper and `CodeTextView`. The publishing
area defines the type in its own folder; consumers only read it. Agree on a seam's signature before both sides build on it.

### G. Keytutor: `Pages/KeyTutor/` (native only)
`:keytutor` — the keys taught by doing in a practice app (`KeyTutorSandbox`: an AppModel on canned data behind
`KeyTutorStub`, with Ship's `openURL`/`copyText`, the remembered prefs and the Socratic sessions swapped out). The
host's `keys.nested` hands it every key on the keytutor page; `keys.onVerb` tells it which verb fired. A new verb
needs a lesson step (`KeyLessons`) or an entry in `KeyLessons.untaught` — `KeyTutorTests` fails otherwise. A page
that grows a new way to leave the process (open, copy, write a file) needs a seam the sandbox can swap.

## 9. Shared files

`Sources/CanopyCore/**`, `Sources/CanopyUI/Shell/**`, `Sources/CanopyUI/Theme/**`, `Package.swift`,
`canopy` and the existing tests are shared. Phase 2 shouldn't need to edit them. If one really must change
(a missing core capability, a bug), make it one small additive commit on its own, say so in your report,
and keep every other area green. Never change existing signatures. All v2 routes already exist in
`Route`, and every area is already registered in `Areas.all`.

## 10. Testing

- swift-testing (`import Testing`, `@Test`, `#expect`). UI-level tests build a whole app with no network:
  `AppModel(config: c, port: 1, telemetry: false)`. Every area is installed, so the app-wide key rules check
  your commands too. Drive it by key names: `a.keys.handle("g"); a.keys.handle("o")`.
- Store data in tests: `a.store.hydrate(try Snapshot.decode(data))` from a fixture you saved from a live GET.
- Writes: register through the runner against `Transport(base:protocolClasses: [Stub.self])` (see RunnerTests).
- `./canopy --dump` checks the live end-to-end path: hydrate, events, keys, modes, the keyboard rule, fonts.

## 11. Server contract notes (see API.md for the full list)

- **The actor.** The server's actor enum (`srv/actor.py`) has no native value, and an unknown `X-Stack-Actor` falls
  through to User-Agent sniffing and lands as `unknown`. We send `browser`: it's the actor that means
  Phil's hand, telemetry counts only it, and GitHub writes require it. A clean fix is a server change
  (add `native` to `ACTORS`, `HUMAN_ACTORS` and the ghreview gate). Then flip `Transport.actor`.
- **GitHub review writes will refuse from native** until the server changes. Beyond actor + `X-Stack-Via`,
  `srv/ghreview.py refusal()` requires `Sec-Fetch-Site: same-origin`, a header only browsers set. We
  deliberately don't forge it. The server needs a native allowance first. Until then sends stay local drafts
  (`ok:false`).
- Keys and the repo list come only from the HTML bootstrap script in `GET /v2` (`Bootstrap.parse`).
  There's no JSON endpoint for them.
- `/state` `repo.trunk` is the trunk's **SHA**; its name is `repo.main`. `conv.at` is a float (epoch seconds).
- Some "reads" write: `GET /gates-progress` (the green verdict), `GET /node` and `POST /integrate` (temporary
  `refs/stack/…` refs). Errors use `err` in most handlers and `error` in some; the runner reads both.

## 12. Phase 1 left unfinished, on purpose

- Every page is a placeholder except the Forests home's list (rows, `ret` to open) and the forest page's branch list.
- Telemetry posts `cmd`/`nav`/`registry`/`page` events (`app: "native"`); `feedbackMs` is time to the next
  main-runloop turn, a stand-in for v2's paint observer. There's no `contentPaint`.
- The app keeps its event stream open while hidden. v2 drops it on a hidden tab, which is a browser connection-cap concern.
  It reconnects with backoff and resyncs on wake like any other drop.
- One window. `AppModel` is per window, so a second window would need a second model and the stream doesn't support it yet.
