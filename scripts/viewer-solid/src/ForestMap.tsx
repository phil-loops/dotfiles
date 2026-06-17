// ForestMap — the forest DAG as an SVG, laid out with a deterministic BOIDS /
// force-directed relaxation: nodes repel (separation), edges pull together
// (cohesion), and `main` is a pinned anchor everything settles around. Seeded
// from a golden-angle spiral + a fixed iteration count (NO requestAnimationFrame
// loop), so the map is organic but never jitters or shifts between renders —
// deep stacks curl into 2D instead of running off the right edge.
//
// Edges + nodes flock in with a staggered animation-delay. Fully self-contained
// (own class names + <style>), so it drops into App.tsx with one import + the
// existing <ForestMap …/> mount — zero shared CSS or lines.
import { createMemo, For, Show } from "solid-js";
import type { SpineNode } from "./types";

const leafOf = (s: string): string => s.split("/").pop() ?? s;
const nodeW = (b: string): number => 50 + leafOf(b).length * 7.2 + 34;
const NODE_H = 28;
function lumen(n: SpineNode): "stale" | "blessed" | "unblessed" {
  if (n.stale > 0) return "stale";
  if (n.total > 0 && n.clean === n.total) return "blessed";
  return "unblessed";
}

// Force-layout constants (ported from the vanilla viewer's tuned values).
const K = 140, REP = 210, GRAV = 0.18, CUT = 470, ITER = 520, PAD = 72;

export function ForestMap(props: {
  spine: () => SpineNode[];
  active: () => string;
  onPick: (b: string) => void;
  onClose: () => void;
}) {
  const layout = createMemo(() => {
    const list = props.spine();
    const ids = list.map((n) => n.id);
    const byId: Record<string, SpineNode> = {};
    list.forEach((n) => (byId[n.id] = n));

    // seed: golden-angle spiral (deterministic — same input → same picture).
    const P: Record<string, { x: number; y: number }> = {};
    ids.forEach((b, i) => {
      const a = i * 2.39996323, r = 26 + 20 * Math.sqrt(i + 1);
      P[b] = { x: Math.cos(a) * r, y: Math.sin(a) * r };
    });
    const MAIN = { x: 0, y: 0 };
    const wOf = (id: string) => (id === "main" ? 40 : nodeW(id));
    const at = (id: string) => (id === "main" ? MAIN : P[id]);

    // links drive cohesion: a parent rail per node (→ main if rootless) + fan-ins.
    const links: [string, string][] = [];
    ids.forEach((b) => {
      const p = byId[b].parent;
      links.push([p && p !== "main" && byId[p] ? p : "main", b]);
      (byId[b].requires || []).forEach((r) => {
        if (byId[r] && r !== b) links.push([r, b]);
      });
    });

    let temp = K * 1.8;
    for (let it = 0; it < ITER; it++) {
      const dsp: Record<string, { x: number; y: number }> = {};
      ids.forEach((b) => (dsp[b] = { x: 0, y: 0 }));
      // separation: pairwise repulsion, with a hard shove out of overlap.
      for (let i = 0; i < ids.length; i++) {
        for (let j = i + 1; j < ids.length; j++) {
          const A = P[ids[i]], B = P[ids[j]];
          let dx = A.x - B.x, dy = A.y - B.y;
          const d = Math.hypot(dx, dy) || 0.01;
          const minD = (wOf(ids[i]) + wOf(ids[j])) / 2 + 90;
          if (d > CUT && d > minD) continue; // beyond the cutoff, let gravity win
          const f = (REP * REP) / d * (d < minD ? 7 : 1);
          dx /= d; dy /= d;
          dsp[ids[i]].x += dx * f; dsp[ids[i]].y += dy * f;
          dsp[ids[j]].x -= dx * f; dsp[ids[j]].y -= dy * f;
        }
      }
      // gravity: pull the whole chain inward into a ball.
      ids.forEach((b) => { dsp[b].x -= P[b].x * GRAV; dsp[b].y -= P[b].y * GRAV; });
      // cohesion: edges act as springs (main is pinned, so it only pulls others).
      links.forEach(([u, v]) => {
        const A = at(u), B = at(v);
        const dx = B.x - A.x, dy = B.y - A.y, d = Math.hypot(dx, dy) || 0.01, fa = d / K;
        if (u !== "main") { dsp[u].x += dx * fa; dsp[u].y += dy * fa; }
        if (v !== "main") { dsp[v].x -= dx * fa; dsp[v].y -= dy * fa; }
      });
      // integrate, capped by the cooling temperature.
      ids.forEach((b) => {
        const m = Math.hypot(dsp[b].x, dsp[b].y) || 0.01, s = Math.min(m, temp) / m;
        P[b].x += dsp[b].x * s; P[b].y += dsp[b].y * s;
      });
      temp *= 0.985;
    }

    // pack into the canvas: bbox over node extents (+ main), shift into PAD margins.
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

    // straight center-to-center connectors (the force layout drops the old L→R axis).
    type Edge = { x1: number; y1: number; x2: number; y2: number; kind: string };
    const edges: Edge[] = [];
    list.forEach((n) => {
      if (n.depth === 0 && pos[n.id]) {
        edges.push({ x1: mainPos.x, y1: mainPos.y, x2: cx(n.id), y2: cy(n.id), kind: lumen(n) });
      }
      const p = n.parent;
      if (p && p !== "main" && pos[p] && pos[n.id]) {
        edges.push({ x1: cx(p), y1: cy(p), x2: cx(n.id), y2: cy(n.id), kind: lumen(n) });
      }
      // fan-in: dashed planned edge, unless the dep is already an ancestor on the rail.
      const ancestors = new Set<string>();
      let x: string | undefined = n.parent, guard = 0;
      while (x && x !== "main" && byId[x] && guard++ < 64) { ancestors.add(x); x = byId[x].parent; }
      (n.requires || []).forEach((rq) => {
        if (pos[rq] && pos[n.id] && !ancestors.has(rq)) {
          edges.push({ x1: cx(rq), y1: cy(rq), x2: cx(n.id), y2: cy(n.id), kind: "fanin" });
        }
      });
    });

    return { list, pos, mainPos, W, H, edges };
  });

  return (
    <div class="fm-overlay" onClick={() => props.onClose()}>
      <style>{CSS}</style>
      <svg
        class="fm-svg"
        viewBox={`0 0 ${layout().W} ${layout().H}`}
        width={layout().W}
        height={layout().H}
        preserveAspectRatio="xMidYMid meet"
        onClick={(e) => e.stopPropagation()}
      >
        <For each={layout().edges}>
          {(e, i) => (
            <path
              class={`fm-edge ${e.kind}`}
              style={{ "animation-delay": `${i() * 40}ms` }}
              d={`M${e.x1},${e.y1} L${e.x2},${e.y2}`}
            />
          )}
        </For>
        <g class="fm-node fm-main" style={{ "animation-delay": "80ms" }}
           transform={`translate(${layout().mainPos.x},${layout().mainPos.y})`}>
          <circle r="6" />
          <text x="16" y="4">main</text>
        </g>
        <For each={layout().list}>
          {(n, i) => {
            const p = () => layout().pos[n.id];
            const w = nodeW(n.id);
            return (
              <Show when={p()}>
                <g
                  class={`fm-node ${lumen(n)}`}
                  classList={{ active: n.id === props.active() }}
                  style={{ "animation-delay": `${120 + i() * 45}ms` }}
                  transform={`translate(${p().x},${p().y})`}
                  onClick={() => props.onPick(n.id)}
                >
                  <rect x="0" y={-NODE_H / 2} rx="8" width={w} height={NODE_H} />
                  <circle class="dot" cx="16" cy="0" r="5" />
                  <text x="30" y="4.5">{leafOf(n.id)}</text>
                  <text class="cnt" x={w - 12} y="4.5">{n.clean}/{n.total}</text>
                </g>
              </Show>
            );
          }}
        </For>
      </svg>
    </div>
  );
}

