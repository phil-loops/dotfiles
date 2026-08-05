import { createSignal, createEffect, onCleanup, createMemo, Show } from "solid-js";
import { useQueryClient, createQuery } from "@tanstack/solid-query";
import { useViewerLocation, forestKey, forestRepo, withNode } from "./router";
import { provider, canMutate, withRepo } from "./provider";
import { leaf, interestPips, flattenForest } from "./shared";
import { cameFrom } from "./cameFrom";
import { overviewView, setOverviewView } from "./overviewView";
import { ForestMap } from "./ForestMap";
import MergeStory from "./MergeStory";
import { chatToTmux } from "./chatDrawer";
import { SessionPicker } from "./SessionPicker";
import type { Purpose } from "./types";

// ── forest overview: the map as the landing hero (no node selected) ──────
// Picking a node navigates to /forests/<project>/<branch> — the per-node review surface.
// The old inline sheet's --gold/--raised fallbacks were live (#e0ad4e / #1b1815 — those
// tokens were never defined); they stay raw below.
const FO_BTN = "cursor-pointer rounded-[6px] px-[10px] py-[3px] text-[11px] leading-[1.55]";
const FO_VIEW_OFF = "border-transparent bg-transparent text-ink-faint hover:text-ink-dim";
const FO_VIEW_ON = "border-rule bg-[#1b1815] text-[#e0ad4e]";
const FO_STAGE = `fo-stage ${FO_BTN} ml-[6px] border enabled:hover:border-patina enabled:hover:text-ink disabled:cursor-default disabled:opacity-50`;
const FO_STAGE_QUIET = "border-rule bg-transparent text-patina";
const FO_STAGE_ARMED = "border-patina bg-patina text-vellum-night";
const FO_STAGE_MSG = "fo-stage-msg ml-[6px] text-[11px] whitespace-nowrap";
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


// "stage for testing" — restack this forest's chain forward onto fresh origin/main, then
// move the MAIN working tree onto the tip so the :3000 dev server serves the whole feature.
// Two-click armed (it moves Phil's checkout); every guard re-verified server-side, and a
// mid-chain conflict restores all branches to their pre-stage snapshots.
function StageButton(props: { project: string }) {
  const [armed, setArmed] = createSignal(false);
  const [busy, setBusy] = createSignal(false);
  const [msg, setMsg] = createSignal<{ text: string; bad?: boolean } | null>(null);
  let disarm: ReturnType<typeof setTimeout>;
  const fire = async () => {
    if (!armed()) {
      setArmed(true);
      clearTimeout(disarm);
      disarm = setTimeout(() => setArmed(false), 6000);
      return;
    }
    clearTimeout(disarm);
    setArmed(false);
    setBusy(true);
    setMsg(null);
    const r = await fetch(withRepo("/stage"), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ project: props.project }),
    })
      .then((x) => x.json() as Promise<{ ok?: boolean; err?: string; tip?: string; moved?: string[]; alreadyStaged?: boolean }>)
      .catch((e) => ({ ok: false, err: String(e) }));
    setBusy(false);
    if (r.ok) {
      const re = r as { tip?: string; moved?: string[]; alreadyStaged?: boolean };
      setMsg({
        text: re.alreadyStaged
          ? `✓ already staged — checkout is on ${re.tip}`
          : `✓ ${re.tip} on your checkout${re.moved?.length ? ` · ${re.moved.length} rebased` : ""}`,
      });
    } else {
      setMsg({ text: `✗ ${r.err || "stage failed"}`, bad: true });
    }
  };
  return (
    <>
      <button
        class={`${FO_STAGE} ${armed() ? FO_STAGE_ARMED : FO_STAGE_QUIET}`}
        classList={{ armed: armed() }}
        disabled={busy()}
        title="stage for testing — restack this chain onto fresh origin/main, then move your main checkout onto the tip so the dev server serves it. Refuses on a dirty checkout, an open PR in the chain, or anything but a single main-rooted line."
        onClick={fire}
      >
        {busy() ? "staging…" : armed() ? "confirm: move my checkout" : "⇪ stage"}
      </button>
      <Show when={msg()}>
        <span class={`${FO_STAGE_MSG} ${msg()!.bad ? "text-del" : "text-ink-dim"}`} classList={{ bad: !!msg()!.bad }}>{msg()!.text}</span>
      </Show>
    </>
  );
}

