import type { SpineNode } from "./types";

export const NODE_H = 28;
export const leafOf = (s: string): string => s.split("/").pop() ?? s;
export const isGhostId = (id: string): boolean => id.startsWith("✦");
export const nodeW = (b: string): number => 50 + leafOf(b).length * 7.2 + 34;

// story-tree layout constants: one branch per row, indentation IS the parent edge.
// Fan-in routes through vertical rails in the right margin (RAIL_PAD past the widest
// node, RAIL_GAP apart), so PAD_R only clears the arrowhead + hover glow.
const ROW_H = 74, INDENT = 46, LEFT = 96, TOP = 64, PAD_R = 36, PAD_B = 56;
const RAIL_PAD = 24, RAIL_GAP = 13;

export function lumen(n: SpineNode): "stale" | "blessed" | "unblessed" {
  if (n.stale > 0) return "stale";
  if (n.total > 0 && n.clean === n.total) return "blessed";
  return "unblessed";
}

// Story-aligned tree layout: the map reads exactly like the merge-story text. Each branch
// is a ROW; a node's INDENT column clears its DEEPEST upstream — the parent chain gives
// the tree shape (a thin elbow guide, drawn always), and a `requires` fan-in pushes the
// dependent right of every base it carries, so indentation always means "lands after
// everything left of me". `requires` fan-in routes orthogonally through the right
// margin — each dependent owns one vertical rail there, every carried base stubs into
// it, and one arrow enters the dependent — so dense fan-in reads as a schematic bus,
// never curves crossing the map body. Sibling blocks are topo-sorted over cross-block
// requires, so the vertical order IS the landing order and a prerequisite sits above
// its dependent whenever the block graph allows it (a block-level cycle can still force
// an upward rail; the rail geometry handles either direction). The ghost culmination is a SINK, not a sibling: it
// never joins the tree, rendering instead as the last row seated back on main's own
// column — main's spine runs down into it (kind "spine") and the tips' work arcs in as
// "lands" edges — so the picture opens forking OFF main and closes landing ON it.
// Pure and deterministic.
export function computeForestLayout(model: { list: SpineNode[]; byId: Record<string, SpineNode> }) {
    const { list, byId } = model;
    const ids = list.map((n) => n.id);

    // rank = merge order authority (server's stack-merge-rank when present, else a longest-
    // path walk over parent + requires) — used ONLY to sort siblings, never for geometry.
    const rankCache: Record<string, number> = {};
    const rankOf = (id: string): number => {
      if (id === "main") return 0;
      const c = rankCache[id];
      if (c != null) return c;
      rankCache[id] = 1; // cycle guard while recursing
      const n = byId[id];
      if (n?.mergeRank != null) return (rankCache[id] = n.mergeRank);
      let r = 1;
      if (n) {
        const ups: string[] = [];
        if (n.parent && n.parent !== "main" && byId[n.parent]) ups.push(n.parent);
        (n.requires || []).forEach((rq) => { if (byId[rq]) ups.push(rq); });
        ups.forEach((u) => { r = Math.max(r, rankOf(u) + 1); });
      }
      return (rankCache[id] = r);
    };
    ids.forEach(rankOf);

    // the ✦ culmination is a sink, never a tree node — it leaves the root list entirely
    // and takes the sink seat after every work row is placed.
    const ghosts = list.filter((n) => isGhostId(n.id));
    const kids: Record<string, string[]> = {};
    const roots: string[] = [];
    list.forEach((n) => {
      if (isGhostId(n.id)) return;
      const p = n.parent && n.parent !== "main" && byId[n.parent] ? n.parent : "main";
      if (p === "main") roots.push(n.id);
      else (kids[p] ||= []).push(n.id);
    });
    const declared: Record<string, number> = {};
    ids.forEach((b, i) => (declared[b] = i));
    const order = (a: string, b: string) => rankOf(a) - rankOf(b) || declared[a] - declared[b];
    // A sibling's whole subtree renders as one contiguous block, so "vertical order is the
    // landing order" holds only if any block containing a prerequisite sorts above the block
    // whose member requires it. Rank alone can't see that (the block tops may tie — a rank-1
    // root can hide a rank-2 dependent), so topo-sort the blocks over cross-block requires,
    // tie-breaking with the plain comparator. Cycle (bad config) → comparator order.
    const members: Record<string, Set<string>> = {};
    const collect = (id: string): Set<string> => {
      const s = new Set([id]);
      (kids[id] || []).forEach((c) => collect(c).forEach((m) => s.add(m)));
      return (members[id] = s);
    };
    const sortBlocks = (siblings: string[]): string[] => {
      siblings.forEach(collect);
      const blockOf = (node: string) => siblings.find((s) => members[s].has(node));
      const before: Record<string, Set<string>> = {};
      siblings.forEach((s) => (before[s] = new Set()));
      siblings.forEach((s) => {
        members[s].forEach((m) => {
          (byId[m]?.requires || []).forEach((rq) => {
            const b = blockOf(rq);
            if (b && b !== s) before[s].add(b);
          });
        });
      });
      const sorted: string[] = [];
      const pending = [...siblings].sort(order);
      while (pending.length) {
        const i = pending.findIndex((s) => [...before[s]].every((b) => sorted.includes(b)));
        sorted.push(...pending.splice(Math.max(i, 0), 1));
      }
      return sorted;
    };
    roots.splice(0, roots.length, ...sortBlocks(roots));
    Object.keys(kids).forEach((p) => (kids[p] = sortBlocks(kids[p])));

    // DFS: row per node, indent per depth — parent always directly above its subtree.
    // Fan-in truth: a node's column clears EVERY upstream, so a `requires` base deeper
    // than the parent chain pushes the dependent (and its subtree) further right —
    // indentation reads "lands after everything left of me", not just "child of parent".
    // Block topo-sorting placed each prerequisite's row (hence depth) before its dependent.
    const pos: Record<string, { x: number; y: number }> = {};
    const depth: Record<string, number> = {};
    let row = 0;
    const place = (id: string, d: number) => {
      (byId[id]?.requires || []).forEach((rq) => {
        if (depth[rq] != null) d = Math.max(d, depth[rq] + 1);
      });
      depth[id] = d;
      pos[id] = { x: LEFT + d * INDENT, y: TOP + row * ROW_H };
      row++;
      (kids[id] || []).forEach((c) => place(c, d + 1));
    };
    roots.forEach((r) => place(r, 0));

    const mainPos = { x: LEFT - 62, y: TOP - ROW_H * 0.62 };
    // the sink seat: a breath below the last work row, back on main's own column — the
    // spine drop (mainPos.x) enters the ✦ row right above its name glyph (local x=16).
    const SINK_GAP = ROW_H * 0.4;
    ghosts.forEach((g) => {
      depth[g.id] = 0;
      pos[g.id] = { x: mainPos.x - 16, y: TOP + row * ROW_H + SINK_GAP };
      row++;
    });
    let maxX = mainPos.x + 60;
    list.forEach((n) => { if (pos[n.id]) maxX = Math.max(maxX, pos[n.id].x + nodeW(n.id)); });
    const H = TOP + row * ROW_H + (ghosts.length ? SINK_GAP : 0) + PAD_B;

    // Edges. Parent edges are ELBOW GUIDES (file-tree style): drop from the guardian's dot,
    // then turn into the child's left edge — geometry the renderer draws as M x1,y1 V y2 H x2.
    // The guardian is the parent node, or main for roots (main's spine runs down the left).
    // `requires` edges carry kind "fanin"; each dependent gets one vertical rail in the
    // right margin (laneX, assigned below) that all its carried bases run through.
    // The ✦ sink draws no parent elbow: main's spine continues straight down into it
    // (kind "spine"), and its synthetic requires — the tips the preview assembles — run
    // in as kind "lands", a different dependence than fan-in (bookkeeping, not merge-blocking).
    type Edge = { x1: number; y1: number; x2: number; y2: number; kind: string; from: string; to: string; laneX?: number; meta?: { carried: number; of: number } };
    const edges: Edge[] = [];
    list.forEach((n) => {
      const me = pos[n.id];
      if (!me) return;
      if (isGhostId(n.id)) {
        edges.push({
          x1: mainPos.x, y1: mainPos.y + 10, x2: mainPos.x, y2: me.y - NODE_H / 2 - 4,
          kind: "spine", from: "main", to: n.id,
        });
        (n.requires || []).forEach((rq) => {
          if (pos[rq]) {
            edges.push({
              x1: pos[rq].x + nodeW(rq) + 6, y1: pos[rq].y,
              x2: me.x + nodeW(n.id) + 6, y2: me.y,
              kind: "lands", from: rq, to: n.id,
            });
          }
        });
        return;
      }
      const p = n.parent && n.parent !== "main" && pos[n.parent] ? n.parent : "main";
      const gx = p === "main" ? mainPos.x : pos[p].x + 16; // drop from the dot column
      // start the drop BELOW the parent's purpose subtitle (two lines now) so it never strikes it.
      const gy = p === "main" ? mainPos.y + 10 : pos[p].y + NODE_H / 2 + (byId[p]?.description ? 31 : 4);
      edges.push({ x1: gx, y1: gy, x2: me.x - 7, y2: me.y, kind: lumen(n), from: p, to: n.id });
      const ancestors = new Set<string>();
      let x: string | undefined = n.parent, guard = 0;
      while (x && x !== "main" && byId[x] && guard++ < 64) { ancestors.add(x); x = byId[x].parent; }
      (n.requires || []).forEach((rq) => {
        if (pos[rq] && !ancestors.has(rq)) {
          edges.push({
            x1: pos[rq].x + nodeW(rq) + 6, y1: pos[rq].y,
            x2: me.x + nodeW(n.id) + 6, y2: me.y,
            kind: "fanin", from: rq, to: n.id, meta: n.requires_meta?.[rq],
          });
        }
      });
    });

    // Rail assignment: one vertical rail per fan-in dependent (the ✦ sink included),
    // inner rails to higher targets, every rail right of every node — a source stub only
    // ever crosses another rail at a right angle, never a node.
    const railTargets = [...new Set(edges.filter((e) => e.kind === "fanin" || e.kind === "lands").map((e) => e.to))]
      .sort((a, b) => pos[a].y - pos[b].y);
    railTargets.forEach((t, i) => {
      const laneX = maxX + RAIL_PAD + i * RAIL_GAP;
      edges.forEach((e) => { if (e.to === t && (e.kind === "fanin" || e.kind === "lands")) e.laneX = laneX; });
    });
    const W = (railTargets.length ? maxX + RAIL_PAD + (railTargets.length - 1) * RAIL_GAP : maxX) + PAD_R;

    return { list, pos, mainPos, W, H, edges };
}
