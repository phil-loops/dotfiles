import { createEffect, createMemo, createSignal, on, onCleanup, For, Show } from "solid-js";
import { createQuery, useQueryClient } from "@tanstack/solid-query";
import { useViewerLocation, type ViewerLocation } from "./router";
import { canMutate, provider } from "./provider";
import { fetchJSON } from "./api";
import { flattenForest } from "./shared";
import { cachedModel, rememberModel } from "./modelCache";
import { cachedProjects } from "./projectsCache";
import { recents } from "./recents";
import { ForestMap } from "./ForestMap";
import { computeForestLayout, isGhostId } from "./forestLayout";
import { indexById } from "./forestGraph";
import { nearestInDirection, type Dir, type Point } from "./spatialNav";
import { mapTarget, mapOpen, openMap, closeMap, type MapTarget } from "./mapState";
import { paletteOpen } from "./CommandPalette";
import { storySheetOpen } from "./StorySheet";
import type { ForestModel, Project } from "./types";

type Health = Record<string, { drifted: boolean; merged: boolean; contractable: boolean; upstream?: string; ahead?: number }>;

const repoOf = (t: MapTarget) => t.repo ?? "loops";
const prefix = (t: MapTarget) => (t.repo && t.repo !== "loops" ? "/" + t.repo : "");
// the same keys NodeDetail and ForestOverview read, so the overlay paints from their cache
const modelKey = (t: MapTarget) => ["model", repoOf(t), t.name];
const fetchModel = (t: MapTarget) =>
  fetchJSON<ForestModel>(prefix(t) + "/model?branch=" + encodeURIComponent(t.name));
const sameForest = (a: MapTarget | null, b: MapTarget | null) =>
  !!a && !!b && a.name === b.name && repoOf(a) === repoOf(b);

