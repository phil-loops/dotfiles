import { createSignal, createMemo, Show, For, type JSX } from "solid-js";
import { deleteMode, setDeleteMode } from "./deleteMode";
import { canMutate } from "./provider";
import { ActionBar, type Action } from "./actions";
import { mergedAgo } from "./shared";
import { nextStep, type NextStep } from "./homeModel";
import { FocusLane } from "./FocusLane";
import { ForgottenBand, isForgotten } from "./ForgottenBand";
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
// order by next-step urgency, other bands by recency. Owns its own filter/fold state; the
// row itself comes in as a prop (Home wires its hover/ctx/parked handlers).
export function ForestsList(props: {
  tab: () => string;
  projects: () => Project[] | undefined;
  restackErr: () => string | null;
  restackAllAction: () => Action;
  forestRow: (p: Project, folded: boolean, next?: { step: NextStep; start: boolean }) => JSX.Element;
  parked: () => Parked | null;
  prOf: (name: string) => PR | undefined;
  setTier: (repo: string, project: string, tier: string) => void;
}) {
  const [forestQuery, setForestQuery] = createSignal("");
  // Forests recency — "most recently alive": the latest of local commit, PR opened, and
  // merge-to-main. The within-band sort, never the grouping.
  const forestTs = (p: Project): number =>
    Math.max(
      (p.lastCommit ?? 0) * 1000,
      p.prOpened ? Date.parse(p.prOpened) : 0,
      p.merged?.at ? Date.parse(p.merged.at) : 0,
    );
  const filteredForests = createMemo(() => {
    const needle = forestQuery().trim().toLowerCase();
    const list = props.projects() || [];
    return needle ? list.filter((p) => p.name.toLowerCase().includes(needle)) : list;
  });
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
  // Cross-repo "epic" clusters: same stack-project.<name>.epic tag spanning ≥2 repos folds into
  // one card, placed in the band of its most urgent member. A single-repo epic is left in its
  // normal band — pulling one row out into a lone "cluster" would only fragment the list.
  const epicClusters = createMemo(() => {
    const byEpic = new Map<string, Project[]>();
    for (const p of filteredForests()) {
      if (!p.epic || recentlyMerged(p) || p.shelved || p.tier !== "committed" || p.focus != null) continue;
      (byEpic.get(p.epic) ?? byEpic.set(p.epic, []).get(p.epic)!).push(p);
    }
    return [...byEpic.entries()]
      .filter(([, items]) => new Set(items.map((p) => p.repo || "loops")).size >= 2)
      .map(([epic, items]) => ({
        epic,
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
    const active = filteredForests().filter((p) => !recentlyMerged(p) && !p.shelved && p.tier === "committed" && p.focus == null && !clustered.has(pkey(p)));
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
    if (folded || p.shelved || !isPrBand(bandIdx(p))) return undefined;
    const step = stepOf(p);
    return step ? { step, start: pkey(p) === startKey() } : undefined;
  };
  const merged = createMemo(() =>
    filteredForests().filter(recentlyMerged).sort((a, b) => forestTs(b) - forestTs(a)));
  // deliberately paused — Phil's explicit mark (right-click → shelve); a shelf, not a band
  const shelvedList = createMemo(() =>
    filteredForests().filter((p) => p.shelved && !recentlyMerged(p)).sort((a, b) => forestTs(b) - forestTs(a)));

  // ── conviction tiers (orthogonal to the bands) ──────────────────────────
  // committed → the lifecycle bands above; trying/spike/untriaged get their own sections. A pool of
  // everything still in play (not merged, not shelved) — and NOT already pinned to the focus lane:
  // pinning IS a decision, so a focused forest leaves the triage pile (and every band) for the lane.
  // A forgotten row is claimed by its own band and leaves the tier sections — listed in both, the
  // stale copy reads as live work in the newest-first sort that hid it in the first place.
  const tierPool = createMemo(() =>
    filteredForests().filter((p) => !recentlyMerged(p) && !p.shelved && p.focus == null && !isForgotten(p)));
  // any interaction counts as triaged: a forest you've rated (interest>0) keeps its triage-zone
  // spot but no longer nags for a tier — the nag count reflects only the still-untouched ones.
  const triaged = (p: Project) => (p.interest ?? 0) > 0;
  const triageList = createMemo(() =>
    tierPool().filter((p) => p.tier == null).sort((a, b) => forestTs(b) - forestTs(a)));
  const triageNag = createMemo(() => triageList().filter((p) => !triaged(p)).length);
  const tryingList = createMemo(() =>
    tierPool().filter((p) => p.tier === "trying").sort((a, b) => forestTs(b) - forestTs(a)));
  const spikeList = createMemo(() =>
    tierPool().filter((p) => p.tier === "spike").sort((a, b) => forestTs(b) - forestTs(a)));
  // the "committed" super-header only earns its place once tiers are actually in use — otherwise
  // the bands stand on their own exactly as before.
  const showTierHeads = createMemo(() =>
    tierPool().some((p) => p.tier === "committed") &&
    (triageList().length > 0 || tryingList().length > 0 || spikeList().length > 0));
  const multiRepo = createMemo(() => new Set(filteredForests().map((p) => p.repo || "loops")).size > 1);

  // ── drag a row up into the focus lane to pin it (only this page has the drop target) ────
  // The grip publishes the pointer to the focusDrag store; FocusLane hit-tests and commits the
  // drop. Release anywhere else is a no-op.
  const dragDown = (e: PointerEvent, p: Project) => {
    e.preventDefault();
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
    setRowDrag({ repo: p.repo || "loops", name: p.name, x: e.clientX, y: e.clientY });
  };
  const dragMove = (e: PointerEvent) => {
    const d = rowDrag();
    if (!d) return;
    setRowDrag({ ...d, x: e.clientX, y: e.clientY });
    // the lane lives at the top of a long page — nudge the scroll when dragging near the edges
    if (e.clientY < 90) window.scrollBy(0, -14);
    else if (e.clientY > window.innerHeight - 60) window.scrollBy(0, 14);
  };
  const dragUp = () => {
    const d = rowDrag();
    setRowDrag(null);
    if (d) dropOnLane(d);
  };
  const dragWrap = (p: Project, inner: JSX.Element) => (
    <div class="row-drag-wrap group/drag relative">
      <span
        class="row-drag-grip absolute -left-5 top-1/2 z-[2] -translate-y-1/2 cursor-grab select-none touch-none px-[3px] py-[6px] text-[12px] text-ink-faint opacity-0 transition-opacity duration-[120ms] hover:text-gold-leaf active:cursor-grabbing group-hover/drag:opacity-100"
        title="drag to focus lane"
        onPointerDown={(e) => dragDown(e, p)}
        onPointerMove={dragMove}
        onPointerUp={dragUp}
        onPointerCancel={dragUp}
      >⠿</span>
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
  // dormant + shelved + recently-merged folds closed until clicked — context, not to-dos.
  const [dormantOpen, setDormantOpen] = createSignal(false);
  const [shelvedOpen, setShelvedOpen] = createSignal(false);
  const [mergedOpen, setMergedOpen] = createSignal(false);
  const [spikeOpen, setSpikeOpen] = createSignal(false);
  // triage row: a forest with no tier yet → one-click set into a tier. The forcing function.
  const TRIAGE_SET = "cursor-pointer rounded-[3px] border border-rule px-[9px] py-[2px] font-mono text-[11px] text-ink-dim";
  const triageRow = (p: Project) => (
    <div class="triage-item flex flex-col">
      {row(p, false)}
      <Show when={!triaged(p)}>
        <div class="triage-actions mt-[2px] mb-2 ml-[10px] flex gap-[6px]">
          <button class={`triage-set committed ${TRIAGE_SET} hover:border-gold-deep hover:text-gold-leaf`} title="I'm shipping this" onClick={() => props.setTier(p.repo || "loops", p.name, "committed")}>● committed</button>
          <button class={`triage-set trying ${TRIAGE_SET} hover:border-patina hover:text-patina`} title="leaning in, undecided" onClick={() => props.setTier(p.repo || "loops", p.name, "trying")}>◐ trying</button>
          <button class={`triage-set spike ${TRIAGE_SET} hover:border-ink-faint hover:text-ink-faint`} title="throwaway experiment" onClick={() => props.setTier(p.repo || "loops", p.name, "spike")}>○ spike</button>
        </div>
      </Show>
    </div>
  );
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
          <Show when={canMutate && (props.projects() || []).some((p) => p.behind > 0)}>
            <ActionBar actions={[props.restackAllAction()]} />
          </Show>
        </div>
        <Show when={(props.projects() || []).length > 6}>
          <input
            class="forest-search mx-0 mt-0 mb-[12px] w-full rounded-[9px] border border-rule bg-vellum-raise px-[13px] py-[9px] font-mono text-[13px] leading-[1.55] text-ink focus:border-gold-deep focus:outline-none"
            placeholder="filter forests…"
            value={forestQuery()}
            onInput={(e) => setForestQuery(e.currentTarget.value)}
          />
        </Show>
        <FocusLane projects={props.projects} prOf={props.prOf} />
        <ForgottenBand projects={props.projects} forestRow={props.forestRow} />
        <Show
          when={filteredForests().length}
          fallback={
            <p class="loading">
              {forestQuery()
                ? `no forest matches “${forestQuery()}”`
                : "no forests configured"}
            </p>
          }
        >
          <Show when={triageList().length}>
            <div class={`forest-band-head triage-head ${BAND_HEAD} flex items-center gap-[6px] text-ember`} title="new forests with no conviction tier yet — decide: committed (ships, keeps its bands), trying, or a throwaway spike">
              ◆ triage <span class="triage-count rounded-[8px] bg-ember px-[6px] font-mono text-[11px] text-vellum-night">{triageNag()}</span>
            </div>
            <For each={triageList()}>{(p) => triageRow(p)}</For>
          </Show>
          <Show when={showTierHeads()}>
            <div class="tier-head mt-[18px] mb-1 border-0 border-b border-solid border-gold-deep pb-[3px] font-mono text-[11px] uppercase tracking-[0.14em] text-gold-leaf" title="the forests you're serious about — full lifecycle bands below">committed</div>
          </Show>
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
                      <h3 class="epic-head mx-[2px] mt-[2px] mb-[8px] text-[11px] uppercase tracking-[0.08em] text-gold-deep" title="one effort spanning repos, linked by epic tag (advisory — each half still merges on its own main)">
                        ⇌ {cluster.epic}
                      </h3>
                      <For each={cluster.items}>
                        {(p) => dragWrap(p, (
                          <div class={SUBROW}>
                            <span class={BADGE}>{p.repo || "loops"}</span>
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
          <Show when={tryingList().length}>
            <div class={`forest-band-head tier-head-trying ${BAND_HEAD} text-patina`} title="leaning in, undecided — promote to committed or drop to spike as it proves out">
              ◐ trying
            </div>
            <For each={tryingList()}>{(p) => row(p, false)}</For>
          </Show>
          <Show when={spikeList().length}>
            <button class={MFOLD} onClick={() => setSpikeOpen(!spikeOpen())} title="throwaway experiments — right-click a forest → conviction to promote one">
              {spikeOpen() ? "▾" : "▸"} {spikeList().length} spike{spikeList().length === 1 ? "" : "s"}
            </button>
            <Show when={spikeOpen()}>
              <For each={spikeList()}>{(p) => row(p, false)}</For>
            </Show>
          </Show>
          <Show when={shelvedList().length}>
            <button class={MFOLD} onClick={() => setShelvedOpen(!shelvedOpen())} title="deliberately paused (right-click a forest → shelve); unshelve the same way">
              {shelvedOpen() ? "▾" : "▸"} {shelvedList().length} shelved
            </button>
            <Show when={shelvedOpen()}>
              <For each={shelvedList()}>{(p) => row(p, false)}</For>
            </Show>
          </Show>
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