const CSS = `
.fm-overlay { position: fixed; inset: 0; z-index: 50; display: flex; align-items: center;
  justify-content: center; overflow: auto; background: rgba(10, 8, 4, .86); backdrop-filter: blur(2px); }
.fm-svg { display: block; margin: auto; max-width: 94vw; max-height: 90vh; height: auto; }
.fm-edge { fill: none; stroke: var(--ink-faint); stroke-width: 1.6; opacity: 0;
  animation: fm-fade .8s ease forwards; }
.fm-edge.blessed { stroke: var(--gold-deep); }
.fm-edge.stale { stroke: var(--del); }
.fm-edge.fanin { stroke: var(--patina); stroke-width: 1.3; stroke-dasharray: 11 3 2 3;
  animation-delay: .25s; }
.fm-node { cursor: pointer; opacity: 0; animation: fm-fade .45s ease forwards; }
.fm-node rect { fill: var(--vellum-raise); stroke: var(--rule); stroke-width: 1.2; transition: stroke .15s, fill .15s; }
.fm-node:hover rect { stroke: var(--ink-faint); fill: var(--vellum-edge); }
.fm-node.active rect { stroke: var(--gold-leaf); stroke-width: 2;
  filter: drop-shadow(0 0 9px var(--gold-wash)); }
.fm-node text { font-family: var(--mono); font-size: 11.5px; fill: var(--ink-dim); }
.fm-node.active text { fill: var(--ink); }
.fm-node .cnt { fill: var(--ink-faint); font-size: 10px; text-anchor: end; }
.fm-node .dot { stroke-width: 1.5; fill: none; }
.fm-node.blessed .dot { fill: var(--gold-leaf); stroke: var(--gold-leaf);
  filter: drop-shadow(0 0 5px var(--gold-wash)); }
.fm-node.blessed rect { stroke: var(--gold-deep); }
.fm-node.stale .dot { fill: var(--del); stroke: var(--del); }
.fm-node.unblessed .dot { stroke: var(--ink-faint); }
.fm-main circle { fill: var(--gold-leaf); filter: drop-shadow(0 0 7px var(--gold-leaf)); }
.fm-main text { fill: var(--gold-leaf); font-family: var(--display); font-style: italic; font-size: 15px; }
@keyframes fm-fade { to { opacity: 1; } }
@media (prefers-reduced-motion: reduce) { .fm-edge, .fm-node { animation: none; opacity: 1; } }
`;
