# Chat overview — make threads discoverable across the forest

**Status:** spec / not built. Requested by Phil. Authored by the `drain-batch-settings`
session 2026-06-22 while another session held uncommitted `viewer-solid` WIP — so this is
a durable hand-off, not a patch. Build it **on top of the committed viewer rewrite**, not on
the HEAD this was written against (the rewrite restructures the three surfaces below).

## Problem

Chat threads are keyed by `branch + path` and persisted to `localStorage`, but a thread is
only ever surfaced when you reopen that exact file's `✦ chat` drawer. So a conversation is
invisible unless you remember which file you had it on. Goal: see chats **generally** —
spot where they exist, and browse/return to them.

Phil chose **both**: per-node badges **and** a browsable index panel.

## Current model (in `src/chatStore.ts`)

- `interface Thread { msgs: Msg[]; session: string }` — `session` is the `claude --resume` id.
- `interface Msg { role: "you" | "claude"; text: string }`.
- `const [threads, setThreads] = createStore<Record<string, Thread>>(...)` — reactive store,
  keyed by `keyOf(branch, path)` = `` `${branch} ${path}` `` (branch names have no spaces).
- `order: string[]` — a **plain, non-reactive** module array used as write-LRU for eviction
  (`MAX_THREADS = 60`). Do **not** drive UI off `order` — it won't trigger Solid updates.
- Mirrored to `localStorage` key `viewer.chat.threads.v1`, debounced.
- Opened via `ChatPanel.tsx` (per-file drawer).

## Build

### 1. `chatStore.ts` — additive data layer (low collision)

- Add `writtenAt: number` to `Thread`; stamp it in `touch()` / `appendMsg()` (`Date.now()`).
  Default to `0` when loading old persisted threads that lack it.
- Export a reactive summary read:
  ```ts
  export interface ChatSummary {
    branch: string;
    path: string;
    count: number;          // msgs.length
    last: Msg | undefined;  // msgs.at(-1)
    writtenAt: number;
  }
  export function chatSummaries(): ChatSummary[]   // derive from `threads` (reactive), sort by writtenAt desc
  ```
  Reconstruct `branch`/`path` by splitting the key on the **first space**
  (`const i = k.indexOf(" ")`), since paths may contain spaces but branches don't.
  Iterate `Object.keys(threads)` so the read is reactive — never `order`.
- Export `export function threadMsgCount(branch, path): number` for the badge
  (`threads[keyOf(branch, path)]?.msgs.length ?? 0`).
- Skip empty threads (`count === 0`) in both — `thread()` lazily creates empties on read.

### 2. Badges — on the tree nodes

- `💬 N` on any **file** node with `threadMsgCount(branch, path) > 0`.
- On a **branch** node, sum its files' counts (`chatSummaries().filter(s => s.branch === b)`).
- Pure store reads → reactive automatically. Style next to the existing fork-state badge.

### 3. `ChatIndex.tsx` — new file (collision-free), the panel

- Collapsible panel toggled from the header/rail (a `💬 chats (N)` toggle).
- Rows from `chatSummaries()`, **grouped by branch**:
  `file · N msgs · "<last snippet>" · <relative time from writtenAt>`.
- Click a row → open that file's existing `ChatPanel` drawer (reuse the current open path /
  selection mechanism — set the same branch+path the drawer keys on).
- Empty state when there are no threads.

## Scope / gotchas

- **localStorage-scoped** — "all chats" = all chats *in this browser*, not server-side/shared.
  Same as today; don't imply otherwise in the UI.
- Reactivity: derive from the `threads` store, **not** `order`.
- The `MAX_THREADS = 60` LRU already bounds growth — the index inherits that bound.
- Keep it read-only over the store (open/browse); no new mutation surface needed.