type ShipResult = {
  ok?: boolean; err?: string; alreadyReady?: boolean; moved?: string[]; conflict?: string;
  unseatable?: string[]; contracted?: { branch: string }[]; order?: { branch: string; unpushed: boolean }[];
};

// One ship verb, one outcome slot. The header button and the map's merged-ghost pill both POST
// /ship, so they share this signal — a pill that fired and dropped the answer read as a dead
// button while the server was refusing (an off-parent node, a conflicting rebase) in full detail.
const [shipMsg, setShipMsg] = createSignal<{ text: string; bad?: boolean } | null>(null);

async function runShip(project: string, qc: ReturnType<typeof useQueryClient>): Promise<ShipResult> {
  setShipMsg(null);
  const r: ShipResult = await fetch(withRepo("/ship"), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ project }),
  })
    .then((x) => x.json() as Promise<ShipResult>)
    .catch((e) => ({ ok: false, err: String(e) }));
  if (!r.ok) {
    setShipMsg({ text: `✗ ${r.err || "ship failed"}`, bad: true });
    return r;
  }
  const pushList = (r.order ?? []).filter((o) => o.unpushed).map((o) => leaf(o.branch));
  const did = [
    r.contracted?.length ? `${r.contracted.length} merged dropped` : "",
    r.moved?.length ? `${r.moved.length} rebased` : "",
  ].filter(Boolean).join(" · ");
  setShipMsg({
    text: (r.alreadyReady ? "✓ already ready" : `✓ ready — ${did}`)
      + (pushList.length ? ` · push: ${pushList.join(" → ")}` : " · nothing to push"),
  });
  qc.invalidateQueries({ queryKey: ["model"] });
  qc.invalidateQueries({ queryKey: ["forest-health"] });
  qc.invalidateQueries({ queryKey: ["projects"] });
  return r;
}

// What /ship would actually do here, off the daemon's ambient classification (shared cache with
// Home's chip). null = the daemon can't say — callers treat that as "assume there's work", so a
// verb never vanishes just because the classification is missing.
function useShipPlan(project: () => string) {
  const shipAmbient = createQuery(() => ({
    queryKey: ["restack-ambient"], queryFn: () => provider.restackAmbient(), refetchInterval: 15000,
  }));
  const shipForestBranches = createQuery(() => ({
    queryKey: ["forest-branches"], queryFn: () => provider.forestBranches(), refetchInterval: 60000,
  }));
  return () => {
    const a = shipAmbient.data;
    if (!a?.available || !a.report) return null;
    const inProj = new Set((shipForestBranches.data || []).filter((fb) => fb.project === project()).map((fb) => fb.branch));
    const b = a.report.branches.filter((x) => inProj.has(x.branch));
    return {
      contract: b.filter((x) => x.verdict === "would-contract").length,
      rebase: b.filter((x) => x.verdict === "would-restack").length,
      conflict: b.filter((x) => x.verdict === "will-conflict").length,
    };
  };
}

const shipHasWork = (plan: { contract: number; rebase: number; conflict: number } | null) =>
  !plan || plan.contract > 0 || plan.rebase > 0 || plan.conflict > 0;

