import { createSignal, createEffect, onCleanup, createMemo, Show } from "solid-js";
import { useQueryClient, createQuery } from "@tanstack/solid-query";
import { Link, useViewerLocation, forestKey, forestRepo, withNode } from "./router";
import { provider, canMutate, withRepo } from "./provider";
import { leaf, interestPips, flattenForest } from "./shared";
import { cameFrom } from "./cameFrom";
import { overviewView, setOverviewView } from "./overviewView";
import { ForestMap } from "./ForestMap";
import MergeStory from "./MergeStory";
import { chatToTmux } from "./chatDrawer";
import type { Purpose } from "./types";

// ── forest overview: the map as the landing hero (no node selected) ──────
// Picking a node navigates to /forests/<project>/<branch> — the per-node review surface.
const FO_VIEWS_CSS = `
.fo-views { display: inline-flex; gap: 2px; margin-left: auto; }
.fo-views button {
  font: inherit; font-size: 11px; cursor: pointer; padding: 3px 10px; border-radius: 6px;
  color: var(--ink-faint, #6f675a); background: transparent; border: 1px solid transparent;
}
.fo-views button:hover { color: var(--ink-dim, #a89e8c); }
.fo-views button.on { color: var(--gold, #e0ad4e); border-color: var(--rule, #3a332b); background: var(--raised, #1b1815); }
.fo-chat {
  font: inherit; font-size: 11px; cursor: pointer; padding: 3px 10px; border-radius: 6px; margin-left: 6px;
  color: var(--ember, #d2732a); background: transparent; border: 1px solid var(--gold-deep, #6e521d);
}
.fo-chat:hover { color: var(--gold-leaf, #e6b64e); border-color: var(--gold-leaf, #e6b64e); }
.fo-stage {
  font: inherit; font-size: 11px; cursor: pointer; padding: 3px 10px; border-radius: 6px; margin-left: 6px;
  color: var(--patina, #7fa093); background: transparent; border: 1px solid var(--rule, #3a332b);
}
.fo-stage:hover:not(:disabled) { color: var(--ink, #e8dcc4); border-color: var(--patina, #7fa093); }
.fo-stage:disabled { opacity: 0.5; cursor: default; }
.fo-stage.armed { color: var(--vellum-night, #14110a); background: var(--patina, #7fa093); border-color: var(--patina, #7fa093); }
.fo-stage-msg { font-size: 11px; margin-left: 6px; color: var(--ink-dim, #a89e8c); white-space: nowrap; }
.fo-stage-msg.bad { color: var(--del, #c87a55); }

/* Warming — the kiln heating before it can read the pieces (cold /forest-health, ~5s vs GitHub).
   Ember, never the blessed gold; a delay guard keeps it off sub-second warm-cache loads. */
.fo-warm { display: inline-flex; align-items: center; gap: 8px;
  font-size: 11px; letter-spacing: 0.05em; white-space: nowrap; }
.fo-warm.reading { color: var(--ember, #d2732a); }
.fo-warm.read { color: var(--ink-dim, #a89e8c); animation: fo-warm-fade 0.4s ease both; }
.fo-warm.refreshing { color: var(--ink-faint, #6f675a); }
.fo-warm b { font-weight: 500; color: var(--gold-leaf, #e6b64e); }         /* the count that earns a look */
.fo-warm .fo-coal {
  width: 7px; height: 7px; border-radius: 50%; flex: none;
  background: var(--ember, #d2732a); box-shadow: 0 0 8px var(--ember-wash, rgba(210,115,42,.12));
}
.fo-warm.reading .fo-coal { animation: fo-breathe 1.5s ease-in-out infinite; }
.fo-warm.read .fo-coal { background: var(--gold-leaf, #e6b64e); box-shadow: 0 0 8px var(--gold-wash, rgba(230,182,78,.08)); }
.fo-warm.refreshing .fo-coal { width: 5px; height: 5px; background: var(--ink-faint, #6f675a); box-shadow: none;
  animation: fo-breathe 1.9s ease-in-out infinite; }

@keyframes fo-breathe { 0%,100% { opacity: 0.35; } 50% { opacity: 1; } }
@keyframes fo-warm-fade { from { opacity: 0; transform: translateY(-2px); } to { opacity: 1; transform: none; } }
@media (prefers-reduced-motion: reduce) {
  .fo-warm .fo-coal { animation: none !important; }
  .fo-warm.reading .fo-coal { opacity: 1; }
}
@media (max-width: 600px) { .fo-warm { white-space: normal; } }
`;

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
        <span class={`fo-warm ${s()}`} aria-live="polite">
          <span class="fo-coal" />
          <Show when={s() === "reading"}>warming · reading branch health from GitHub</Show>
          <Show when={s() === "read"}>
            <Show when={attn() > 0} fallback={<>read · all clear</>}>
              read · <b>{attn()}</b> {attn() === 1 ? "needs" : "need"} attention
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
        class="fo-stage"
        classList={{ armed: armed() }}
        disabled={busy()}
        title="stage for testing — restack this chain onto fresh origin/main, then move your main checkout onto the tip so the dev server serves it. Refuses on a dirty checkout, an open PR in the chain, or anything but a single main-rooted line."
        onClick={fire}
      >
        {busy() ? "staging…" : armed() ? "confirm: move my checkout" : "⇪ stage"}
      </button>
      <Show when={msg()}>
        <span class="fo-stage-msg" classList={{ bad: !!msg()!.bad }}>{msg()!.text}</span>
      </Show>
    </>
  );
}

