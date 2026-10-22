import { createSignal, createMemo, onCleanup, Show, For, type JSX } from "solid-js";
import { useQueryClient } from "@tanstack/solid-query";
import { deleteMode, setDeleteMode } from "./deleteMode";
import { canMutate } from "./provider";
import { ActionBar, type Action } from "./actions";
import { mergedAgo } from "./shared";
import { nextStep, type NextStep } from "./homeModel";
import { rowDrag, setRowDrag, dropOnLane } from "./focusDrag";
import type { Project, Parked, PR } from "./types";

const SUBROW = "epic-subrow mb-[6px] flex items-center gap-[9px]";
const BADGE = "epic-repo-badge w-[62px] flex-none text-right text-[10px] uppercase tracking-[0.06em] text-ink-faint";
const BAND_HEAD = "mx-1 mt-4 mb-[7px] first:mt-[2px] text-[11px] uppercase tracking-[0.09em] opacity-[0.85]";
const MFOLD = "forest-mfold mt-2 block w-full cursor-pointer px-1 pt-[9px] pb-[5px] text-left text-[11px] leading-[1.55] tracking-[0.03em] text-ink-dim hover:text-gold-leaf";

// The Forests tab: the complete forest index grouped by LIFECYCLE BAND — what state the work
// is in, most urgent first — with cross-repo epic clusters folded into their band and quiet
// folds for dormant + recently-merged. One opinionated order (Phil, 2026-07-11): the manual
// interest pips no longer rank the page (they demoted to passive row metadata); the PR bands
// order by next-step urgency, other bands by recency. Owns its own fold state; the
// row itself comes in as a prop (Home wires its hover/ctx/parked handlers).
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

  // ── lifecycle bands, most urgent first ──────────────────────────────────
  //   needs a hand — parked on a rebase conflict: blocked until someone resolves it
  //   shipping     — landed a PR this month (gh-backed p.shipped) with work remaining:
  //                  the proven class (Phil, 2026-07-12: "once a project has a PR merged,
  //                  that's a class of projects on itself")
  //   first PR out — an open PR but nothing merged yet: the second, lower class
  //   building     — alive in the last two weeks, no PR activity
  //   dormant      — no life in two weeks (folded: it's context, not a to-do)
  // Deliberately NOT bands: behind-main (when origin/main advances everything is behind at
  // once — ambient restack weather, owned by the row dot + restack-all) and mergeable roots
  // (nearly every built forest has one — a signal that's always on ranks nothing).
  const BANDS = [
    { key: "hand", label: "needs a hand", hint: "a rebase parked on a conflict — blocked until it's resolved or aborted" },
    { key: "shipping", label: "shipping", hint: "landed PRs this month, more to ship — the proven class" },
    { key: "opening", label: "first PR out", hint: "an open PR, nothing merged yet" },
    { key: "building", label: "building", hint: "commits in the last two weeks; no PR activity" },
    { key: "dormant", label: "dormant", hint: "no movement in two weeks" },
  ] as const;
  const DORMANT_AFTER_MS = 14 * 24 * 3600 * 1000;
  const bandIdx = (p: Project): number => {
    if (props.parked()?.project === p.name) return 0;
    const open = !!(p.prOpened || props.prOf(p.name));
    if ((p.shipped?.count ?? 0) > 0 && (open || p.mergeable?.length)) return 1;
    if (open) return 2;
    return forestTs(p) > Date.now() - DORMANT_AFTER_MS ? 3 : 4;
  };
  const isPrBand = (i: number) => i === 1 || i === 2;

  // A project's identity is (repo, name) — the same forest name can exist in two repos.
  const pkey = (p: Project) => (p.repo || "loops") + " " + p.name;
  // "Epic" clusters: the same stack-project.<name>.epic tag on ≥2 forests (one repo or several)
  // folds them into one headed card, placed in the band of its most urgent member. A lone tagged
  // forest stays in its normal band — a one-row "cluster" would only fragment the list.
  const epicClusters = createMemo(() => {
    const byEpic = new Map<string, Project[]>();
    for (const p of forests()) {
      if (!p.epic || recentlyMerged(p) || p.focus != null) continue;
      (byEpic.get(p.epic) ?? byEpic.set(p.epic, []).get(p.epic)!).push(p);
    }
    return [...byEpic.entries()]
      .filter(([, items]) => items.length >= 2)
      .map(([epic, items]) => ({
        epic,
        crossRepo: new Set(items.map((p) => p.repo || "loops")).size >= 2,
        band: Math.min(...items.map(bandIdx)),
        ts: Math.max(...items.map(forestTs)),
        items: items.sort((a, b) => forestTs(b) - forestTs(a)),
      }));
  });
  const clusteredKeys = createMemo(() => new Set(epicClusters().flatMap((c) => c.items.map(pkey))));
  // rows in the two PR bands carry their concrete next step (nextStep, homeModel); each
  // band sorts your-move steps above waiting-on-others so its top IS the priority order.
  // Other bands keep the plain recency sort.
  const stepOf = (p: Project): NextStep | null => nextStep(p, props.prOf(p.name));
  const bands = createMemo(() => {
    const clustered = clusteredKeys();
    const active = forests().filter((p) => !recentlyMerged(p) && p.focus == null && !clustered.has(pkey(p)));
    return BANDS.map((band, i) => ({
      ...band,
      clusters: epicClusters().filter((c) => c.band === i).sort((a, b) => b.ts - a.ts),
      items: active.filter((p) => bandIdx(p) === i).sort((a, b) =>
        (isPrBand(i) ? (stepOf(a)?.rank ?? 9) - (stepOf(b)?.rank ?? 9) : 0) || forestTs(b) - forestTs(a)),
    })).filter((b) => b.items.length || b.clusters.length);
  });
  // "if I don't know what to do next, start here" — exactly one row wears the start tag:
  // the first your-move step in render order across shipping then first-PR-out.
  const startKey = createMemo(() => {
    const ordered = bands()
      .filter((b) => b.key === "shipping" || b.key === "opening")
      .flatMap((b) => [...b.clusters.flatMap((c) => c.items), ...b.items]);
    const first = ordered.find((p) => isPrBand(bandIdx(p)) && stepOf(p)?.yourMove);
    return first ? pkey(first) : null;
  });
  const stepInfo = (p: Project, folded: boolean) => {
    if (folded || !isPrBand(bandIdx(p))) return undefined;
    const step = stepOf(p);
    return step ? { step, start: pkey(p) === startKey() } : undefined;
  };
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
        {props.forestRow(p, folded, stepInfo(p, folded))}
      </div>
    ) : (
      props.forestRow(p, folded, stepInfo(p, folded))
    ));
  // dormant + recently-merged folds closed until clicked — context, not to-dos.
  const [dormantOpen, setDormantOpen] = createSignal(false);
  const [mergedOpen, setMergedOpen] = createSignal(false);
  return (
      <Show when={props.tab() === "forests"}>
      <section>
        <div class="eyebrow-row flex items-center justify-between">
          <h2 class="eyebrow mt-[34px] mb-[12px] text-[10px] font-medium tracking-[0.22em] uppercase text-ink-faint">forests</h2>
          <Show when={deleteMode()}>
            <span class="delete-mode-tag ml-3 inline-flex items-center gap-2 text-[11px] tracking-[0.03em] text-del">
              delete mode
              <button class="delete-mode-exit cursor-pointer rounded-[6px] border border-del bg-transparent px-2 py-[2px] text-[11px] leading-[1.55] text-del transition-[background] duration-[120ms] hover:bg-del-bg" onClick={() => setDeleteMode(false)}>exit</button>
            </span>
          </Show>
          <Show when={props.restackErr()}>
            <span class="restack-err ml-auto pr-[10px] text-[11px] tracking-[0.02em] text-del">{props.restackErr()}</span>
          </Show>
          <Show when={canMutate && (props.projects() || []).some((p) => (p.mergedNodes?.length ?? 0) > 0)}>
            <ActionBar actions={[props.restackAllAction()]} />
          </Show>
        </div>
        <Show
          when={forests().length}
          fallback={
            <p class="loading px-1 py-[14px] italic text-ink-faint">no forests configured</p>
          }
        >
          <For each={bands()}>
            {(band) => (
              <Show
                when={band.key !== "dormant"}
                fallback={
                  <>
                    <button class={MFOLD} onClick={() => setDormantOpen(!dormantOpen())}>
                      {dormantOpen() ? "▾" : "▸"} {band.items.length + band.clusters.reduce((n, c) => n + c.items.length, 0)} dormant
                    </button>
                    <Show when={dormantOpen()}>
                      {/* a fully-dormant epic cluster flattens to plain rows here — the fold is
                          an archive shelf, not a place to preserve cluster framing */}
                      <For each={[...band.clusters.flatMap((c) => c.items), ...band.items]}>{(p) => row(p, false)}</For>
                    </Show>
                  </>
                }
              >
                <div class={`forest-band-head ${BAND_HEAD} text-gold-deep`} title={band.hint}>{band.label}</div>
                <For each={band.clusters}>
                  {(cluster) => (
                    <div class="epic-cluster mx-0 mt-[2px] mb-[16px] rounded-[12px] border border-gold-deep bg-[color-mix(in_srgb,var(--color-gold-leaf)_5%,var(--color-vellum-raise))] px-[11px] pt-[9px] pb-[4px]">
                      <h3 class="epic-head mx-[2px] mt-[2px] mb-[8px] text-[11px] uppercase tracking-[0.08em] text-gold-deep" title="one effort spanning forests, linked by epic tag (advisory — each forest still merges on its own)">
                        ⇌ {cluster.epic}
                      </h3>
                      <For each={cluster.items}>
                        {(p) => dragWrap(p, (
                          <div class={SUBROW}>
                            <Show when={cluster.crossRepo}><span class={BADGE}>{p.repo || "loops"}</span></Show>
                            {props.forestRow(p, false, stepInfo(p, false))}
                          </div>
                        ))}
                      </For>
                    </div>
                  )}
                </For>
                <For each={band.items}>{(p) => row(p, false)}</For>
              </Show>
            )}
          </For>
          <Show when={merged().length}>
            <button class={MFOLD} onClick={() => setMergedOpen(!mergedOpen())}>
              {mergedOpen() ? "▾" : "▸"} {merged().length} recently merged
            </button>
            <Show when={mergedOpen()}>
              <For each={merged()}>{(p) => row(p, true)}</For>
            </Show>
          </Show>
        </Show>
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