// The forest's "get this ready to go" verb: POST /ship contracts already-merged members,
// restacks every survivor onto fresh origin/main (trees included), and reports the push
// order. Prep/push stay per-node so the outgoing commit message remains editable.
function ShipButton(props: { project: string }) {
  const qc = useQueryClient();
  const [armed, setArmed] = createSignal(false);
  const [busy, setBusy] = createSignal(false);
  let disarm: ReturnType<typeof setTimeout>;
  const shipPlan = useShipPlan(() => props.project);
  // the confirm step previews exactly what it'll do (drop merged ghosts, rebase the rest)
  // rather than firing blind.
  const preview = () => {
    const p = shipPlan();
    return p && (p.contract || p.rebase || p.conflict) ? p : null;
  };
  const confirmLabel = () => {
    const p = preview();
    if (!p) return "confirm: contract + restack";
    const parts = [p.contract && `drop ${p.contract}`, p.rebase && `rebase ${p.rebase}`].filter(Boolean);
    return `confirm: ${parts.join(" · ") || "restack"}`;
  };
  const fire = async () => {
    if (!armed()) {
      setArmed(true);
      clearTimeout(disarm);
      disarm = setTimeout(() => setArmed(false), 6000);
      return;
    }
    clearTimeout(disarm);
    setArmed(false);
    setBusy(true);
    await runShip(props.project, qc);
    setBusy(false);
  };
  return (
    <>
      <button
        class={`${FO_STAGE} ${armed() ? FO_STAGE_ARMED : FO_STAGE_QUIET}`}
        classList={{ armed: armed() }}
        disabled={busy()}
        title="ready to ship — drop any member that already merged (rewiring its children), restack the whole forest onto fresh origin/main, then list what to push in order. Refuses if a member has an open PR or a dirty worktree; a conflict restores everything."
        onClick={fire}
      >
        {busy() ? "readying…" : armed() ? confirmLabel() : "▸ ready"}
      </button>
      <Show when={armed() && (preview()?.conflict ?? 0) > 0}>
        <span class={`${FO_STAGE_MSG} bad text-del`} title="a conflicting rebase restores every branch to where it was — nothing is left half-done">
          ⚠ {preview()!.conflict} may conflict
        </span>
      </Show>
      <Show when={shipMsg()}>
        <span class={`${FO_STAGE_MSG} ${shipMsg()!.bad ? "text-del" : "text-ink-dim"}`} classList={{ bad: !!shipMsg()!.bad }}>{shipMsg()!.text}</span>
      </Show>
    </>
  );
}