const ARROWS: Record<string, Dir> = { ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right" };

const ROW = "flex w-full cursor-pointer items-baseline gap-2 rounded-[6px] border-0 bg-transparent px-[10px] py-[5px] text-left font-mono text-[12px] leading-[1.5]";

export function MapOverlay() {
  const qc = useQueryClient();
  const { location, navigate } = useViewerLocation();

  // what `m` opens on: the forest this page stands in, else the last forest you were in, else the
  // top of the focus lane — so the key does something useful from a cold home page too.
  const homeForest = (): MapTarget | null => {
    const l = location();
    if (l.kind === "forest") return { name: l.name, repo: l.repo };
    for (const r of recents()) {
      if (r.to.kind === "forest") return { name: r.to.name, repo: r.to.repo };
    }
    const ps = qc.getQueryData<Project[]>(["projects"]) ?? cachedProjects() ?? [];
    const top = [...ps].sort((a, b) => (a.focus ?? 1e9) - (b.focus ?? 1e9) || (b.lastCommit ?? 0) - (a.lastCommit ?? 0))[0];
    return top ? { name: top.name, repo: top.repo === "loops" ? undefined : top.repo } : null;
  };
  // warm the map's model with the page, so the overlay opens on data instead of a fetch
  createEffect(() => {
    const t = homeForest();
    if (t && canMutate) void qc.prefetchQuery({ queryKey: modelKey(t), queryFn: () => fetchModel(t) });
  });
  // any navigation (a pick, back/forward, a palette jump) takes the overlay down with it
  createEffect(on(location, () => closeMap(), { defer: true }));

  const target = () => mapTarget();
  const model = createQuery(() => {
    const t = target() ?? { name: "" };
    return {
      queryKey: modelKey(t),
      queryFn: () => fetchModel(t),
      enabled: !!target(),
      initialData: () => cachedModel(repoOf(t), t.name),
    };
  });
  createEffect(() => {
    const t = target();
    if (t) rememberModel(repoOf(t), t.name, model.data);
  });
  const spine = createMemo(() => (target() ? flattenForest(model.data) : []));
  const ids = createMemo(() => spine().map((n) => n.id).filter(Boolean));
  const health = createQuery(() => ({
    queryKey: ["forest-health", repoOf(target() ?? { name: "" }), ids().join(",")],
    queryFn: () =>
      fetchJSON<Health>(prefix(target()!) + "/forest-health?" + ids().map((b) => "branch=" + encodeURIComponent(b)).join("&")),
    enabled: canMutate && !!target() && ids().length > 0,
  }));
  const prs = createQuery(() => ({
    queryKey: ["branch-prs", repoOf(target() ?? { name: "" })],
    queryFn: () => provider.branchPrs(),
    enabled: !!target(),
  }));
  const myPrs = createQuery(() => ({ queryKey: ["myprs"], queryFn: () => provider.myPrs(), enabled: !!target() }));
  const mine = () => {
    const all = prs.data;
    if (!all) return undefined;
    const own = new Set((myPrs.data || []).map((p) => p.branch));
    return Object.fromEntries(Object.entries(all).filter(([b]) => own.has(b)));
  };

  // the keyboard cursor: starts on the node you're reading, moves spatially over the drawn map
  const [cursor, setCursor] = createSignal("");
  const points = createMemo<Record<string, Point>>(() => {
    if (!spine().length) return {};
    const { pos } = computeForestLayout(indexById(spine()));
    return Object.fromEntries(Object.entries(pos).map(([id, p]) => [id, { x: p.x + 16, y: p.y }]));
  });
  const here = (): string => {
    const l = location();
    if (l.kind !== "forest" || !sameForest(target(), { name: l.name, repo: l.repo }) || !l.node) return "";
    return l.node === "~integration" ? (spine().find((n) => isGhostId(n.id))?.id ?? "") : l.node;
  };
  let centerNext = true;
  createEffect(on(target, () => { setCursor(""); centerNext = true; }));
  createEffect(() => {
    const list = spine();
    if (!list.length || list.some((n) => n.id === cursor())) return;
    const h = here();
    setCursor(h && list.some((n) => n.id === h) ? h : (list.find((n) => !isGhostId(n.id)) ?? list[0]).id);
  });

  let panel: HTMLDivElement | undefined;
  // keep the cursor in view inside the map's own scroller — scrollIntoView would also scroll the
  // page under the overlay. Opening centres it; arrow moves only nudge when it leaves the view.
  createEffect(() => {
    const id = cursor();
    points();
    if (!id || !panel) return;
    requestAnimationFrame(() => {
      const host = panel?.querySelector<HTMLElement>(".fm-fill");
      const el = panel?.querySelector<SVGGElement>(".fm-node.active");
      if (!host || !el) return;
      const h = host.getBoundingClientRect();
      const r = el.getBoundingClientRect();
      const dy = r.top + r.height / 2 - (h.top + h.height / 2);
      const dx = r.left + r.width / 2 - (h.left + h.width / 2);
      if (centerNext) {
        host.scrollBy({ top: dy, left: dx, behavior: "instant" });
        centerNext = false;
      } else if (r.top < h.top + 24 || r.bottom > h.bottom - 24 || r.left < h.left || r.right > h.right) {
        host.scrollBy({ top: dy, left: dx, behavior: "smooth" });
      }
    });
  });

  const go = (branch: string) => {
    const t = target();
    if (!t) return;
    closeMap();
    navigate({ kind: "forest", name: t.name, repo: t.repo, node: isGhostId(branch) ? "~integration" : branch });
  };

  // a compact forest list beside the map: recent first, then the focus lane, then everything by
  // last touch. `/` filters it; picking one swaps the map in place, no page change.
  const projects = createQuery(() => ({
    queryKey: ["projects"],
    queryFn: () => provider.projects(),
    initialData: cachedProjects,
    initialDataUpdatedAt: 0,
    enabled: mapOpen(),
    refetchOnWindowFocus: false,
  }));
  const [filter, setFilter] = createSignal("");
  let filterEl: HTMLInputElement | undefined;
  const forests = createMemo(() => {
    const ps = projects.data ?? [];
    const recent = recents()
      .map((r) => (r.to.kind === "forest" ? r.to : null))
      .filter((r): r is Extract<ViewerLocation, { kind: "forest" }> => !!r);
    const rank = (p: Project) => {
      const i = recent.findIndex((r) => r.name === p.name && (r.repo ?? "loops") === (p.repo ?? "loops"));
      return i >= 0 ? i : p.focus != null ? 100 + p.focus : 1e6;
    };
    const q = filter().trim().toLowerCase();
    return ps
      .filter((p) => !q || p.name.toLowerCase().includes(q))
      .sort((a, b) => rank(a) - rank(b) || (b.lastCommit ?? 0) - (a.lastCommit ?? 0))
      .slice(0, 60);
  });
  const pickForest = (p: Project) => {
    setFilter("");
    filterEl?.blur();
    openMap({ name: p.name, repo: p.repo === "loops" ? undefined : p.repo });
  };

  const onKey = (e: KeyboardEvent) => {
    const el = e.target as HTMLElement | null;
    const typing = !!el?.matches?.("input, textarea, select, [contenteditable]");
    if (!mapOpen()) {
      if (e.key !== "m" || e.metaKey || e.ctrlKey || e.altKey || typing || paletteOpen() || storySheetOpen()) return;
      const t = homeForest();
      if (!t) return;
      e.preventDefault();
      openMap(t);
      return;
    }
    if (paletteOpen() || e.metaKey || e.ctrlKey || e.altKey) return;
    if (typing) {
      if (el !== filterEl) return;
      if (e.key === "Escape") { setFilter(""); filterEl?.blur(); }
      else if (e.key === "Enter" && forests()[0]) pickForest(forests()[0]);
      else return;
      e.preventDefault();
      e.stopPropagation();
      return;
    }
    // the overlay owns the keyboard while it's up: nothing reaches the page underneath
    e.stopPropagation();
    const dir = ARROWS[e.key];
    if (dir) {
      const next = nearestInDirection(points(), cursor(), dir);
      if (next) setCursor(next);
    } else if (e.key === "Enter" && cursor()) go(cursor());
    else if (e.key === "Escape" || e.key === "m") closeMap();
    else if (e.key === "/") queueMicrotask(() => filterEl?.focus());
    else if (e.key !== "Tab") return;
    e.preventDefault();
  };
  // document capture, registered after the usage tracker's: the key is still counted, and
  // stopPropagation here keeps it from the node page's own shortcuts on window.
  document.addEventListener("keydown", onKey, { capture: true });
  onCleanup(() => document.removeEventListener("keydown", onKey, { capture: true }));

  createEffect(() => {
    document.documentElement.style.overflow = mapOpen() ? "hidden" : "";
  });

  const nodeCount = () => spine().filter((n) => !isGhostId(n.id)).length;
  const isCurrent = (p: Project) => sameForest(target(), { name: p.name, repo: p.repo === "loops" ? undefined : p.repo });

  return (
    <Show when={target()}>
      {(t) => (
        <div
          ref={panel}
          class="map-overlay fixed inset-0 z-[75] grid grid-cols-[212px_1fr] bg-[rgba(12,10,6,0.96)] backdrop-blur-[3px] animate-tip-in motion-reduce:animate-none max-[640px]:grid-cols-[1fr]"
          role="dialog"
          aria-label="forest map"
        >
          <aside class="mo-forests flex min-h-0 flex-col border-r border-rule bg-[linear-gradient(180deg,var(--color-vellum-raise),var(--color-vellum-night))] max-[640px]:hidden">
            <input
              ref={filterEl}
              class="mo-filter mx-[10px] mt-[16px] mb-[8px] rounded-[7px] border border-rule bg-vellum-night px-[10px] py-[6px] font-mono text-[12px] text-ink outline-none placeholder:text-ink-faint focus:border-gold-deep"
              placeholder="/ find a forest"
              value={filter()}
              onInput={(e) => setFilter(e.currentTarget.value)}
            />
            <div class="mo-list min-h-0 flex-1 overflow-y-auto overscroll-contain px-[6px] pb-[16px]">
              <For each={forests()}>
                {(p) => (
                  <button
                    class={`mo-forest ${ROW} ${isCurrent(p) ? "bg-vellum-edge text-gold-leaf" : "text-ink-dim hover:bg-vellum-edge hover:text-ink"}`}
                    title={`show ${p.name}'s map`}
                    onClick={() => pickForest(p)}
                  >
                    <span class="w-[10px] flex-none text-[10px] text-gold-leaf">{p.focus != null ? "★" : ""}</span>
                    <span class="min-w-0 flex-1 overflow-hidden text-ellipsis whitespace-nowrap">{p.name}</span>
                    <span class="flex-none text-[10px] text-ink-faint">{p.branches}</span>
                  </button>
                )}
              </For>
            </div>
          </aside>
          <section class="mo-main grid min-h-0 min-w-0 grid-rows-[auto_1fr_auto]">
            <header class="mo-head flex items-baseline gap-4 border-b border-rule px-6 py-[14px]">
              <span class="mo-title font-display text-[21px] italic text-ink">{t().name}</span>
              <Show when={nodeCount()}>
                <span class="font-mono text-[11px] tracking-[0.04em] text-ink-faint">{nodeCount()} {nodeCount() === 1 ? "node" : "nodes"}</span>
              </Show>
              <button
                class="mo-page ml-auto cursor-pointer border-0 bg-transparent font-mono text-[11px] text-ink-faint hover:text-gold-leaf"
                title="open this forest's own page — stories, merge story, a linkable URL"
                onClick={() => { closeMap(); navigate({ kind: "forest", name: t().name, repo: t().repo }); }}
              >forest page ↗</button>
              <button
                class="mo-close cursor-pointer border-0 bg-transparent px-[4px] text-[19px] leading-none text-ink-faint hover:text-ink"
                title="close the map (esc)"
                onClick={closeMap}
              >×</button>
            </header>
            <div class="mo-map min-h-0 min-w-0">
              <Show
                when={spine().length}
                fallback={<p class="px-6 py-10 font-display italic text-ink-faint">{model.isFetching ? "reading the forest…" : "no branches in this forest"}</p>}
              >
                <ForestMap
                  fill
                  spine={spine}
                  active={cursor}
                  health={() => health.data}
                  prs={mine}
                  onPick={go}
                  onClose={closeMap}
                />
              </Show>
            </div>
            <footer class="mo-hint flex gap-[14px] border-t border-rule px-6 py-[8px] font-mono text-[10.5px] tracking-[0.04em] text-ink-faint [&_b]:font-semibold [&_b]:text-ink-dim">
              <span><b>←↑↓→</b> move</span>
              <span><b>↵</b> open</span>
              <span class="max-[640px]:hidden"><b>/</b> find a forest</span>
              <span><b>esc</b> close</span>
            </footer>
          </section>
        </div>
      )}
    </Show>
  );
}
