import { createSignal, createEffect, onCleanup, createMemo, Show } from "solid-js";
import { useQueryClient, createQuery } from "@tanstack/solid-query";
import { useViewerLocation, forestKey, forestRepo, withNode } from "./router";
import { provider, canMutate, withRepo } from "./provider";
import { leaf, interestPips, flattenForest } from "./shared";
import { cameFrom } from "./cameFrom";
import { cachedModel, rememberModel } from "./modelCache";
import { ContinuesStrip } from "./ContinuesStrip";
import { overviewView, setOverviewView } from "./overviewView";
import { ForestMap } from "./ForestMap";
import { ForestLanding } from "./ForestLanding";
import { StoriesEditor } from "./StoriesEditor";
import { TicketChip } from "./TicketChip";
import type { Purpose } from "./types";

// ── forest overview: the map as the landing hero (no node selected) ──────
// Picking a node navigates to /forests/<project>/<branch> — the per-node review surface.
// The old inline sheet's --gold/--raised fallbacks were live (#e0ad4e / #1b1815 — those
// tokens were never defined); they stay raw below.
const FO_BTN = "cursor-pointer rounded-[6px] px-[10px] py-[3px] text-[11px] leading-[1.55]";
const FO_VIEW_OFF = "border-transparent bg-transparent text-ink-faint hover:text-ink-dim";
const FO_VIEW_ON = "border-rule bg-[#1b1815] text-[#e0ad4e]";
// Warming — the kiln heating before it can read the pieces (cold /forest-health, ~5s vs
// GitHub). Ember, never the blessed gold; a delay guard keeps it off sub-second loads.
const FO_WARM = "fo-warm inline-flex items-center gap-2 text-[11px] tracking-[0.05em] whitespace-nowrap max-[600px]:whitespace-normal";
const FO_WARM_STATE: Record<string, string> = {
  reading: "text-ember",
  read: "animate-fo-warm-fade text-ink-dim",
  refreshing: "text-ink-faint",
};
const FO_COAL = "fo-coal flex-none rounded-full motion-reduce:animate-none";
const FO_COAL_STATE: Record<string, string> = {
  reading: "h-[7px] w-[7px] animate-fo-breathe bg-ember shadow-[0_0_8px_var(--color-ember-wash)]",
  read: "h-[7px] w-[7px] bg-gold-leaf shadow-[0_0_8px_var(--color-gold-wash)]",
  refreshing: "h-[5px] w-[5px] animate-fo-breathe-slow bg-ink-faint shadow-none",
};

// The forest header's warming indicator. Three honest states, straight from the health query —
// which maps 1:1 to the server's SWR cache: pending-with-no-data = cold read (~5s vs GitHub),
// fetching-with-data = a stale-while-revalidate background refresh, settled = read. A 400ms delay
// guard keeps it off warm-cache loads (~0.35s) so only a genuine cold read reveals it.
function WarmingRibbon(props: {
  loading: boolean;              // health query in flight
  hasData: boolean;             // some health already resolved (SWR shows it while refetching)
  needsAttention: number;       // nodes with drift/ghost — the count worth surfacing
}) {
  const [shown, setShown] = createSignal(false);   // delay-guarded: only after 400ms of a cold read
  const [justRead, setJustRead] = createSignal(false);
  let revealT: ReturnType<typeof setTimeout> | undefined;
  let readT: ReturnType<typeof setTimeout> | undefined;
  const cold = () => props.loading && !props.hasData;

  createEffect(() => {
    if (cold()) {
      clearTimeout(revealT);
      revealT = setTimeout(() => setShown(true), 400);
    } else {
      clearTimeout(revealT);
      if (shown()) {                                 // a cold read we actually surfaced just landed
        setShown(false);
        setJustRead(true);
        clearTimeout(readT);
        readT = setTimeout(() => setJustRead(false), 1600);
      }
    }
  });
  onCleanup(() => { clearTimeout(revealT); clearTimeout(readT); });

  const state = (): "reading" | "read" | "refreshing" | "" => {
    if (shown()) return "reading";
    if (justRead()) return "read";
    if (props.loading && props.hasData) return "refreshing";
    return "";
  };
  const attn = () => props.needsAttention;

  return (
    <Show when={state()}>
      {(s) => (
        <span class={`${FO_WARM} ${s()} ${FO_WARM_STATE[s()]}`} aria-live="polite">
          <span class={`${FO_COAL} ${FO_COAL_STATE[s()]}`} />
          <Show when={s() === "reading"}>warming · reading branch health from GitHub</Show>
          <Show when={s() === "read"}>
            <Show when={attn() > 0} fallback={<>read · all clear</>}>
              read · <b class="font-medium text-gold-leaf">{attn()}</b> {attn() === 1 ? "needs" : "need"} attention
            </Show>
          </Show>
          <Show when={s() === "refreshing"}>· refreshing</Show>
        </span>
      )}
    </Show>
  );
}


