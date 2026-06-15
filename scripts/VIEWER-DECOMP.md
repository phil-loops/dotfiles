# Stack-review viewer — decomposition plan

**Problem.** `stack-review-html.tpl.py` is a ~490-line god-file: one Python wrapper
emitting a single HTML string that bundles CSS + shell + data layer + 3 views +
all interactions. Every feature — graph, detail, blessing, fan-in edges — lands in
that one file, so concurrent work collides (the `requires` support got clobbered
once already). The contention is the symptom; the file doing too much is the cause.

**Target.** Split by concern so the graph and the detail panel are *separate files*
two people can edit without touching each other — and so the "graph-is-main,
detail-is-accessory" model is just a file boundary, not a tangle.

```
scripts/viewer/
  shell.html     minimal skeleton: <head> assets, #dock / #rail / #detail containers, wiring
  styles.css     ALL css (vars, layout grid, rail, detail/file-cards, graph .ge/.gn)
  data.js        model + /sig polling, lazy /node diffs (NODEPATCH), bless API, shared state
  graph.js       THE MAIN VIEW — graphModel, edge, renderGraph, place; node-click → opens detail
  detail.js      THE ACCESSORY — file cards, diff2html, bless buttons, purpose; esc to close
```
`tpl.py` (or the server) becomes a thin injector: serve `shell.html`, inject the
model as `window.__MODEL__`, load the static assets.

## What moves where (current → module)

| current (in tpl.py) | → module |
|---|---|
| `:root` vars, body grid, grain/vignette, `.rail`, `.file`/`.chip`, `.ge`/`.gn` | **styles.css** |
| `fetchModel`, `ensureNode`/`NODEPATCH`, `doBless`, `/sig` polling, `MODEL`/`NODES`, `flatten`, `subtree`, `rollStatus` | **data.js** |
| `graphModel`, `edge`, `renderGraph`, `place`, the `#dock` graph render | **graph.js** |
| file-card render, diff2html mount, `fulltoggle`, `doBless` buttons, purpose callout, rail list | **detail.js** |
| `<head>`, dock/rail/detail containers, key handlers, graph↔detail wiring | **shell.html** |

## The decoupling contract (the whole point)

- **data.js** owns ALL fetch + state. Exposes: `state.model`, `state.nodes`,
  `getModel()`, `getNodeDiffs(branch)`, `bless(branch,file)`, `onChange(cb)`
  (pub/sub fired on `/sig`). Nobody else calls `fetch`.
- **graph.js** is a pure view: `renderGraph(container)` reads from `state`, emits a
  `selectNode(branch)` event on click. **Reads each node's OWN `clean/total`, not a
  subtree rollup** (Phil only cares about this branch's changes). A node whose own
  `clean===total>0` gets a `.done` class (solid gold / ✓, no count).
- **detail.js** is the accessory: `openDetail(branch)` mounts an overlay from
  `getNodeDiffs(branch)`; `closeDetail()` on `esc`. Calls `data.bless`. Never reaches
  into the graph.
- **shell.html** wires it: graph's `selectNode` → `openDetail`; `esc` → `closeDetail`.

Because the graph never imports the detail and vice-versa (they only meet through
`data` + two events), the two can be edited in parallel. Collision gone.

## Migration (incremental — each step ships & is reversible)

1. **Extract `styles.css`** — cut the `<style>` block to a file, `<link>` it. Zero
   logic risk; immediately drops ~150 lines from the monolith.
2. **Extract `data.js`** — move fetch/state/poll/bless + flatten/subtree/rollStatus.
   Everything else calls into it.
3. **Extract `graph.js`** — move the graph render; have it emit `selectNode`.
4. **Extract `detail.js`** — move file cards + diff + bless buttons behind
   `openDetail/closeDetail`.
5. **`shell.html` / thin `tpl.py`** — skeleton + asset tags + wiring only.

Server (`stack-review-server.py`): already serves `/model`, `/node`, `/bless`,
`/sig`; just add static serving for `viewer/*.{css,js,html}`.

## Why this is the right next move

The 3 pending UX changes become *local and trivial* once split:
- **own count, not rollup** → one line in graph.js's node label.
- **"done" status** → one `.done` class in graph.js.
- **graph main / detail accessory** → it *is* the file boundary (graph renders on
  load; detail mounts as overlay).

Doing these in the monolith first just grows the god-file and the contention. Split
first, then the features fall in cleanly — and two sessions stop fighting over one file.
