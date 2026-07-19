import { For, Show, createMemo, createSignal, createEffect } from "solid-js";
import { createQuery } from "@tanstack/solid-query";
import { useViewerLocation, buildPath, type HomeTab, type ViewerLocation } from "./router";
import { provider } from "./provider";
import { leaf } from "./shared";
import { cachedProjects } from "./projectsCache";

// ── the persistent left rail: app-wide nav chrome ────────────────────
//
// Lives in Layout (not Home) so every altitude — home, forest overview, node review —
// shares one nav grammar. Tiles light from the ROUTE: a home tab lights its own tile, being
// inside a forest lights Forests, an imported review lights Work; the place you're standing
// shows as a gold context tile beneath, which climbs back to its forest overview.

const THUMB_BASE =
  "thumb relative flex cursor-pointer flex-col items-center gap-[9px] border-l-2 bg-transparent px-0 transition-[color,background] duration-[140ms] motion-reduce:transition-none max-[640px]:flex-row max-[640px]:border-l-0 max-[640px]:border-b-2 max-[640px]:px-[14px] max-[640px]:py-[10px]";
const THUMB = `${THUMB_BASE} py-[18px]`;
const THUMB_SM = `${THUMB_BASE} py-[10px] flex-none`;
const THUMB_OFF = "border-transparent text-ink-faint hover:bg-vellum-edge hover:text-ink-dim";
const THUMB_ON =
  "border-l-gold-leaf bg-vellum-edge text-gold-leaf max-[640px]:border-l-transparent max-[640px]:border-b-gold-leaf";
// vertical text runs its inline axis DOWN the rail, so truncation is a max-HEIGHT there;
// on mobile the rail is horizontal and it flips back to a max-width.
const THUMB_LBL_BASE =
  "thumb-label font-display italic tracking-[0.04em] [writing-mode:vertical-rl] [text-orientation:mixed] overflow-hidden text-ellipsis whitespace-nowrap max-[640px]:[writing-mode:horizontal-tb] max-[640px]:max-h-none";
const THUMB_LBL = `${THUMB_LBL_BASE} text-[17px]`;
const COUNT =
  "thumb-count min-w-[17px] rounded-[6px] border bg-vellum-night px-[5px] py-px text-center font-mono text-[10px]";
const CTX_LBL = `${THUMB_LBL_BASE} text-[14px] max-h-[200px] max-[640px]:max-w-[160px]`;
const RECENT_LBL = `${THUMB_LBL_BASE} text-[12px] max-h-[140px] max-[640px]:max-w-[120px]`;

// the tile a location belongs under: reviews are Work-tab things, everything branch-shaped
// lives under Forests.
const tileOf = (l: ViewerLocation): HomeTab =>
  l.kind === "home" ? l.tab : l.kind === "review" ? "work" : "forests";

