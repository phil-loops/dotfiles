import { createSignal, createMemo, Show, For, type JSX } from "solid-js";
import { deleteMode, setDeleteMode } from "./deleteMode";
import { canMutate } from "./provider";
import { ActionBar, type Action } from "./actions";
import { interestPips, mergedAgo } from "./shared";
import type { Project } from "./types";

// The Forests tab: the complete forest index grouped by repo → priority tiers, with cross-repo
// epic clusters pulled to the top and a per-repo recently-merged fold. Owns its own filter/fold
// state; the row itself comes in as a prop (Home wires its hover/ctx/parked handlers).
export function ForestsList(props: {
  tab: () => string;
  projects: () => Project[] | undefined;
  restackErr: () => string | null;
  restackAllAction: () => Action;
  forestRow: (p: Project, folded: boolean) => JSX.Element;
}) {
  const [forestQuery, setForestQuery] = createSignal("");
  // Forests recency — one opinionated order (Phil, 2026-07-05). "Most recently alive": the latest
  // of local commit, PR opened, and merge-to-main.
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
  // Group the home list by repo (loops first, then alphabetical), then within each repo split the
  // active forests into PRIORITY TIERS (interest level, descending) so same-priority work stands
  // together, and pull recently-merged forests aside into their own fold.
  // A project's identity is (repo, name) — the same forest name can exist in two repos.
  const pkey = (p: Project) => (p.repo || "loops") + " " + p.name;
  // Cross-repo "epic" clusters: same stack-project.<name>.epic tag spanning ≥2 repos folds into one
  // card at the top (ranked by its members' max interest). A single-repo epic is left in its normal
  // repo bucket — pulling one row out into a lone "cluster" would only fragment the list.
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
        interest: Math.max(...items.map((p) => p.interest ?? 0)),
        items: items.sort((a, b) => forestTs(b) - forestTs(a)),
      }))
      .sort((a, b) => b.interest - a.interest || b.items.length - a.items.length);
  });
  const clusteredKeys = createMemo(() => new Set(epicClusters().flatMap((c) => c.items.map(pkey))));
  const forestGroups = createMemo(() => {
    const clustered = clusteredKeys();
    const by = new Map<string, Project[]>();
    for (const p of filteredForests()) {
      if (clustered.has(pkey(p))) continue; // shown in an epic cluster above, not under its repo header
      const r = p.repo || "loops";
      (by.get(r) ?? by.set(r, []).get(r)!).push(p);
    }
    return [...by.entries()]
      .sort(([a], [b]) => (a === "loops" ? -1 : b === "loops" ? 1 : a.localeCompare(b)))
      .map(([repo, items]) => {
        const merged = items.filter(recentlyMerged).sort((a, b) => forestTs(b) - forestTs(a));
        const active = items.filter((p) => !recentlyMerged(p));
        const levels = [...new Set(active.map((p) => p.interest ?? 0))].sort((a, b) => b - a);
        const tiers = levels.map((interest) => ({
          interest,
          // within a tier, most-recently-alive first (blended commit/PR/merge recency).
          items: active
            .filter((p) => (p.interest ?? 0) === interest)
            .sort((a, b) => forestTs(b) - forestTs(a)),
        }));
        return { repo, tiers, merged };
      });
  });
  const multiRepo = createMemo(() => forestGroups().length > 1);
  // recently-merged fold is collapsed per repo until clicked.
  const [mergedOpenSet, setMergedOpenSet] = createSignal<Set<string>>(new Set());
  const mergedOpen = (r: string) => mergedOpenSet().has(r);
  const toggleMerged = (r: string) =>
    setMergedOpenSet((s) => {
      const n = new Set(s);
      if (n.has(r)) { n.delete(r); } else { n.add(r); }
      return n;
    });
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
          <For each={epicClusters()}>
            {(cluster) => (
              <div class="epic-cluster">
                <h3 class="epic-head" title="one effort spanning repos, linked by epic tag (advisory — each half still merges on its own main)">
                  ⇌ {cluster.epic}
                </h3>
                <For each={cluster.items}>
                  {(p) => (
                    <div class="epic-subrow">
                      <span class="epic-repo-badge">{p.repo || "loops"}</span>
                      {props.forestRow(p, false)}
                    </div>
                  )}
                </For>
              </div>
            )}
          </For>
          <For each={forestGroups()}>
            {(group) => (
              <>
                <Show when={multiRepo()}>
                  <h3 class="forest-repo-head">{group.repo}</h3>
                </Show>
                <For each={group.tiers}>
                  {(tier) => (
                    <>
                      <Show when={group.tiers.length > 1}>
                        <div class="forest-tier-head">
                          {tier.interest > 0 ? interestPips(tier.interest) : "no priority"}
                        </div>
                      </Show>
                      <For each={tier.items}>{(p) => props.forestRow(p, false)}</For>
                    </>
                  )}
                </For>
                <Show when={group.merged.length}>
                  <button class="forest-mfold" onClick={() => toggleMerged(group.repo)}>
                    {mergedOpen(group.repo) ? "▾" : "▸"} {group.merged.length} recently merged
                  </button>
                  <Show when={mergedOpen(group.repo)}>
                    <For each={group.merged}>{(p) => props.forestRow(p, true)}</For>
                  </Show>
                </Show>
              </>
            )}
          </For>
        </Show>
      </section>
      </Show>
  );
}