// Pin/unpin this forest to the focus lane from its own page — the same stack-project.<p>.focus
// rank Home's context menu writes, so no trip back to Home to mark what you're pushing now.
function FocusPin(props: { project: string; repo?: string; focused: boolean }) {
  const qc = useQueryClient();
  const [busy, setBusy] = createSignal(false);
  const toggle = async () => {
    setBusy(true);
    await fetch("/focus", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ repo: props.repo ?? "", project: props.project, on: !props.focused }),
    }).catch(() => {});
    await qc.invalidateQueries({ queryKey: ["model"] });
    qc.invalidateQueries({ queryKey: ["projects"] });
    setBusy(false);
  };
  return (
    <button
      class={`fo-focus cursor-pointer border-0 bg-transparent p-0 text-[13px] leading-none ${props.focused ? "text-gold-leaf hover:text-ink-dim" : "text-ink-faint hover:text-gold-leaf"}`}
      data-track="forest.focus-pin"
      classList={{ on: props.focused }}
      disabled={busy()}
      title={props.focused ? "unpin from the focus lane" : "pin to the focus lane — the hand-ordered 'pushing now' strip at the top of Home"}
      onClick={toggle}
    >{props.focused ? "★" : "☆"}</button>
  );
}

export function ForestOverview() {
  const { location, navigate } = useViewerLocation();
  const project = () => forestKey(location());
  const [ovView, setOvView] = [overviewView, setOverviewView]; // shared module signal so ⌘K can open straight into a view
  const model = createQuery(() => ({
    // repo in the key so loops/monotoad forests with the same name don't share a cache entry
    // and a cross-repo nav refetches; provider reads the repo from the URL at fetch time.
    queryKey: ["model", forestRepo(location()) ?? "loops", project()],
    queryFn: () => provider.model(project()),
    enabled: !!project(),
    initialData: () => cachedModel(forestRepo(location()) ?? "loops", project()),
  }));
  createEffect(() => rememberModel(forestRepo(location()) ?? "loops", project(), model.data));
  const spine = createMemo(() => flattenForest(model.data));
  const healthIds = createMemo(() => spine().map((n) => n.id).filter(Boolean));
  const health = createQuery(() => ({
    queryKey: ["forest-health", forestRepo(location()) ?? "loops", healthIds().join(",")],
    queryFn: () =>
      fetch(withRepo("/forest-health?" + healthIds().map((b) => "branch=" + encodeURIComponent(b)).join("&"))).then(
        (r) =>
          r.json() as Promise<
            Record<string, { drifted: boolean; merged: boolean; contractable: boolean; upstream?: string; ahead?: number }>
          >,
      ),
    enabled: canMutate && healthIds().length > 0,
    // health wakes on focus (global default is refetchOnWindowFocus: false); unattended
    // convergence is the server's job — its pulse freshens the remote world and pushes an
    // SSE update, so N tabs cost one poller instead of N intervals.
    refetchOnWindowFocus: true,
  }));
  // open PRs keyed by head branch — drives the per-node PR badge in the map. The rich /prs
  // map (base/toMain/review) is filtered to MY PRs via /myprs, so a node only badges a PR I own.
  const prs = createQuery(() => ({
    queryKey: ["branch-prs", forestRepo(location()) ?? "loops"],
    queryFn: () => provider.branchPrs(),
  }));
  const myPrs = createQuery(() => ({ queryKey: ["myprs"], queryFn: () => provider.myPrs() }));
  const myBranches = createMemo(() => new Set((myPrs.data || []).map((p) => p.branch)));
  const myBranchPrs = () => {
    const all = prs.data;
    if (!all) return undefined;
    const mine = myBranches();
    return Object.fromEntries(Object.entries(all).filter(([b]) => mine.has(b)));
  };
  // ghost endstate (✦ <project>) opens its integration diff; every other node opens itself.
  // withNode keeps the location's repo so a monotoad node stays in monotoad.
  const open = (b: string) => navigate(withNode(location(), b));
  const nodeCount = () => spine().filter((n) => !n.id.startsWith("✦")).length;
  // nodes the read turned up as needing a look — drifted off-parent or a merged ghost.
  const needsAttention = () =>
    Object.values(health.data || {}).filter((v) => v.drifted || v.merged).length;

  // hover a node in the map → gloss its full purpose in a caption strip pinned to the
  // bottom edge, never floating over the graph (cached; guard the async gap so a pointer
  // that left before /purpose resolved doesn't pop a stale tip).
  const purposeCache = new Map<string, Purpose>();
  const [tip, setTip] = createSignal<{ branch: string; text: string } | null>(null);
  let tipBranch: string | null = null;
  const showTip = async (branch: string) => {
    tipBranch = branch;
    let p = purposeCache.get(branch);
    if (!p) {
      try { p = await provider.purpose(branch); }
      catch { p = { thesis: "" }; }
      purposeCache.set(branch, p);
    }
    if (tipBranch !== branch || !p.thesis) return;
    setTip({ branch, text: p.thesis });
  };
  const hideTip = () => { tipBranch = null; setTip(null); };

  return (
    <div class="forest-overview min-h-screen bg-vellum-night">
      <header class="fo-head sticky top-0 z-[2] flex items-baseline gap-4 border-x-0 border-t-0 border-b border-solid border-rule bg-vellum-night px-6 py-4">
        <span class="fo-project font-display text-[21px] italic text-ink">{project()}</span>
        <Show when={canMutate && model.data}>
          <FocusPin project={project()} repo={forestRepo(location())} focused={model.data!.focus != null} />
        </Show>
        <Show when={(model.data?.interest ?? 0) > 0}>
          <span class="fo-interest text-[11px] tracking-[-1px] text-gold-leaf" title={`interest ${model.data!.interest} — promoted on the Forests home`}>
            {interestPips(model.data!.interest!)}
          </span>
        </Show>
        <Show when={canMutate || model.data?.ticket}>
          <TicketChip project={project()} ticket={model.data?.ticket} />
        </Show>
        <Show when={spine().length}>
          <span class="fo-meta text-[12px] tracking-[0.04em] text-ink-faint">{nodeCount()} {nodeCount() === 1 ? "node" : "nodes"}</span>
          <WarmingRibbon loading={health.isFetching} hasData={!!health.data} needsAttention={needsAttention()} />
          <div class="fo-views ml-auto inline-flex gap-[2px]" role="group" aria-label="overview view">
            <button class={`${FO_BTN} border ${ovView() === "map" ? FO_VIEW_ON : FO_VIEW_OFF}`} classList={{ on: ovView() === "map" }} onClick={() => setOvView("map")} title="spatial forest map">⊞ map</button>
            <button class={`fo-view-story ${FO_BTN} border ${ovView() === "story" ? FO_VIEW_ON : FO_VIEW_OFF}`} classList={{ on: ovView() === "story" }} onClick={() => setOvView("story")} title="the titles that land on main, in merge order">≣ landing</button>
            <button class={`fo-view-stories ${FO_BTN} border ${ovView() === "stories" ? FO_VIEW_ON : FO_VIEW_OFF}`} classList={{ on: ovView() === "stories" }} onClick={() => setOvView("stories")} title="one plain-English line per branch, edited in place">✎ stories</button>
          </div>
        </Show>
      </header>
      <Show
        when={spine().length}
        fallback={<p class="loading fo-empty px-6 py-10 italic text-ink-faint">{model.isLoading ? "loading…" : "no branches in this forest"}</p>}
      >
        <Show
          when={ovView() !== "map"}
          fallback={<>
            <ContinuesStrip model={() => model.data} onOpen={(p) => navigate({ kind: "forest", name: p, repo: forestRepo(location()) })} />
            <ForestMap
              page
              spine={spine}
              active={() => (spine().some((n) => n.id === cameFrom()) ? cameFrom() : "")}
              health={() => health.data}
              prs={myBranchPrs}
              onPick={open}
              onClose={() => {}}
              onHoverNode={showTip}
              onLeaveNode={hideTip}
            />
          </>}
        >
          <Show when={ovView() === "stories"} fallback={<ForestLanding project={project()} repo={forestRepo(location())} onPick={open} />}>
            <div class="fo-stories h-[calc(100dvh-62px)] min-h-0">
              <StoriesEditor project={project()} branch={spine()[0].id} onPick={open} />
            </div>
          </Show>
        </Show>
      </Show>
      <Show when={tip()}>
        {(t) => (
          <div class="purpose-tip pointer-events-none fixed bottom-4 left-1/2 z-[60] max-w-[min(680px,calc(100vw-48px))] -translate-x-1/2 animate-tip-in rounded-[9px] border border-solid border-rule border-l-2 border-l-gold-deep bg-vellum-raise px-[14px] py-[9px] font-mono text-[11.5px] leading-[1.5] text-ink-dim shadow-[0_10px_30px_rgba(0,0,0,0.5)] motion-reduce:animate-none [&_b]:font-medium [&_b]:text-ink">
            <b>{leaf(t().branch)}</b> — {t().text}
          </div>
        )}
      </Show>
    </div>
  );
}