// The forest's "get this ready to go" verb: POST /ship contracts already-merged members,
// restacks every survivor onto fresh origin/main (trees included), and reports the push
// order. Prep/push stay per-node so the outgoing commit message remains editable.
function ShipButton(props: { project: string }) {
  const qc = useQueryClient();
  const [armed, setArmed] = createSignal(false);
  const [busy, setBusy] = createSignal(false);
  const [msg, setMsg] = createSignal<{ text: string; bad?: boolean } | null>(null);
  let disarm: ReturnType<typeof setTimeout>;
  // shared cache with Home's chip — the daemon already classified this forest, so the confirm
  // step previews exactly what it'll do (drop merged ghosts, rebase the rest) rather than firing blind.
  const shipAmbient = createQuery(() => ({
    queryKey: ["restack-ambient"], queryFn: () => provider.restackAmbient(), refetchInterval: 15000,
  }));
  const shipForestBranches = createQuery(() => ({
    queryKey: ["forest-branches"], queryFn: () => provider.forestBranches(), refetchInterval: 60000,
  }));
  const preview = () => {
    const a = shipAmbient.data;
    if (!a?.available || !a.report) return null;
    const inProj = new Set((shipForestBranches.data || []).filter((fb) => fb.project === props.project).map((fb) => fb.branch));
    const b = a.report.branches.filter((x) => inProj.has(x.branch));
    const contract = b.filter((x) => x.verdict === "would-contract").length;
    const rebase = b.filter((x) => x.verdict === "would-restack").length;
    const conflict = b.filter((x) => x.verdict === "will-conflict").length;
    return contract || rebase || conflict ? { contract, rebase, conflict } : null;
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
    setMsg(null);
    const r = await fetch(withRepo("/ship"), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ project: props.project }),
    })
      .then((x) => x.json() as Promise<{
        ok?: boolean; err?: string; alreadyReady?: boolean; moved?: string[];
        contracted?: { branch: string }[]; order?: { branch: string; unpushed: boolean }[];
      }>)
      .catch((e) => ({ ok: false, err: String(e) }));
    setBusy(false);
    if (r.ok) {
      const re = r as { alreadyReady?: boolean; moved?: string[]; contracted?: { branch: string }[]; order?: { branch: string; unpushed: boolean }[] };
      const pushList = (re.order ?? []).filter((o) => o.unpushed).map((o) => leaf(o.branch));
      const did = [
        re.contracted?.length ? `${re.contracted.length} merged dropped` : "",
        re.moved?.length ? `${re.moved.length} rebased` : "",
      ].filter(Boolean).join(" · ");
      setMsg({
        text: (re.alreadyReady ? "✓ already ready" : `✓ ready — ${did}`)
          + (pushList.length ? ` · push: ${pushList.join(" → ")}` : " · nothing to push"),
      });
      qc.invalidateQueries({ queryKey: ["model"] });
      qc.invalidateQueries({ queryKey: ["forest-health"] });
      qc.invalidateQueries({ queryKey: ["projects"] });
    } else {
      setMsg({ text: `✗ ${r.err || "ship failed"}`, bad: true });
    }
  };
  return (
    <>
      <button
        class="fo-stage"
        classList={{ armed: armed() }}
        disabled={busy()}
        title="ready to ship — drop any member that already merged (rewiring its children), restack the whole forest onto fresh origin/main, then list what to push in order. Refuses if a member has an open PR or a dirty worktree; a conflict restores everything."
        onClick={fire}
      >
        {busy() ? "readying…" : armed() ? confirmLabel() : "▸ ready"}
      </button>
      <Show when={armed() && (preview()?.conflict ?? 0) > 0}>
        <span class="fo-stage-msg bad" title="a conflicting rebase restores every branch to where it was — nothing is left half-done">
          ⚠ {preview()!.conflict} may conflict
        </span>
      </Show>
      <Show when={msg()}>
        <span class="fo-stage-msg" classList={{ bad: !!msg()!.bad }}>{msg()!.text}</span>
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
        (r) => r.json() as Promise<Record<string, { drifted: boolean; merged: boolean; contractable: boolean }>>,
      ),
    enabled: canMutate && healthIds().length > 0,
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

  // hover a node in the map → float its branch purpose (cached; guard the async gap so a
  // pointer that left before /purpose resolved doesn't pop a stale tip).
  const purposeCache = new Map<string, Purpose>();
  const [tip, setTip] = createSignal<{ text: string; x: number; y: number } | null>(null);
  let tipBranch: string | null = null;
  const showTip = async (branch: string, el: HTMLElement) => {
    tipBranch = branch;
    let p = purposeCache.get(branch);
    if (!p) {
      try { p = await provider.purpose(branch); }
      catch { p = { thesis: "" }; }
      purposeCache.set(branch, p);
    }
    if (tipBranch !== branch || !p.thesis) return;
    const r = el.getBoundingClientRect();
    setTip({ text: p.thesis, x: r.right + 12, y: r.top });
  };
  const hideTip = () => { tipBranch = null; setTip(null); };

  return (
    <div class="forest-overview">
      <header class="fo-head">
        <Link class="brand" to={{ kind: "home", tab: "forests" }}>
          <span class="brand-mark">✦</span> blessed
        </Link>
        <span class="fo-project">{project()}</span>
        <Show when={(model.data?.interest ?? 0) > 0}>
          <span class="fo-interest" title={`interest ${model.data!.interest} — promoted on the Forests home`}>
            {interestPips(model.data!.interest!)}
          </span>
        </Show>
        <Show when={spine().length}>
          <span class="fo-meta">{nodeCount()} {nodeCount() === 1 ? "node" : "nodes"}</span>
          <WarmingRibbon loading={health.isFetching} hasData={!!health.data} needsAttention={needsAttention()} />
          <div class="fo-views" role="group" aria-label="overview view">
            <button classList={{ on: ovView() === "map" }} onClick={() => setOvView("map")} title="spatial forest map">⊞ map</button>
            <button classList={{ on: ovView() === "story" }} onClick={() => setOvView("story")} title="the feature as ordered semantic commits">≣ story</button>
          </div>
          <Show when={canMutate}>
            <button
              class="fo-chat"
              title="chat about this whole forest — what it does end to end, where the gaps are, what's left"
              onClick={() => chatToTmux({ project: project() })}
            >✦ chat</button>
            <ShipButton project={project()} />
            <StageButton project={project()} />
          </Show>
        </Show>
        <style>{FO_VIEWS_CSS}</style>
      </header>
      <Show
        when={spine().length}
        fallback={<p class="loading fo-empty">{model.isLoading ? "loading…" : "no branches in this forest"}</p>}
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
                await fetch(withRepo("/contract"), {
                  method: "POST",
                  headers: { "Content-Type": "application/json" },
                  body: JSON.stringify({ branch }),
                }).then((r) => r.json());
                ovQc.invalidateQueries({ queryKey: ["model"] });
                ovQc.invalidateQueries({ queryKey: ["forest-health"] });
                ovQc.invalidateQueries({ queryKey: ["projects"] });
              } : undefined}
            />
          }
        >
          <MergeStory model={model.data} project={project()} onPick={open} />
        </Show>
      </Show>
      <Show when={tip()}>
        {(t) => (
          <div class="purpose-tip" style={{ left: `${t().x}px`, top: `${t().y}px` }}>
            {t().text}
          </div>
        )}
      </Show>
    </div>
  );
}
