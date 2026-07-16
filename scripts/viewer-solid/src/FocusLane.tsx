import { createSignal, createMemo, onCleanup, Show, For } from "solid-js";
import { useQueryClient, createMutation } from "@tanstack/solid-query";
import { Link, type ViewerLocation } from "./router";
import { nextStep } from "./homeModel";
import { rowDrag, registerLaneDrop, type RowDrag } from "./focusDrag";
import type { Project, PR } from "./types";

// ── focus lane: the hand-ordered "what I'm pushing now" strip ───────────────
// The forest bands rank by shipping momentum; this ranks by Phil's explicit priority. A short
// pinned list (stack-project.<p>.focus N), reordered two ways: pointer-drag the grip (rows glide
// out of the way), or right-click a row for the reprioritize menu (to top / up / set position).
// Pin/unpin lives in the forest-card ctx menu; this owns the ordering (→ POST /focus {order}).
const pkey = (p: Project) => (p.repo || "loops") + "/" + p.name;

export function FocusLane(props: {
  projects: () => Project[] | undefined;
  prOf: (name: string) => PR | undefined;
}) {
  const qc = useQueryClient();
  // pinned forests in rank order; a live optimistic override holds during a reorder so the row
  // doesn't snap back to server order between the write and the refetch.
  const [override, setOverride] = createSignal<string[] | null>(null);
  const pinned = createMemo(() => {
    const list = (props.projects() || []).filter((p) => p.focus != null)
      .sort((a, b) => (a.focus ?? 0) - (b.focus ?? 0));
    const ov = override();
    if (!ov) return list;
    const byKey = new Map(list.map((p) => [pkey(p), p]));
    return ov.map((k) => byKey.get(k)).filter((p): p is Project => !!p);
  });

  const reorder = createMutation(() => ({
    mutationFn: (order: { repo: string; project: string }[]) =>
      fetch("/focus", { method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ order }) }).then((r) => r.json()),
    onSettled: () => { setOverride(null); qc.invalidateQueries({ queryKey: ["projects"] }); },
  }));

  // Commit a new key order: hold it as an optimistic override AND write the ranks straight into
  // the projects cache, so when the override clears on settle the lane already reads the new order
  // from cache — no snap-back to server order while it refetches.
  const commitOrder = (keys: string[]) => {
    setOverride(keys);
    const rank = new Map(keys.map((k, i) => [k, i + 1]));
    qc.setQueryData<Project[]>(["projects"], (cur) =>
      cur?.map((p) => (rank.has(pkey(p)) ? { ...p, focus: rank.get(pkey(p))! } : p)));
    const byKey = new Map((props.projects() || []).map((p) => [pkey(p), p]));
    reorder.mutate(keys.map((k) => ({ repo: byKey.get(k)!.repo || "loops", project: byKey.get(k)!.name })));
  };

  const moveByIndex = (from: number, to: number) => {
    const keys = pinned().map(pkey);
    to = Math.max(0, Math.min(keys.length - 1, to));
    if (from < 0 || from >= keys.length || from === to) return;
    keys.splice(to, 0, ...keys.splice(from, 1));
    commitOrder(keys);
  };

  // Unpin (drag a row out of the lane): optimistic cache write so the row rejoins the bands
  // instantly, then the single-pin toggle — the {order} path can't unset a rank.
  const unpin = (p: Project) => {
    qc.setQueryData<Project[]>(["projects"], (cur) =>
      cur?.map((q) => (pkey(q) === pkey(p) ? { ...q, focus: null } : q)));
    fetch("/focus", { method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ repo: p.repo || "loops", project: p.name, on: false }) })
      .then(() => qc.invalidateQueries({ queryKey: ["projects"] }));
  };

  // ── pointer drag: the dragged row tracks the finger (no transition); the rows it passes glide
  // one slot up/down via a transform + CSS transition — a real drag-and-drop feel, not the native
  // HTML5 API's snap. `dragTo` is derived from how many row-pitches the pointer has travelled.
  const [dragFrom, setDragFrom] = createSignal<number | null>(null);
  const [dragDY, setDragDY] = createSignal(0);
  const [dragDX, setDragDX] = createSignal(0);
  let rowsEl: HTMLDivElement | undefined;
  let pitch = 0;
  let startY = 0;
  let startX = 0;

  const dragTo = createMemo(() => {
    const f = dragFrom();
    if (f == null || !pitch) return null;
    return Math.max(0, Math.min(pinned().length - 1, f + Math.round(dragDY() / pitch)));
  });
  // Pulled sideways past the threshold = leaving the lane: release unpins instead of reordering.
  const dragOut = createMemo(() => dragFrom() != null && Math.abs(dragDX()) > 80);

  const gripDown = (e: PointerEvent, idx: number) => {
    e.preventDefault();
    const kids = rowsEl?.children;
    pitch = kids && kids.length > 1
      ? kids[1].getBoundingClientRect().top - kids[0].getBoundingClientRect().top
      : ((kids?.[0] as HTMLElement | undefined)?.getBoundingClientRect().height ?? 34) + 4;
    startY = e.clientY;
    startX = e.clientX;
    setDragFrom(idx);
    setDragDY(0);
    setDragDX(0);
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
  };
  const gripMove = (e: PointerEvent) => {
    if (dragFrom() != null) { setDragDY(e.clientY - startY); setDragDX(e.clientX - startX); }
  };
  const gripUp = () => {
    const f = dragFrom(), t = dragTo(), out = dragOut();
    setDragFrom(null); setDragDY(0); setDragDX(0);
    if (f == null) return;
    if (out) unpin(pinned()[f]);
    else if (t != null && f !== t) moveByIndex(f, t);
  };

  // Per-row translate during a drag: the dragged row follows the finger; rows between its origin
  // and target shift one slot to open the gap. In unpin mode the gap closes — nothing is moving in.
  const rowShift = (idx: number): number => {
    const f = dragFrom(), t = dragTo();
    if (f == null || t == null) return 0;
    if (idx === f) return dragDY();
    if (dragOut()) return 0;
    if (f < t && idx > f && idx <= t) return -pitch;
    if (f > t && idx >= t && idx < f) return pitch;
    return 0;
  };
  const rowSlide = (idx: number): number => (dragFrom() === idx && dragOut() ? dragDX() : 0);

  // ── inbound drag: a forest row from the bands below, dropped here to pin ────
  // ForestsList owns the pointer; we hit-test its position against the lane and, on drop, splice
  // the newcomer into the rank order (one {order} POST — the server writes ranks 1..N).
  const laneHit = (x: number, y: number): { idx: number; lineY: number } | null => {
    if (!rowsEl) return null;
    const r = rowsEl.getBoundingClientRect();
    if (x < r.left - 16 || x > r.right + 16 || y < r.top - 28 || y > r.bottom + 16) return null;
    const kids = [...rowsEl.children].filter((el) => el.classList.contains("focus-row")) as HTMLElement[];
    let idx = kids.length;
    for (let i = 0; i < kids.length; i++) {
      const kr = kids[i].getBoundingClientRect();
      if (y < kr.top + kr.height / 2) { idx = i; break; }
    }
    const last = kids[kids.length - 1];
    const lineY = idx < kids.length ? kids[idx].offsetTop - 3
      : last ? last.offsetTop + last.offsetHeight + 1 : 2;
    return { idx, lineY };
  };
  const dropAt = createMemo(() => {
    const d = rowDrag();
    return d ? laneHit(d.x, d.y) : null;
  });
  onCleanup(registerLaneDrop((d: RowDrag) => {
    const hit = laneHit(d.x, d.y);
    if (!hit) return false;
    const k = (d.repo || "loops") + "/" + d.name;
    const keys = pinned().map(pkey).filter((x) => x !== k);
    keys.splice(Math.min(hit.idx, keys.length), 0, k);
    commitOrder(keys);
    return true;
  }));

  const [menu, setMenu] = createSignal<{ x: number; y: number; idx: number } | null>(null);
  const clampMenu = (el: HTMLElement, x: number, y: number) => {
    requestAnimationFrame(() => {
      const pad = 8;
      el.style.left = `${Math.max(pad, Math.min(x, window.innerWidth - el.offsetWidth - pad))}px`;
      el.style.top = `${Math.max(pad, Math.min(y, window.innerHeight - el.offsetHeight - pad))}px`;
    });
  };

  const target = (p: Project): ViewerLocation => ({
    kind: "forest", name: p.name, repo: p.repo && p.repo !== "loops" ? p.repo : undefined,
  });

  return (
    <Show when={pinned().length || rowDrag()}>
      <section class="focus-lane" classList={{ "drop-target": !!dropAt() }}>
        <h2 class="eyebrow">focus <span class="eyebrow-ask ml-2 font-display text-[14px] normal-case italic tracking-normal text-ink-dim">— what you're pushing now, drag or right-click to reorder</span></h2>
        <div class="focus-rows" ref={rowsEl}>
          <Show when={dropAt()}>
            {(a) => <div class="focus-drop-line" style={{ top: `${a().lineY}px` }} />}
          </Show>
          <Show when={rowDrag() && !pinned().length}>
            <div class="focus-drop-empty">drop here to focus</div>
          </Show>
          <For each={pinned()}>
            {(p, i) => {
              const step = createMemo(() => nextStep(p, props.prOf(p.name)));
              return (
                <div
                  class="focus-row"
                  classList={{ dragging: dragFrom() === i(), unpinning: dragFrom() === i() && dragOut() }}
                  style={{ transform: `translate(${rowSlide(i())}px, ${rowShift(i())}px)` }}
                  onContextMenu={(e) => { e.preventDefault(); setMenu({ x: e.clientX, y: e.clientY, idx: i() }); }}
                >
                  <span
                    class="focus-grip"
                    title="drag to reorder"
                    onPointerDown={(e) => gripDown(e, i())}
                    onPointerMove={gripMove}
                    onPointerUp={gripUp}
                    onPointerCancel={gripUp}
                  >⠿</span>
                  <span class="focus-rank">{i() + 1}</span>
                  <Link class="focus-name" to={target(p)}>
                    {p.repo && p.repo !== "loops" ? <span class="focus-repo">{p.repo}</span> : null}
                    {p.name}
                  </Link>
                  <Show when={step()}>
                    <span class="focus-next" classList={{ yours: !!step()!.yourMove }} title={step()!.title}>
                      {step()!.text}
                    </span>
                  </Show>
                </div>
              );
            }}
          </For>
        </div>
      </section>
      <Show when={menu()}>
        {(m) => (
          <>
            <div class="ctx-scrim" onClick={() => setMenu(null)} onContextMenu={(e) => { e.preventDefault(); setMenu(null); }} />
            <div class="ctx-menu" ref={(el) => clampMenu(el, m().x, m().y)} style={{ left: `${m().x}px`, top: `${m().y}px` }}>
              <div class="ctx-head">reprioritize</div>
              <button class="ctx-item" disabled={m().idx === 0} onClick={() => { moveByIndex(m().idx, 0); setMenu(null); }}>
                <span class="ctx-pips">⤒</span><span class="ctx-lbl">move to top</span>
              </button>
              <button class="ctx-item" disabled={m().idx === 0} onClick={() => { moveByIndex(m().idx, m().idx - 1); setMenu(null); }}>
                <span class="ctx-pips">↑</span><span class="ctx-lbl">move up</span>
              </button>
              <button class="ctx-item" disabled={m().idx === pinned().length - 1} onClick={() => { moveByIndex(m().idx, m().idx + 1); setMenu(null); }}>
                <span class="ctx-pips">↓</span><span class="ctx-lbl">move down</span>
              </button>
              <div class="ctx-head">set position</div>
              <For each={pinned().map((_, i) => i)}>
                {(pos) => (
                  <button class="ctx-item ctx-focus" classList={{ on: m().idx === pos }}
                    onClick={() => { moveByIndex(m().idx, pos); setMenu(null); }}>
                    <span class="ctx-pips">{pos + 1}</span>
                    <span class="ctx-lbl">{pinned()[pos] ? pinned()[pos].name : ""}</span>
                  </button>
                )}
              </For>
            </div>
          </>
        )}
      </Show>
    </Show>
  );
}
