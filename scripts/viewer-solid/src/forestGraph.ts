import type { SpineNode } from "./types";
// .ts suffix: this module is imported by `node --test` too, and node's ESM resolver needs the
// real filename — vite and tsgo (allowImportingTsExtensions) both take it as-is.
import { isGhostId } from "./forestLayout.ts";

// Pure graph reads over the spine — the DAG questions the map asks before it draws anything:
// who's a tip, what must land first, what does this drag down with it, and what the shape
// becomes once a node contracts. Kept solid-free (and out of the component) so each one is
// checkable in `node --test` against a hand-built list; ForestMap wraps them in memos.

export type Spine = { list: SpineNode[]; byId: Record<string, SpineNode> };

export const indexById = (list: SpineNode[]): Spine => {
  const byId: Record<string, SpineNode> = {};
  list.forEach((n) => (byId[n.id] = n));
  return { list, byId };
};

// Mirror a server-side contraction: the node goes, its children inherit its nearest surviving
// ancestor, and any `requires` naming it loses that edge — the same rewire /contract performs.
export function contractNodes(list: SpineNode[], gone: ReadonlySet<string>): SpineNode[] {
  if (!gone.size) return list;
  const parentOf = new Map(list.map((n) => [n.id, n.parent]));
  const heir = (p: string | undefined, guard = 0): string | undefined =>
    p && gone.has(p) && guard < 64 ? heir(parentOf.get(p), guard + 1) : p;
  return list.filter((n) => !gone.has(n.id)).map((n) => ({
    ...n,
    parent: heir(n.parent),
    ...(n.requires ? { requires: n.requires.filter((r) => !gone.has(r)) } : {}),
  }));
}

// heads: the TIP of each substack — a branch nothing else builds on (nobody's parent,
// nobody's `requires`). These are the leaves you'd actually check out; everything else
// is interior plumbing. The ghost endstate is excluded (it's a destination, not a tip).
export function headsOf(list: SpineNode[]): Set<string> {
  const hasChild = new Set<string>();
  list.forEach((n) => {
    if (n.parent && n.parent !== "main") hasChild.add(n.parent);
    (n.requires || []).forEach((r) => hasChild.add(r));
  });
  const h = new Set<string>();
  list.forEach((n) => { if (!isGhostId(n.id) && !hasChild.has(n.id)) h.add(n.id); });
  return h;
}

// upstream: the parent chain + the transitive `requires` (fan-in) closure — everything that
// must merge before this branch can. downstream: the transitive dependents (branches whose
// parent IS this, or that `require` it).
export function upstreamOf(byId: Record<string, SpineNode>, id: string): Set<string> {
  const seen = new Set<string>();
  const visit = (x: string) => {
    const n = byId[x];
    if (!n) return;
    const ups: string[] = [];
    if (n.parent && byId[n.parent]) ups.push(n.parent);
    (n.requires || []).forEach((r) => { if (byId[r]) ups.push(r); });
    ups.forEach((u) => { if (!seen.has(u)) { seen.add(u); visit(u); } });
  };
  visit(id);
  return seen;
}

export function downstreamOf(list: SpineNode[], id: string): Set<string> {
  const seen = new Set<string>();
  const q = [id];
  while (q.length) {
    const x = q.shift()!;
    list.forEach((n) => {
      if (seen.has(n.id)) return;
      if (n.parent === x || (n.requires || []).includes(x)) { seen.add(n.id); q.push(n.id); }
    });
  }
  seen.delete(id);
  return seen;
}

// CHEAP dirty-conflict "dams". A node with uncommitted (tracked) working-tree changes whose
// paths collide with a DOWNSTREAM node's OWN diff is a dam: once that dirt commits, those
// descendants conflict on rebase. A dam freezes the flow to its WHOLE downstream subtree —
// everything below is built on a world about to shift. File-overlap only (no merge attempt):
// honest "potential", instant, recomputed each render. `frozen` = nodes whose inbound edge is dead.
export function computeDams(list: SpineNode[], byId: Record<string, SpineNode>) {
  const damSet = new Set<string>();
  const conflictSet = new Set<string>();
  const frozen = new Set<string>();
  const dirtyOf = (id: string) => byId[id]?.dirty ?? [];
  const ownPaths = (id: string) => (byId[id]?.files ?? []).map((f) => f.path);
  list.forEach((n) => {
    const d = dirtyOf(n.id);
    if (!d.length) return;
    const dset = new Set(d);
    const down = downstreamOf(list, n.id);
    let active = false;
    down.forEach((c) => {
      if (ownPaths(c).some((p) => dset.has(p))) { conflictSet.add(c); active = true; }
    });
    if (active) {
      damSet.add(n.id);
      down.forEach((c) => frozen.add(c));
    }
  });
  return { damSet, conflictSet, frozen, dirtyOf };
}
