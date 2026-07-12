import type { SpineNode } from "./types";

export const NODE_H = 28;
export const leafOf = (s: string): string => s.split("/").pop() ?? s;
export const isGhostId = (id: string): boolean => id.startsWith("✦");
export const nodeW = (b: string): number => 50 + leafOf(b).length * 7.2 + 34;

// story-tree layout constants: one branch per row, indentation IS the parent edge.
const ROW_H = 74, INDENT = 46, LEFT = 96, TOP = 64, PAD_R = 150, PAD_B = 56;

export function lumen(n: SpineNode): "stale" | "blessed" | "unblessed" {
  if (n.stale > 0) return "stale";
  if (n.total > 0 && n.clean === n.total) return "blessed";
  return "unblessed";
}

// Story-aligned tree layout: the map reads exactly like the merge-story text. Each branch
// is a ROW; depth in the parent tree is an INDENT column, so the parent relationship is
// carried by geometry (a thin elbow guide, drawn always). `requires` fan-in never draws a
// resting edge — it renders as a ⤿ pill on the node and its edge appears only under the
// hover spotlight. Roots sort by merge rank so the vertical order IS the landing order;
// the ghost culmination sorts last (it's the destination, not work). Pure and deterministic.
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

    const kids: Record<string, string[]> = {};
    const roots: string[] = [];
    list.forEach((n) => {
      const p = n.parent && n.parent !== "main" && byId[n.parent] ? n.parent : "main";
      if (p === "main") roots.push(n.id);
      else (kids[p] ||= []).push(n.id);
    });
    const declared: Record<string, number> = {};
    ids.forEach((b, i) => (declared[b] = i));
    const order = (a: string, b: string) =>
      (isGhostId(a) ? 1 : 0) - (isGhostId(b) ? 1 : 0) ||
      rankOf(a) - rankOf(b) ||
      declared[a] - declared[b];
    roots.sort(order);
    Object.values(kids).forEach((c) => c.sort(order));

    // DFS: row per node, indent per depth — parent always directly above its subtree.
    const pos: Record<string, { x: number; y: number }> = {};
    const depth: Record<string, number> = {};
    let row = 0;
    const place = (id: string, d: number) => {
      depth[id] = d;
      pos[id] = { x: LEFT + d * INDENT, y: TOP + row * ROW_H };
      row++;
      (kids[id] || []).forEach((c) => place(c, d + 1));
    };
    roots.forEach((r) => place(r, 0));

    const mainPos = { x: LEFT - 62, y: TOP - ROW_H * 0.62 };
    // the ⤿ fan-in pill rides OUTSIDE the node rect, so it counts toward the canvas width.
    const reqPillW = (n: SpineNode): number => {
      const names = (n.requires || []).filter((r) => pos[r]).map(leafOf).join(" · ");
      return names ? (8 + names.length) * 5.8 + 26 : 0;
    };
    let maxX = mainPos.x + 60;
    list.forEach((n) => { if (pos[n.id]) maxX = Math.max(maxX, pos[n.id].x + nodeW(n.id) + reqPillW(n)); });
    const W = maxX + PAD_R;
    const H = TOP + row * ROW_H + PAD_B;

    // Edges. Parent edges are ELBOW GUIDES (file-tree style): drop from the guardian's dot,
    // then turn into the child's left edge — geometry the renderer draws as M x1,y1 V y2 H x2.
    // The guardian is the parent node, or main for roots (main's spine runs down the left).
    // `requires` edges carry kind "fanin" and their own right-side lane geometry; the
    // renderer shows them only when the hover spotlight lights both ends.
    type Edge = { x1: number; y1: number; x2: number; y2: number; kind: string; from: string; to: string };
    const edges: Edge[] = [];
    list.forEach((n) => {
      const me = pos[n.id];
      if (!me) return;
      const p = n.parent && n.parent !== "main" && pos[n.parent] ? n.parent : "main";
      const gx = p === "main" ? mainPos.x : pos[p].x + 16; // drop from the dot column
      // start the drop BELOW the parent's purpose subtitle so the guide never strikes it.
      const gy = p === "main" ? mainPos.y + 10 : pos[p].y + NODE_H / 2 + (byId[p]?.description ? 21 : 4);
      edges.push({ x1: gx, y1: gy, x2: me.x - 7, y2: me.y, kind: lumen(n), from: p, to: n.id });
      const ancestors = new Set<string>();
      let x: string | undefined = n.parent, guard = 0;
      while (x && x !== "main" && byId[x] && guard++ < 64) { ancestors.add(x); x = byId[x].parent; }
      (n.requires || []).forEach((rq) => {
        if (pos[rq] && !ancestors.has(rq)) {
          edges.push({
            x1: pos[rq].x + nodeW(rq) + 6, y1: pos[rq].y,
            x2: me.x + nodeW(n.id) + 6, y2: me.y,
            kind: "fanin", from: rq, to: n.id,
          });
        }
      });
    });

    return { list, pos, mainPos, W, H, edges };
}