export function ForestOverview() {
  const { location, navigate } = useViewerLocation();
  const project = () => forestKey(location());
  const ovQc = useQueryClient();
  const [ovView, setOvView] = [overviewView, setOverviewView]; // shared module signal so ⌘K can open straight into a view
  const model = createQuery(() => ({
    // repo in the key so loops/monotoad forests with the same name don't share a cache entry
    // and a cross-repo nav refetches; provider reads the repo from the URL at fetch time.
    queryKey: ["model", forestRepo(location()) ?? "loops", project()],
    queryFn: () => provider.model(project()),
    enabled: !!project(),
  }));
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
  const ovShipPlan = useShipPlan(project);
  const [chatPick, setChatPick] = createSignal(false);
  const editTicket = async () => {
    if (!canMutate) {
      return;
    }
    const cur = model.data?.ticket?.toUpperCase() ?? "";
    const v = window.prompt("Linear ticket for this forest (blank clears):", cur || "LOO-");
    if (v === null || v.trim().toUpperCase() === cur) {
      return;
    }
    const r = await fetch(withRepo("/ticket"), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ project: project(), ticket: v.trim() }),
    });
    if (r.ok) {
      ovQc.invalidateQueries({ queryKey: ["model"] });
    } else {
      const e = (await r.json().catch(() => null)) as { error?: string } | null;
      window.alert(e?.error ?? "ticket save failed");
    }
  };

  return (
    <div class="forest-overview min-h-screen bg-vellum-night">
      <header class="fo-head sticky top-0 z-[2] flex items-baseline gap-4 border-x-0 border-t-0 border-b border-solid border-rule bg-vellum-night px-6 py-4">
        <span class="fo-project font-display text-[21px] italic text-ink">{project()}</span>
        <Show when={(model.data?.interest ?? 0) > 0}>
          <span class="fo-interest text-[11px] tracking-[-1px] text-gold-leaf" title={`interest ${model.data!.interest} — promoted on the Forests home`}>
            {interestPips(model.data!.interest!)}
          </span>
        </Show>
        <Show when={canMutate || model.data?.ticket}>
          <button
            class="fo-ticket cursor-pointer rounded-[6px] border border-transparent bg-transparent px-[4px] py-[1px] font-mono text-[11px] text-ink-faint hover:border-rule hover:text-ink-dim"
            title={model.data?.ticket
              ? `Linear ${model.data.ticket.toUpperCase()} — commit scopes read type(${model.data.ticket}):; click to change`
              : "tie this forest to a Linear ticket — commit scopes become type(loo-####):"}
            onClick={editTicket}
          >
            {model.data?.ticket ?? "＋ ticket"}
          </button>
        </Show>
        <Show when={spine().length}>
          <span class="fo-meta text-[12px] tracking-[0.04em] text-ink-faint">{nodeCount()} {nodeCount() === 1 ? "node" : "nodes"}</span>
          <WarmingRibbon loading={health.isFetching} hasData={!!health.data} needsAttention={needsAttention()} />
          <div class="fo-views ml-auto inline-flex gap-[2px]" role="group" aria-label="overview view">
            <button class={`${FO_BTN} border ${ovView() === "map" ? FO_VIEW_ON : FO_VIEW_OFF}`} classList={{ on: ovView() === "map" }} onClick={() => setOvView("map")} title="spatial forest map">⊞ map</button>
            <button class={`fo-view-story ${FO_BTN} border ${ovView() === "story" ? FO_VIEW_ON : FO_VIEW_OFF}`} classList={{ on: ovView() === "story" }} onClick={() => setOvView("story")} title="the feature as ordered semantic commits">≣ story</button>
          </div>
          <Show when={canMutate}>
            <span class="sp-anchor relative inline-flex">
              <button
                class={`fo-chat ${FO_BTN} ml-[6px] border border-gold-deep bg-transparent text-ember hover:border-gold-leaf hover:text-gold-leaf`}
                title="chat about this whole forest — what it does end to end, where the gaps are, what's left"
                onClick={() => setChatPick((v) => !v)}
              >✦ chat</button>
              <Show when={chatPick()}>
                <SessionPicker
                  onClose={() => setChatPick(false)}
                  onPick={(session) => { setChatPick(false); chatToTmux({ project: project(), session }); }}
                />
              </Show>
            </span>
            <ShipButton project={project()} />
            <StageButton project={project()} />
          </Show>
        </Show>
      </header>
      <Show
        when={spine().length}
        fallback={<p class="loading fo-empty px-6 py-10 italic text-ink-faint">{model.isLoading ? "loading…" : "no branches in this forest"}</p>}
      >
        <Show
          when={ovView() === "story"}
          fallback={
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
              onContract={canMutate ? async (branch) => {
                const r = await fetch(withRepo("/contract"), {
                  method: "POST",
                  headers: { "Content-Type": "application/json" },
                  body: JSON.stringify({ branch }),
                });
                const body = (await r.json()) as { ok?: boolean; err?: string };
                ovQc.invalidateQueries({ queryKey: ["model"] });
                ovQc.invalidateQueries({ queryKey: ["forest-health"] });
                ovQc.invalidateQueries({ queryKey: ["projects"] });
                return { status: r.status, ...body };
              } : undefined}
              // a forest with nothing to ship gets no verb — the merged-with-follow-on node stays a
              // passive ghost instead of a "ready forest →" that fires and reports "already ready".
              onReady={canMutate && shipHasWork(ovShipPlan()) ? () => runShip(project(), ovQc) : undefined}
            />
          }
        >
          <MergeStory model={model.data} project={project()} onPick={open} />
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
