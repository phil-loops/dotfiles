import type { SpineNode } from "./types";

export const NODE_H = 28;
export const leafOf = (s: string): string => s.split("/").pop() ?? s;
export const isGhostId = (id: string): boolean => id.startsWith("✦");
export const nodeW = (b: string): number => 50 + leafOf(b).length * 7.2 + 34;

// layout constants. COLW/ROWH = x/y advance per rank step (their ratio sets the diagonal's
// slope); REST = the spring's natural edge length (≈ one column); SPRING = stiffness;
// RANKK = pull toward each node's diagonal slot.
const COLW = 186, ROWH = 150, REP = 180, REST = 186, SPRING = 0.5, K = 150, RANKK = 0.3, CUT = 340, ITER = 480, PAD = 72;

export function lumen(n: SpineNode): "stale" | "blessed" | "unblessed" {
  if (n.stale > 0) return "stale";
  if (n.total > 0 && n.clean === n.total) return "blessed";
  return "unblessed";
}

// Force-directed forest layout: rank each node by longest upstream path from main, seed on the
// diagonal, then relax X with repulsion + rest-length edge springs + a hard per-lane no-overlap
// sweep. Returns node positions, canvas size, and the routed edges. Pure — one call per model.
export function computeForestLayout(model: { list: SpineNode[]; byId: Record<string, SpineNode> }) {
    const { list, byId } = model;
    const ids = list.map((n) => n.id);

    // rank = longest path from main over upstream edges (parent + requires). Prefer the
    // server's mergeRank (the shared stack-merge-rank authority, so the map agrees with the
    // story + pr-body) and fall back to the local walk for nodes /model didn't rank — the
    // ghost culmination especially (parent=main but requires the deep tips), which ranks PAST
    // them instead of collapsing to depth 0 so it lands at the far end of the diagonal. main = 0.
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

    // the endstate: the single culmination the forest builds toward — the highest-rank
    // node (the ghost ✦ when multi-tip, else the deepest tip). Pinned bottom-right as
    // the mirror of main's pinned top-left.
    let endId: string | null = null;
    ids.forEach((b) => { if (endId === null || rankCache[b] > rankCache[endId]) endId = b; });

    // seed each node in its rank lane (Y = rank·ROWH, fixed); X starts on the diagonal slot
    // jittered off it deterministically (no Math.random) to break symmetry before the relax.
    // main + endstate are fixed anchors.
    const diagOf = (id: string) => ({ x: (rankCache[id] || 0) * COLW, y: (rankCache[id] || 0) * ROWH });
    const P: Record<string, { x: number; y: number }> = {};
    ids.forEach((b, i) => {
      const d = diagOf(b);
      P[b] = { x: d.x + ((i * 37) % 90) - 45, y: d.y };
    });
    const MAIN = { x: 0, y: 0 };
    if (endId) P[endId] = diagOf(endId); // pin the endstate exactly on the diagonal's far corner
    const wOf = (id: string) => (id === "main" ? 40 : nodeW(id));
    const at = (id: string) => (id === "main" ? MAIN : P[id]);

    const links: [string, string][] = [];
    ids.forEach((b) => {
      const p = byId[b].parent;
      links.push([p && p !== "main" && byId[p] ? p : "main", b]);
      (byId[b].requires || []).forEach((r) => { if (byId[r] && r !== b) links.push([r, b]); });
    });

    let temp = K * 1.6;
    for (let it = 0; it < ITER; it++) {
      // keep the endstate parked just past the RIGHT edge of everything else, so it reads as
      // the destination corner no matter how wide the fan-in spreads (its rank lane already
      // pins it to the bottom). Recomputed as the field settles.
      if (endId) {
        let mx = -Infinity;
        for (const b of ids) {
          if (b === endId) continue;
          if (P[b].x > mx) mx = P[b].x;
        }
        if (mx > -Infinity) P[endId] = { x: mx + COLW * 0.8, y: diagOf(endId).y };
      }
      const dsp: Record<string, { x: number; y: number }> = {};
      ids.forEach((b) => (dsp[b] = { x: 0, y: 0 }));
      // separation: pairwise repulsion (hard shove out of overlap).
      for (let i = 0; i < ids.length; i++) {
        for (let j = i + 1; j < ids.length; j++) {
          const A = P[ids[i]], B = P[ids[j]];
          let dx = A.x - B.x, dy = A.y - B.y;
          const d = Math.hypot(dx, dy) || 0.01;
          const minD = (wOf(ids[i]) + wOf(ids[j])) / 2 + 80;
          if (d > CUT && d > minD) continue;
          const f = (REP * REP) / d * (d < minD ? 6 : 1);
          dx /= d; dy /= d;
          dsp[ids[i]].x += dx * f; dsp[ids[i]].y += dy * f;
          dsp[ids[j]].x -= dx * f; dsp[ids[j]].y -= dy * f;
        }
      }
      // keep nodes clear of the pinned main anchor: main repels but never moves, so
      // roots don't collapse on top of it under edge cohesion.
      ids.forEach((b) => {
        const dx = P[b].x - MAIN.x, dy = P[b].y - MAIN.y;
        const d = Math.hypot(dx, dy) || 0.01;
        const minD = (wOf(b) + 40) / 2 + 120;
        if (d < CUT || d < minD) {
          const f = (REP * REP) / d * (d < minD ? 6 : 1);
          dsp[b].x += (dx / d) * f; dsp[b].y += (dy / d) * f;
        }
      });
      // diagonal rank bias: pull each node toward its (rank·COLW, rank·ROWH) slot so the
      // sequence flows top-left → bottom-right (the rest-length springs do the spacing).
      ids.forEach((b) => {
        const d = diagOf(b);
        dsp[b].x += (d.x - P[b].x) * RANKK;
        dsp[b].y += (d.y - P[b].y) * RANKK;
      });
      // cohesion: rest-length springs — zero force at REST, attract beyond, repel within,
      // so connected nodes settle ~one column apart instead of collapsing together. main pinned.
      links.forEach(([u, v]) => {
        const A = at(u), B = at(v);
        const dx = B.x - A.x, dy = B.y - A.y, d = Math.hypot(dx, dy) || 0.01;
        const f = ((d - REST) / d) * SPRING;
        if (u !== "main") { dsp[u].x += dx * f; dsp[u].y += dy * f; }
        if (v !== "main") { dsp[v].x -= dx * f; dsp[v].y -= dy * f; }
      });
      ids.forEach((b) => {
        if (b === endId) return; // pinned bottom-right anchor — never moves
        const m = Math.hypot(dsp[b].x, dsp[b].y) || 0.01, s = Math.min(m, temp) / m;
        P[b].x += dsp[b].x * s;
        P[b].y = diagOf(b).y; // Y stays in its rank lane — only X relaxes
        // keep everything right of main so main stays the top-left anchor.
        if (P[b].x < 56) P[b].x = 56;
      });
      temp *= 0.985;
    }

    // The diagonal bias pulls every same-rank node toward one x slot, so a wide fan-out settles
    // as a pile pairwise repulsion can't fully separate. Enforce the hard no-overlap constraint
    // the force field only approximates: within each rank lane, sweep left→right and shove
    // siblings apart by their half-widths, then recenter the lane on its original mean so it
    // keeps the x the field chose for it (spreads both ways, doesn't drift right).
    const byRank: Record<number, string[]> = {};
    ids.forEach((b) => { if (b !== endId) (byRank[rankCache[b] || 0] ||= []).push(b); });
    Object.values(byRank).forEach((lane) => {
      if (lane.length < 2) return;
      lane.sort((a, b) => P[a].x - P[b].x);
      const mean0 = lane.reduce((s, b) => s + P[b].x, 0) / lane.length;
      for (let i = 1; i < lane.length; i++) {
        const prev = lane[i - 1], cur = lane[i];
        const minGap = wOf(prev) / 2 + wOf(cur) / 2 + 30;
        if (P[cur].x - P[prev].x < minGap) P[cur].x = P[prev].x + minGap;
      }
      const shift = mean0 - lane.reduce((s, b) => s + P[b].x, 0) / lane.length;
      lane.forEach((b) => (P[b].x += shift));
    });
    // re-pin the endstate just past everything once the lanes have spread, so it stays the corner.
    if (endId) {
      let mx = -Infinity;
      for (const b of ids) { if (b === endId) continue; if (P[b].x > mx) mx = P[b].x; }
      if (mx > -Infinity) P[endId] = { x: mx + COLW * 0.8, y: diagOf(endId).y };
    }

    // pack into the canvas with main at the top-left corner.
    let minX = MAIN.x - 8, maxX = MAIN.x + 46, minY = MAIN.y - 14, maxY = MAIN.y + 14;
    ids.forEach((b) => {
      const hw = nodeW(b) / 2;
      minX = Math.min(minX, P[b].x - hw); maxX = Math.max(maxX, P[b].x + hw);
      minY = Math.min(minY, P[b].y - 16); maxY = Math.max(maxY, P[b].y + 16);
    });
    const ox = PAD - minX, oy = PAD - minY;
    const pos: Record<string, { x: number; y: number }> = {};
    ids.forEach((b) => { pos[b] = { x: P[b].x + ox - nodeW(b) / 2, y: P[b].y + oy }; });
    const mainPos = { x: MAIN.x + ox, y: MAIN.y + oy };
    const W = (maxX - minX) + PAD * 2, H = (maxY - minY) + PAD * 2;

    const cx = (b: string) => pos[b].x + nodeW(b) / 2;
    const cy = (b: string) => pos[b].y;

    type Edge = { x1: number; y1: number; x2: number; y2: number; kind: string; from: string; to: string };
    const edges: Edge[] = [];
    list.forEach((n) => {
      // main→root spokes, but NOT to the ghost endstate — it reaches the map via its
      // fan-in edges, so a straight main→ghost line across the whole canvas is noise.
      if (n.depth === 0 && pos[n.id] && !isGhostId(n.id)) {
        edges.push({ x1: mainPos.x, y1: mainPos.y + 6, x2: cx(n.id), y2: cy(n.id) - NODE_H / 2, kind: lumen(n), from: "main", to: n.id });
      }
      const p = n.parent;
      if (p && p !== "main" && pos[p] && pos[n.id]) {
        edges.push({ x1: cx(p), y1: cy(p) + NODE_H / 2, x2: cx(n.id), y2: cy(n.id) - NODE_H / 2, kind: lumen(n), from: p, to: n.id });
      }
      const ancestors = new Set<string>();
      let x: string | undefined = n.parent, guard = 0;
      while (x && x !== "main" && byId[x] && guard++ < 64) { ancestors.add(x); x = byId[x].parent; }
      (n.requires || []).forEach((rq) => {
        if (pos[rq] && pos[n.id] && !ancestors.has(rq)) {
          edges.push({ x1: cx(rq), y1: cy(rq) + NODE_H / 2, x2: cx(n.id), y2: cy(n.id) - NODE_H / 2, kind: "fanin", from: rq, to: n.id });
        }
      });
    });

    return { list, pos, mainPos, W, H, edges };
}
