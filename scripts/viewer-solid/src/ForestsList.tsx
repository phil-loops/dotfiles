import { createSignal, createMemo, onCleanup, Show, For, type JSX } from "solid-js";
import { useQueryClient } from "@tanstack/solid-query";
import { canMutate } from "./provider";
import { ActionBar, type Action } from "./actions";
import { mergedAgo } from "./shared";
import type { NextStep } from "./homeModel";
import { rowDrag, setRowDrag, dropOnLane } from "./focusDrag";
import type { Project, Parked, PR } from "./types";
import { ArchiveFold } from "./ArchiveFold";

const SUBROW = "epic-subrow mb-[6px] flex items-center gap-[9px]";
const BADGE = "epic-repo-badge w-[62px] flex-none text-right text-[10px] uppercase tracking-[0.06em] text-ink-faint";
const MFOLD = "forest-mfold mt-2 block w-full cursor-pointer px-1 pt-[9px] pb-[5px] text-left text-[11px] leading-[1.55] tracking-[0.03em] text-ink-dim hover:text-gold-leaf";

// The Forests tab below the focus lane: the workbench (every forest not in focus, rough and
// taking shape), a fold for fully landed forests, and the archive (forests dropped from both,
// hidden everywhere else, restorable). The row itself comes in as a prop (Home wires its
// hover/ctx/parked handlers).
export function ForestsList(props: {
  tab: () => string;
  projects: () => Project[] | undefined;
  restackErr: () => string | null;
  restackAllAction: () => Action;
  forestRow: (p: Project, folded: boolean, next?: { step: NextStep; start: boolean }) => JSX.Element;
  parked: () => Parked | null;
  prOf: (name: string) => PR | undefined;
}) {
  const qc = useQueryClient();
  // Forests recency — "most recently alive": the latest of local commit, PR opened, and
  // merge-to-main. The within-band sort, never the grouping.
  const forestTs = (p: Project): number =>
    Math.max(
      (p.lastCommit ?? 0) * 1000,
      p.prOpened ? Date.parse(p.prOpened) : 0,
      p.merged?.at ? Date.parse(p.merged.at) : 0,
    );
  const forests = createMemo(() => props.projects() || []);
  // A forest folds into "recently merged" only once it's fully wrapped up: a recent merge AND no
  // mergeable roots left (every branch landed AND got contracted). A forest where one base merged
  // but others are still open/unpushed keeps mergeable roots, so it stays in the active list —
  // that's the moment to restack and ship the rest, not bury it. (mergeable still lists squash-
  // merged-but-uncontracted roots, so a just-merged forest lingers in active until you contract it.)
  const recentlyMerged = (p: Project): boolean =>
    !!(p.merged && mergedAgo(p.merged.at)) && !p.mergeable?.length;

  const pkey = (p: Project) => (p.repo || "loops") + " " + p.name;
  // The workbench: every forest that isn't in focus and isn't fully landed — rough, taking shape.
  // One list, a parked rebase conflict first, then most recently alive. Dropping a row (x) archives it.
  const workbench = createMemo(() =>
    forests()
      .filter((p) => !recentlyMerged(p) && p.focus == null)
      .sort((a, b) =>
        Number(props.parked()?.project === b.name) - Number(props.parked()?.project === a.name) || forestTs(b) - forestTs(a)));
  const merged = createMemo(() =>
    forests().filter(recentlyMerged).sort((a, b) => forestTs(b) - forestTs(a)));
  const multiRepo = createMemo(() => new Set(forests().map((p) => p.repo || "loops")).size > 1);

  // ── the gutter ☆: click pins to the end of the focus lane; drag places it precisely ────
  // A bare press-and-release is the common motion (Phil, 2026-08-18: "anything I'm revisiting
  // ends up pinned anyway — should be easier"), so the drag machinery only engages past a 5px
  // slop: rowDrag stays unpublished for a click, keeping the lane's drop chrome and the ghost
  // from flashing. FocusLane hit-tests the published drag and commits the drop.
  // the lane lives at the top of a long page — auto-scroll while the pointer holds an edge zone.
  // Timer-driven, not per-move: scroll must keep flowing while the pointer sits still, and each
  // tick re-publishes the drag so the lane's indicator/hit-test re-measure the scrolled rect.
  let scrollTimer: number | undefined;
  const autoScroll = () => {
    const d = rowDrag();
    if (!d) return;
    if (d.y < 90) window.scrollBy(0, -14);
    else if (d.y > window.innerHeight - 60) window.scrollBy(0, 14);
    else return;
    setRowDrag({ ...d });
  };
  const pinToEnd = (p: Project) => {
    qc.setQueryData<Project[]>(["projects"], (cur) => {
      if (!cur) return cur;
      const maxRank = Math.max(0, ...cur.filter((q) => q.focus != null).map((q) => q.focus ?? 0));
      return cur.map((q) => (pkey(q) === pkey(p) ? { ...q, focus: maxRank + 1 } : q));
    });
    fetch("/focus", { method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ repo: p.repo || "loops", project: p.name, on: true }) })
      .then(() => qc.invalidateQueries({ queryKey: ["projects"] }));
  };
  let press: { p: Project; x: number; y: number } | null = null;
  const dragDown = (e: PointerEvent, p: Project) => {
    e.preventDefault();
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
    press = { p, x: e.clientX, y: e.clientY };
  };
  const dragMove = (e: PointerEvent) => {
    const d = rowDrag();
    if (d) { setRowDrag({ ...d, x: e.clientX, y: e.clientY }); return; }
    if (press && Math.hypot(e.clientX - press.x, e.clientY - press.y) > 5) {
      setRowDrag({ repo: press.p.repo || "loops", name: press.p.name, x: e.clientX, y: e.clientY });
      scrollTimer = window.setInterval(autoScroll, 50);
    }
  };
  const dragUp = () => {
    window.clearInterval(scrollTimer);
    const d = rowDrag();
    setRowDrag(null);
    if (d) dropOnLane(d);
    else if (press) pinToEnd(press.p);
    press = null;
  };
  const dragCancel = () => {
    window.clearInterval(scrollTimer);
    setRowDrag(null);
    press = null;
  };
  onCleanup(() => window.clearInterval(scrollTimer));
  const dragWrap = (p: Project, inner: JSX.Element) => (
    <div class="row-drag-wrap group/drag relative">
      <span
        class="row-drag-grip absolute -left-5 top-1/2 z-[2] -translate-y-1/2 cursor-pointer select-none touch-none px-[4px] py-[6px] text-[13px] text-ink-faint opacity-0 transition-opacity duration-[120ms] hover:text-gold-leaf active:cursor-grabbing group-hover/drag:opacity-100"
        title="pin to focus — click pins, drag to place"
        onPointerDown={(e) => dragDown(e, p)}
        onPointerMove={dragMove}
        onPointerUp={dragUp}
        onPointerCancel={dragCancel}
      >☆</span>
      {inner}
    </div>
  );

  // repo demoted from group header to a quiet per-row badge (non-loops rows only)
  const row = (p: Project, folded: boolean) =>
    dragWrap(p, multiRepo() && (p.repo || "loops") !== "loops" ? (
      <div class={SUBROW}>
        <span class={BADGE}>{p.repo}</span>
        {props.forestRow(p, folded)}
      </div>
    ) : (
      props.forestRow(p, folded)
    ));
  const [mergedOpen, setMergedOpen] = createSignal(false);
  return (
      <Show when={props.tab() === "forests"}>
      <section>
        <div class="eyebrow-row flex items-center justify-between">
          <h2 class="eyebrow mt-[34px] mb-[12px] text-[10px] font-medium tracking-[0.22em] uppercase text-ink-faint" title="taking shape — rough work you haven't committed to. f focuses a row, x archives it">workbench · {workbench().length}</h2>
          <Show when={props.restackErr()}>
            <span class="restack-err ml-auto pr-[10px] text-[11px] tracking-[0.02em] text-del">{props.restackErr()}</span>
          </Show>
          <Show when={canMutate && (props.projects() || []).some((p) => (p.mergedNodes?.length ?? 0) > 0)}>
            <ActionBar actions={[props.restackAllAction()]} />
          </Show>
        </div>
        <Show
          when={workbench().length}
          fallback={<p class="px-1 py-[14px] font-display text-[15px] italic text-ink-faint">the workbench is clear</p>}
        >
          <For each={workbench()}>{(p) => row(p, false)}</For>
        </Show>
        <Show when={merged().length}>
          <button class={MFOLD} onClick={() => setMergedOpen(!mergedOpen())}>
            {mergedOpen() ? "▾" : "▸"} {merged().length} landed
          </button>
          <Show when={mergedOpen()}>
            <For each={merged()}>{(p) => row(p, true)}</For>
          </Show>
        </Show>
        <ArchiveFold />
        <Show when={rowDrag()}>
          {(d) => (
            <div class="drag-ghost pointer-events-none fixed z-40 translate-x-3 -translate-y-1/2 whitespace-nowrap rounded-[4px] border border-solid border-gold-deep bg-vellum-raise px-3 py-1 font-display text-[14px] italic text-ink shadow-[0_6px_18px_rgba(0,0,0,0.4)]" style={{ left: `${d().x}px`, top: `${d().y}px` }}>
              {d().name}
            </div>
          )}
        </Show>
      </section>
      </Show>
  );
}
