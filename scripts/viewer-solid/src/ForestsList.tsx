import { createSignal, createMemo, Show, For, type JSX } from "solid-js";
import { deleteMode, setDeleteMode } from "./deleteMode";
import { canMutate } from "./provider";
import { ActionBar, type Action } from "./actions";
import { mergedAgo } from "./shared";
import { nextStep, type NextStep } from "./homeModel";
import type { Project, Parked, PR } from "./types";

// The Forests tab: the complete forest index grouped by LIFECYCLE BAND — what state the work
// is in, most urgent first — with cross-repo epic clusters folded into their band and quiet
// folds for dormant + recently-merged. One opinionated order (Phil, 2026-07-11): the manual
// interest pips no longer rank the page (they demoted to passive row metadata); shipping
// orders by next-step urgency, other bands by recency. Owns its own filter/fold state; the
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
  //   shipping     — riding to main: an open PR, or bases landed with more roots to ship
  //   building     — alive in the last two weeks, nothing shipping yet
  //   dormant      — no life in two weeks (folded: it's context, not a to-do)
  // Deliberately NOT bands: behind-main (when origin/main advances everything is behind at
  // once — ambient restack weather, owned by the row dot + restack-all) and mergeable roots
  // (nearly every built forest has one — a signal that's always on ranks nothing).
  const BANDS = [
    { key: "hand", label: "needs a hand", hint: "a rebase parked on a conflict — blocked until it's resolved or aborted" },
    { key: "shipping", label: "shipping", hint: "riding to main — an open PR, or landed bases with more still to ship" },
    { key: "building", label: "building", hint: "commits in the last two weeks; nothing shipping yet" },
    { key: "dormant", label: "dormant", hint: "no movement in two weeks" },
  ] as const;
  const DORMANT_AFTER_MS = 14 * 24 * 3600 * 1000;
  const bandIdx = (p: Project): number => {
    if (props.parked()?.project === p.name) return 0;
    // sticky: once anything lands, stay shipping while unmerged roots remain — a base
    // merging must not demote a mid-flight forest between pushes
    if (p.prOpened || props.prOf(p.name) || (p.merged && p.mergeable?.length)) return 1;
    return forestTs(p) > Date.now() - DORMANT_AFTER_MS ? 2 : 3;
  };

  // A project's identity is (repo, name) — the same forest name can exist in two repos.
  const pkey = (p: Project) => (p.repo || "loops") + " " + p.name;
  // Cross-repo "epic" clusters: same stack-project.<name>.epic tag spanning ≥2 repos folds into
  // one card, placed in the band of its most urgent member. A single-repo epic is left in its
  // normal band — pulling one row out into a lone "cluster" would only fragment the list.
  const epicClusters = createMemo(() => {
    const byEpic = new Map<string, Project[]>();
    for (const p of filteredForests()) {
      if (!p.epic || recentlyMerged(p)) continue;
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
  // shipping rows carry their concrete next step (nextStep, homeModel); the band sorts
  // your-move steps above waiting-on-others so the top of shipping IS the priority order.
  // Other bands keep the plain recency sort.
  const stepOf = (p: Project): NextStep | null => nextStep(p, props.prOf(p.name));
  const bands = createMemo(() => {
    const clustered = clusteredKeys();
    const active = filteredForests().filter((p) => !recentlyMerged(p) && !clustered.has(pkey(p)));
    return BANDS.map((band, i) => ({
      ...band,
      clusters: epicClusters().filter((c) => c.band === i).sort((a, b) => b.ts - a.ts),
      items: active.filter((p) => bandIdx(p) === i).sort((a, b) =>
        (i === 1 ? (stepOf(a)?.rank ?? 9) - (stepOf(b)?.rank ?? 9) : 0) || forestTs(b) - forestTs(a)),
    })).filter((b) => b.items.length || b.clusters.length);
  });
  // "if I don't know what to do next, start here" — exactly one row wears the start tag:
  // the first your-move step in shipping's render order (cluster members, then items).
  const startKey = createMemo(() => {
    const shipping = bands().find((b) => b.key === "shipping");
    const ordered = shipping ? [...shipping.clusters.flatMap((c) => c.items), ...shipping.items] : [];
    const first = ordered.find((p) => bandIdx(p) === 1 && stepOf(p)?.yourMove);
    return first ? pkey(first) : null;
  });
  const stepInfo = (p: Project, folded: boolean) => {
    if (folded || bandIdx(p) !== 1) return undefined;
    const step = stepOf(p);
    return step ? { step, start: pkey(p) === startKey() } : undefined;
  };
  const merged = createMemo(() =>
    filteredForests().filter(recentlyMerged).sort((a, b) => forestTs(b) - forestTs(a)));
  const multiRepo = createMemo(() => new Set(filteredForests().map((p) => p.repo || "loops")).size > 1);
  // repo demoted from group header to a quiet per-row badge (non-loops rows only)
  const row = (p: Project, folded: boolean) =>
    multiRepo() && (p.repo || "loops") !== "loops" ? (
      <div class="epic-subrow">
        <span class="epic-repo-badge">{p.repo}</span>
        {props.forestRow(p, folded, stepInfo(p, folded))}
      </div>
    ) : (
      props.forestRow(p, folded, stepInfo(p, folded))
    );
  // dormant + recently-merged fold closed until clicked — context, not to-dos.
  const [dormantOpen, setDormantOpen] = createSignal(false);
  const [mergedOpen, setMergedOpen] = createSignal(false);
  return (
      <Show when={props.tab() === "forests"}>
      <section>
        <div class="eyebrow-row">
          <h2 class="eyebrow">forests</h2>
          <Show when={deleteMode()}>
            <span class="delete-mode-tag">
              delete mode
              <button class="delete-mode-exit" onClick={() => setDeleteMode(false)}>exit</button>
            </span>
          </Show>
          <Show when={props.restackErr()}>
            <span class="restack-err">{props.restackErr()}</span>
          </Show>
          <Show when={canMutate && (props.projects() || []).some((p) => p.behind > 0)}>
            <ActionBar actions={[props.restackAllAction()]} />
          </Show>
        </div>
        <Show when={(props.projects() || []).length > 6}>
          <input
            class="forest-search"
            placeholder="filter forests…"
            value={forestQuery()}
            onInput={(e) => setForestQuery(e.currentTarget.value)}
          />
        </Show>
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
          <For each={bands()}>
            {(band) => (
              <Show
                when={band.key !== "dormant"}
                fallback={
                  <>
                    <button class="forest-mfold" onClick={() => setDormantOpen(!dormantOpen())}>
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
                <div class="forest-band-head" title={band.hint}>{band.label}</div>
                <For each={band.clusters}>
                  {(cluster) => (
                    <div class="epic-cluster">
                      <h3 class="epic-head" title="one effort spanning repos, linked by epic tag (advisory — each half still merges on its own main)">
                        ⇌ {cluster.epic}
                      </h3>
                      <For each={cluster.items}>
                        {(p) => (
                          <div class="epic-subrow">
                            <span class="epic-repo-badge">{p.repo || "loops"}</span>
                            {props.forestRow(p, false, stepInfo(p, false))}
                          </div>
                        )}
                      </For>
                    </div>
                  )}
                </For>
                <For each={band.items}>{(p) => row(p, false)}</For>
              </Show>
            )}
          </For>
          <Show when={merged().length}>
            <button class="forest-mfold" onClick={() => setMergedOpen(!mergedOpen())}>
              {mergedOpen() ? "▾" : "▸"} {merged().length} recently merged
            </button>
            <Show when={mergedOpen()}>
              <For each={merged()}>{(p) => row(p, true)}</For>
            </Show>
          </Show>
        </Show>
      </section>
      </Show>
  );
}