export function NavRail() {
  const { location, navigate } = useViewerLocation();
  const prs = createQuery(() => ({
    queryKey: ["myprs"],
    queryFn: () => provider.myPrs(),
  }));
  const reviewReqs = createQuery(() => ({
    queryKey: ["review-requests"],
    queryFn: () => provider.reviewRequests(),
  }));
  const projects = createQuery(() => ({
    queryKey: ["projects"],
    queryFn: () => provider.projects(),
    initialData: cachedProjects,
    initialDataUpdatedAt: 0,
    // counts are ambient: ride the shared cache (Home + SSE invalidation refresh it), don't
    // add our own churn — a node-review tab shouldn't rerun the /projects fan-out on focus.
    refetchOnWindowFocus: false,
  }));
  const active = createMemo(() => tileOf(location()));
  // where you're standing, when it's deeper than home — one gold tile, climbs to the overview.
  const context = createMemo(() => {
    const l = location();
    if (l.kind === "forest") {
      return { label: leaf(l.name), to: { kind: "forest", name: l.name, repo: l.repo } as ViewerLocation };
    }
    if (l.kind === "standalone") {
      return { label: leaf(l.branch), to: { kind: "standalone", branch: l.branch } as ViewerLocation };
    }
    if (l.kind === "review") {
      return { label: `PR ${l.pr}`, to: { kind: "review", pr: l.pr } as ViewerLocation };
    }
    return null;
  });
  // recently-accessed places linger under the current one — dimmed, one click back. MRU,
  // deduped by destination, capped. Persisted so the stack survives a reload.
  type Ctx = { label: string; to: ViewerLocation };
  const RECENTS_KEY = "viewerRecentContexts";
  const readRecents = (): Ctx[] => {
    try {
      const s = localStorage.getItem(RECENTS_KEY);
      if (s) return JSON.parse(s);
      const old = localStorage.getItem("viewerLastContext"); // predecessor: single lingering tile
      return old ? [JSON.parse(old)] : [];
    } catch {
      return [];
    }
  };
  const [recents, setRecents] = createSignal<Ctx[]>(readRecents());
  createEffect(() => {
    const c = context();
    if (!c) return;
    const key = buildPath(c.to);
    setRecents((r) => {
      const next = [c, ...r.filter((x) => buildPath(x.to) !== key)].slice(0, 6);
      try { localStorage.setItem(RECENTS_KEY, JSON.stringify(next)); } catch { /* quota/private mode — skip */ }
      return next;
    });
  });
  const others = createMemo(() => {
    const cur = context();
    const curKey = cur ? buildPath(cur.to) : null;
    return recents().filter((x) => buildPath(x.to) !== curKey).slice(0, 3);
  });
  const dismiss = (to: ViewerLocation) => {
    const key = buildPath(to);
    setRecents((r) => {
      const next = r.filter((x) => buildPath(x.to) !== key);
      try { localStorage.setItem(RECENTS_KEY, JSON.stringify(next)); } catch { /* quota/private mode — skip */ }
      return next;
    });
  };
  return (
    <nav class="thumb-index sticky top-0 flex h-screen flex-col gap-1 self-start overflow-y-auto border-r border-rule bg-[linear-gradient(180deg,var(--color-vellum-raise),var(--color-vellum-night))] pt-[22px] pb-[40px] max-[640px]:static max-[640px]:h-auto max-[640px]:flex-row max-[640px]:border-r-0 max-[640px]:border-b max-[640px]:pt-[10px] max-[640px]:pb-[10px] max-[640px]:px-[10px]">
      <button
        class="thumb-brand mb-[26px] cursor-pointer border-0 bg-transparent text-center text-[19px] text-gold-leaf max-[640px]:hidden"
        title="canopy — home"
        onClick={() => navigate({ kind: "home", tab: "work" })}
      >
        <span class="brand-mark text-[18px] not-italic text-gold-leaf">✦</span>
      </button>
      <For each={[
        { id: "work" as const, label: "Work", count: (prs.data || []).length + (reviewReqs.data || []).length },
        { id: "forests" as const, label: "Forests", count: (projects.data || []).length },
      ]}>
        {(t) => (
          <button
            class={`${THUMB} ${active() === t.id ? THUMB_ON : THUMB_OFF}`}
            classList={{ active: active() === t.id }}
            onClick={() => navigate({ kind: "home", tab: t.id })}
          >
            <span class={THUMB_LBL}>{t.label}</span>
            <Show when={t.count}>
              <span class={`${COUNT} ${active() === t.id ? "border-gold-deep text-gold-leaf" : "border-rule text-ink-faint"}`}>{t.count}</span>
            </Show>
          </button>
        )}
      </For>
      <Show when={context() || others().length}>
        <div class="rail-sep mx-[18px] my-[6px] h-px flex-none bg-rule max-[640px]:hidden" />
      </Show>
      <Show when={context()}>
        {(c) => (
          <button
            class={`thumb-context ${THUMB} ${THUMB_ON}`}
            classList={{ active: true }}
            title={`${c().label} — up to the overview`}
            onClick={() => navigate(c().to)}
          >
            <span class={CTX_LBL}>{c().label}</span>
          </button>
        )}
      </Show>
      <For each={others()}>
        {(c) => (
          <button
            class={`thumb-recent group ${THUMB_SM} ${THUMB_OFF}`}
            title={`back to ${c.label}`}
            onClick={() => navigate(c.to)}
          >
            <span class={RECENT_LBL}>{c.label}</span>
            <span
              class="thumb-dismiss absolute top-[2px] right-[4px] rounded-[4px] px-[3px] font-mono text-[11px] leading-[1.3] text-ink-faint opacity-0 transition-opacity duration-[120ms] group-hover:opacity-100 hover:bg-vellum-night hover:text-ink max-[640px]:static max-[640px]:opacity-100"
              title={`forget ${c.label}`}
              onClick={(e) => { e.stopPropagation(); dismiss(c.to); }}
            >✕</span>
          </button>
        )}
      </For>
    </nav>
  );
}
