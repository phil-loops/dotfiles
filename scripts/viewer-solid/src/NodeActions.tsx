// NodeActions — the branch-level "do something to this branch" affordances that live on
// the right of NodeDetail's node-head: a fork-state badge (behind / push-blocked) and a
// ⋯ menu collapsing the three rare, history-touching mutations — move the main checkout
// (~/coding/loops) onto this branch, squash parent..branch into one voiced commit, and
// rebase forward onto origin/main. Collapsing them into a menu keeps the header calm and
// adds a click of friction before anything rewrites history. All three are SECONDARY
// actions, so they wear --patina (stale/tarnished green), never gold — gold is reserved
// for blessed work. This component owns its wiring + state so it drops into App.tsx with a
// single mount line.
//
//   <NodeActions branch={active()} />
//
// Endpoints (Python review server, unchanged):
//   POST /checkout {branch, force?}  → {ok} | 409 {ok:false, worktree} when another
//                                       worktree holds the branch (force:true frees it)
//   POST /squash   {branch}          → {ok, n, base, unstaged}  (stack-squash --unstage:
//                                       collapse parent..branch to unstaged changes, no commit)
//   POST /sync     {branch}          → {ok, rebased?, ejected?, conflict?, summary?} | 409
//                                       (rebase forward: in place when clean, else eject Claude)
import { createSignal, For, Show, onCleanup } from "solid-js";
import { createMutation, createQuery, keepPreviousData, useQueryClient } from "@tanstack/solid-query";
import { provider, canMutate, withRepo } from "./provider";
import { useArm } from "./actions";
import RebaseStream from "./RebaseStream";
import { PlanStepsEditor } from "./PlanStepsEditor";
import NodeSpine, { type SpineEdge } from "./NodeSpine";
import { nextStepOf, stationOf, type Station } from "./nodeStation";

interface CheckoutResult {
  ok?: boolean;
  err?: string;
  worktree?: string; // set on 409: the worktree currently holding the branch
  freed?: string; // set on ok: a clean, session-less worktree the server auto-freed en route
  dirty?: number; // set on 409: uncommitted paths in the holding worktree
  session?: { pane?: string; idleSeconds?: number } | null; // set on 409: live Claude session in it
}

const shortWt = (p: string) => p.split("/").pop() || p;

const FIX = "cursor-pointer rounded-[5px] border border-del bg-transparent px-[9px] py-[3px] text-[12px] leading-[1.55] text-del opacity-90 enabled:hover:opacity-100 disabled:cursor-default disabled:opacity-50";
const PUSH_RED = "cursor-pointer rounded-[5px] border border-del px-[9px] py-[3px] text-[12px] font-semibold leading-[1.55] opacity-90 enabled:hover:opacity-100 disabled:cursor-default disabled:opacity-35";
const ITEM = "flex w-full cursor-pointer items-center gap-[10px] rounded-[6px] border border-transparent bg-transparent px-[10px] py-[7px] text-left text-[12px] leading-[1.55] text-patina enabled:hover:border-patina enabled:hover:bg-vellum-edge disabled:cursor-default disabled:opacity-45";
const IC = "w-[14px] flex-none text-center opacity-85";
const DONE = "text-[12px] transition-opacity duration-[240ms] ease-[ease] starting:opacity-0";
const EDITOR_CLOSE = "cursor-pointer text-[11px] leading-[1.55] text-ink-faint";

function holdReason(r: CheckoutResult): string {
  const parts: string[] = [];
  if (r.session) {
    parts.push(`⚠ live Claude session${r.session.idleSeconds != null ? ` (idle ${r.session.idleSeconds}s)` : ""}`);
  }
  if (r.dirty) {
    parts.push(`± ${r.dirty} uncommitted`);
  }
  return parts.join(" · ");
}

interface SyncResult {
  ok?: boolean;
  err?: string;
  rebased?: boolean; // clean forward-rebase landed in place
  ejected?: boolean; // couldn't rebase in place → handed to a headless claude, streamed
  stream?: string; // the rebase job key to tail over /rebase-stream (set with ejected)
  conflict?: boolean; // hit a conflict → Claude resolving in a worktree
  contract?: boolean; // branch already merged into origin/main → drop & rewire instead
  restack?: boolean; // stacked chain behind main → the restack machine owns this rebase
  project?: string; // the project to hand to POST /restack (set with restack)
}

interface DeltaTestResult {
  ok?: boolean; // exit 0 (or no related tests)
  ran?: boolean; // tsx actually executed a test summary
  noTests?: boolean; // no changed file had a co-located test
  passed?: number;
  failed?: number;
  total?: number;
  summary?: string; // tail of the runner output (for the tooltip)
}

async function post<T>(url: string, body: unknown): Promise<T> {
  // prefix the active repo (/monotoad/checkout) so the server pins the right repo — without it
  // every node action (checkout/squash/rebase/contract/…) runs against the launched repo (loops).
  const r = await fetch(withRepo(url), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  // /checkout & /squash send a JSON body on success AND on handled failure (409 held
  // elsewhere, 500 git error) — parse it either way so onSuccess can branch on r.ok.
  // A non-JSON body (server down / restarting, proxy 502, crash before the JSON path)
  // throws here instead of failing silently — the mutations' onError surfaces it.
  const text = await r.text();
  try {
    return JSON.parse(text) as T;
  } catch {
    throw new Error(`HTTP ${r.status}${text ? ": " + text.slice(0, 200) : " (empty response)"}`);
  }
}

export function NodeActions(props: {
  branch: string;
  isReview: boolean;
  merged?: boolean; // forest-health flagged this branch a merged ghost → offer contraction on load
  blessing?: { total: number; blessed: number }; // the node's review progress — the spine's review station + gold mark
  // the old header health badges, folded into the spine's reasons + ⋯ overrides
  health?: {
    drifted?: boolean; contractable?: boolean; parent?: string;
    upstreamBad?: boolean; upstreamReason?: string; upstream?: string;
    diverged?: boolean; ahead?: number; behind?: number;
  } | null;
  onReseat?: () => void; // rebase drifted children back onto the parent's tip (App owns the mutation)
  onDetach?: () => void; // unset a footgun tracking ref
  onInspect?: () => void; // toggle the diverged-inspect panel (lives in App below the header)
  ambient?: { verdict?: string; behind?: number | null; conflict_pr?: number | null; conflict_title?: string | null } | null;
  interest?: number; // the forest's Home-ordering interest — drives the ⋯ promote/demote items
  onBump?: (delta: number) => void;
  onAllChats?: () => void;
}) {
  if (!canMutate) return null; // static snapshot: no rebase/checkout/squash actions
  const qc = useQueryClient();
  // 409 stash: the worktree holding the branch, awaiting a force-confirm — plus which action
  // hit it, so freeing the worktree resumes the right one (plain checkout vs the omni sync).
  const [heldAt, setHeldAt] = createSignal<string | null>(null);
  const [heldFor, setHeldFor] = createSignal<"checkout" | "omniSync">("checkout");
  // why the server refused to auto-free it — a clean, session-less hold never gets here
  // (the server frees those itself); this names the dirt or the live session instead.
  const [heldWhy, setHeldWhy] = createSignal<string>("");
  // squashing rewrites history → two-click arm (shared useArm) before it fires.
  const { armed, trigger } = useArm(4000);
  // transient result line ("✓ …" / "✗ …"), cleared on the next action.
  const [done, setDone] = createSignal<string | null>(null);
  // raises the result line to the ember alert style — a rebase conflict parks a worktree and
  // blocks restacks, so it can't read as a quiet ✓ success like every other outcome.
  const [doneAlert, setDoneAlert] = createSignal(false);
  // /sync found the branch already merged into main — children awaiting a drop+rewire confirm.
  const [contractKids, setContractKids] = createSignal<string[] | null>(null);
  // an eject to a headless rebase is live → tail its output stream inline (RebaseStream) instead
  // of the old frozen "rebasing onto origin/main via Claude" line that couldn't show liveness.
  const [rebaseStreaming, setRebaseStreaming] = createSignal(false);
  // the ⋯ menu open/closed
  const [open, setOpen] = createSignal(false);
  let root: HTMLDivElement | undefined;

  // close the menu on outside click / Escape so it never lingers over the diff.
  const onDocDown = (e: MouseEvent) => {
    if (root && !root.contains(e.target as Node)) setOpen(false);
  };
  const onKey = (e: KeyboardEvent) => {
    if (e.key === "Escape") setOpen(false);
  };
  document.addEventListener("mousedown", onDocDown);
  document.addEventListener("keydown", onKey);
  onCleanup(() => {
    document.removeEventListener("mousedown", onDocDown);
    document.removeEventListener("keydown", onKey);
  });

  const checkout = createMutation(() => ({
    mutationFn: (force: boolean) =>
      post<CheckoutResult>("/checkout", { branch: props.branch, force }),
    onSuccess: (r) => {
      if (r.ok) {
        setHeldAt(null);
        setOpen(false);
        setDone(`✓ checked out in ${r.worktree || "your main checkout"}${r.freed ? ` (freed ${shortWt(r.freed)} — clean, no live session)` : ""}`);
        qc.invalidateQueries({ queryKey: ["head"] });
      } else if (r.worktree) {
        setHeldFor("checkout");
        setHeldWhy(holdReason(r));
        setHeldAt(r.worktree); // held elsewhere → offer to free it
      } else {
        setDone(`✗ ${r.err || "checkout failed"}`);
      }
    },
    onError: (e) => setDone(`✗ ${(e as Error).message || "checkout failed"}`),
  }));

  // ▷ preview — spin a side-port `next dev` for this branch (loops-preview) and open it. Never
  // moves the main checkout off :3000; the Activity dock lists + kills the running ones.
  const devServer = createMutation(() => ({
    mutationFn: () => post<{ ok: boolean; url?: string; err?: string }>("/preview", { branch: props.branch }),
    onSuccess: (r) => {
      setOpen(false);
      if (r.ok && r.url) {
        window.open(r.url, "_blank");
        setDone(`✓ preview → ${r.url.replace("http://", "")}`);
        qc.invalidateQueries({ queryKey: ["processes"] });
      } else {
        setDone(`✗ ${r.err || "preview failed"}`);
        setDoneAlert(true);
      }
    },
    onError: (e) => { setDone(`✗ ${(e as Error).message || "preview failed"}`); setDoneAlert(true); },
  }));

  // prep to merge — the one-motion merge prep, run as a staged pipeline:
  //   1. up-to-date  → rebase onto fresh origin/main (only if behind; conflict ejects to Claude)
  //   2. checkout    → move the main checkout onto this branch so GitHub Desktop follows
  //   3. squash      → collapse the whole branch into one voiced commit + oxfmt (base-clamped)
  //   4. delta-tests → run the tests related to the diff (warn, never block)
  // You review + push from GitHub Desktop, where the pre-push hook runs the gates. Each stage
  // narrates via done(); a stale main, a held worktree, or a conflict stops early with the reason.
  // ── ⟲ sync — the omni local motion (Phil, 2026-07-05): "whatever we do here locally is
  // fine." One button that makes this branch RIGHT and YOURS: reseat if drifted → rebase
  // forward if behind (streams on eject) → checkout here → route to one outgoing commit
  // (additive for a diverged PR, squash for a messy tail) → advisory tests + the push
  // gates (detached — their green is what unlocks the red button) → the message editor.
  // When a step isn't mechanically routable, Claude goes in the middle (reconcile
  // eject). NOTHING here touches origin — the shared world moves only via the red button.
  //
  // The motion narrates as a STEP STRIP (the wards pattern — dirty-sync incident): every
  // step visible, the failing one carrying its reason IN FULL, never truncated.
  type SyncStep = { id: string; label: string; state: "idle" | "run" | "ok" | "skip" | "fail"; note?: string; startedAt?: number };
  const [syncSteps, setSyncSteps] = createSignal<SyncStep[] | null>(null);
  const [dirtGate, setDirtGate] = createSignal(false);      // paused on the dirt decision
  const [stashedRun, setStashedRun] = createSignal(false);  // a sync-stash to pop when the motion ends
  // 1s heartbeat for the running-step elapsed counters — only strip rows that render a
  // counter subscribe, so an idle header pays nothing for it.
  const [nowTick, setNowTick] = createSignal(Date.now());
  const tickTimer = setInterval(() => setNowTick(Date.now()), 1000);
  onCleanup(() => clearInterval(tickTimer));
  const stepSet = (id: string, state: SyncStep["state"], note?: string) =>
    setSyncSteps((s) => (s ?? []).map((x) => (x.id === id
      ? { ...x, state, note: note ?? x.note, startedAt: state === "run" ? (x.startedAt ?? Date.now()) : x.startedAt }
      : x)));
  const beginSteps = () => {
    const steps: SyncStep[] = [{ id: "dirt", label: "working tree", state: "idle" }];
    if (props.health?.drifted) {
      steps.push({ id: "reseat", label: "reseat", state: "idle" });
    }
    if (behind() > 0 && (sync.data?.syncable || sync.data?.restack)) {
      steps.push({
        id: "rebase",
        label: sync.data?.restack ? "restack onto origin/main" : "rebase forward",
        state: "idle",
      });
    }
    steps.push(
      { id: "checkout", label: "checkout", state: "idle" },
      { id: "route", label: "one commit", state: "idle" },
      { id: "tests", label: "tests", state: "idle" },
      { id: "gates", label: "push gates", state: "idle" },
      { id: "editor", label: "editor", state: "idle" },
    );
    setSyncSteps(steps);
  };
  // The push gates (repo-configured stack-gates: typecheck + format in loops) are what the
  // red button's `gates` ward reads — green is recorded server-side keyed to the tip sha,
  // so this run is what unlocks push. It's tsc-length, so it runs DETACHED: the motion and
  // the editor never wait on it; the strip updates when it lands. A run token keeps a stale
  // finish from writing into a newer strip; the server answers from cache when this tip
  // already passed, so re-syncs are instant. fix:false — a gate auto-fix that commits or
  // rebases would move the tip out from under the commit the route step just sealed.
  let gatesRun = 0;
  type GatesVerdict = { ok?: boolean; cached?: boolean; started?: boolean; note?: string; gates?: { name: string; ok: boolean; summary?: string }[] };
  type GateEvent = { event: string; gate?: string; ok?: boolean; ts?: number; gates?: string[] };
  const runPushGates = () => {
    const token = ++gatesRun;
    stepSet("gates", "run", "starting — push unlocks when green");
    const finalize = (g: GatesVerdict) => {
      const parts = (g.gates ?? []).map((x) => `${x.name} ${x.ok ? "✓" : "✗"}`).join(" · ");
      const fails = (g.gates ?? []).filter((x) => !x.ok && x.summary).map((x) => x.summary!.trim()).join("\n");
      stepSet(
        "gates",
        g.ok ? "ok" : "fail",
        g.ok
          ? `${g.cached ? "already green for this commit" : parts || "green"} — push unlocked`
          : `${parts} (advisory — the motion continues; push stays locked)${fails ? ":\n" + fails : ""}`,
      );
      preview.refetch();
    };
    // per-gate position from the run's progress journal: done gates carry their verdict,
    // the running one its live seconds, the rest wait as dots.
    const progressLine = (events: GateEvent[]): string => {
      const plan = events.find((e) => e.event === "plan")?.gates ?? [];
      const done = new Map(events.filter((e) => e.event === "done").map((e) => [e.gate, e.ok]));
      const started = new Map(events.filter((e) => e.event === "start").map((e) => [e.gate, e.ts]));
      const line = plan.map((g) => {
        if (done.has(g)) return `${g} ${done.get(g) ? "✓" : "✗"}`;
        const ts = started.get(g);
        return ts ? `${g} ⟳ ${Math.max(0, Math.floor(Date.now() / 1000 - ts))}s` : `${g} ·`;
      }).join(" · ");
      return `${line || "running"} — push unlocks when green`;
    };
    const poll = () => setTimeout(async () => {
      if (token !== gatesRun) return;
      try {
        const p = await fetch(withRepo("/gates-progress") + "?branch=" + encodeURIComponent(props.branch))
          .then((r) => r.json() as Promise<{ running?: boolean; dead?: boolean; result?: GatesVerdict; events?: GateEvent[] }>);
        if (token !== gatesRun) return;
        if (p.result) return finalize(p.result);
        if (p.dead) return stepSet("gates", "fail", "gates run died without a verdict — push stays locked");
        stepSet("gates", "run", progressLine(p.events ?? []));
        poll();
      } catch {
        poll(); // transient poll failure (server bounce) — keep tailing; the token bounds it
      }
    }, 1500);
    post<GatesVerdict>("/gates", { branch: props.branch, fix: false, useCache: true, detach: true })
      .then((g) => {
        if (token !== gatesRun) return;
        if (g.started) return void poll();
        finalize(g); // cached green answers inline; an older server ran the gates synchronously
      })
      .catch((e) => {
        if (token !== gatesRun) return;
        stepSet("gates", "fail", `${(e as Error).message || "gates crashed"} — push stays locked`);
      });
  };
  const omniSync = createMutation(() => ({
    mutationFn: async (force: boolean) => {
      if (!syncSteps()) {
        beginSteps();
      }
      stepSet("dirt", "ok", stashedRun() ? "stashed for the run" : undefined);
      if (props.health?.drifted && props.health.parent) {
        stepSet("reseat", "run");
        await post("/reseat-children", { branch: props.health.parent });
        stepSet("reseat", "ok");
      }
      if (behind() > 0 && (sync.data?.syncable || sync.data?.restack)) {
        stepSet("rebase", "run");
        const sy = await post<SyncResult>("/sync", { branch: props.branch });
        if (sy.ok && sy.restack) {
          const rs = await post<{ ok?: boolean; err?: string }>("/restack", { project: sy.project });
          if (rs.ok) {
            stepSet("rebase", "run", `restacking ${sy.project} in the background — rerun sync once it lands`);
            return { phase: "restacking" as const };
          }
          stepSet("rebase", "fail", rs.err || "restack refused");
          return { phase: "blocked" as const };
        }
        if (sy.ok && sy.contract) {
          stepSet("rebase", "fail", "already merged into origin/main — drop & rewire (the spine's edge offers it)");
          return { phase: "blocked" as const };
        }
        if (sy.ok && !sy.rebased) {
          stepSet("rebase", "run", "conflict — resolving in a headless rebase, streaming below; the motion continues on its own once it lands");
          return { phase: "streaming" as const };
        }
        stepSet("rebase", sy.ok ? "ok" : "skip", sy.ok ? undefined : `refused (${sy.err || "stacked / open PR"}) — routing handles it`);
      }
      stepSet("checkout", "run");
      const co = await post<CheckoutResult>("/checkout", { branch: props.branch, force });
      if (!co.ok) {
        if (co.worktree) {
          setHeldWhy(holdReason(co));
          stepSet("checkout", "fail", `held by ${co.worktree}${holdReason(co) ? ` (${holdReason(co)})` : ""} — free it below to continue`);
          return { phase: "held" as const, held: co.worktree };
        }
        stepSet("checkout", "fail", co.err || "checkout failed");
        return { phase: "error" as const };
      }
      stepSet("checkout", "ok", co.freed ? `freed ${shortWt(co.freed)} — clean, no live session` : undefined);
      stepSet("route", "run");
      const pr = await post<{ ok?: boolean; err?: string; reconcile?: boolean; routed?: string[]; commit?: { sha: string; subject: string; body: string } | null }>(
        "/prep-push", { branch: props.branch });
      if (!pr.ok) {
        if (pr.reconcile) {
          stepSet("route", "fail", pr.err || "no mechanical route — handing to Claude");
          return { phase: "claude" as const };
        }
        if ((pr.err ?? "").startsWith("nothing to push")) {
          stepSet("route", "ok", "nothing to push — origin already has this");
          stepSet("tests", "skip");
          stepSet("gates", "skip");
          stepSet("editor", "skip", "no outgoing commit");
          return { phase: "done" as const, routed: ["nothing to push — origin already has this"], commit: null };
        }
        stepSet("route", "fail", pr.err || "prep failed");
        return { phase: "error" as const };
      }
      stepSet("route", "ok", (pr.routed ?? []).join(" · ") || undefined);
      runPushGates(); // detached — the editor opens without waiting on a typecheck
      stepSet("tests", "run");
      let tests: DeltaTestResult | null = null;
      try {
        tests = await post<DeltaTestResult>("/delta-tests", { branch: props.branch });
      } catch {
        tests = null; // tests are advisory — a runner crash never blocks a local sync
      }
      stepSet(
        "tests",
        tests && tests.ran && !tests.ok ? "fail" : "ok",
        tests
          ? tests.noTests
            ? "no changed tests"
            : tests.ran
              ? tests.ok ? `${tests.passed ?? "?"} ✓` : `${tests.failed ?? "?"} FAILED (advisory — the motion continues):\n${tests.summary ?? ""}`
              : "couldn't run"
          : "couldn't run",
      );
      return { phase: "done" as const, routed: pr.routed ?? [], commit: pr.commit ?? null, tests };
    },
    onSuccess: (r) => {
      setOpen(false);
      if (r.phase === "held") {
        setHeldFor("omniSync");
        setHeldAt(r.held);
        return;
      }
      if (r.phase === "blocked" || r.phase === "error") {
        // the failing step carries its full reason in the strip — nothing more to say here
        sync.refetch();
        qc.invalidateQueries({ queryKey: ["head"] });
        return;
      }
      if (r.phase === "streaming") {
        setRebaseStreaming(true); // the rebase is running headless — tail it inline below
        sync.refetch();
        return;
      }
      if (r.phase === "restacking") {
        // the restack machine has the walk (journal, parking, resolve) — the strip's note
        // says to rerun sync once it lands; nothing to tail here.
        sync.refetch();
        qc.invalidateQueries({ queryKey: ["head"] });
        return;
      }
      if (r.phase === "claude") {
        reconcile.mutate(); // divergence with no mechanical route — Claude in the middle
        return;
      }
      setHeldAt(null);
      if (r.commit) {
        setRoutedNotes(r.routed ?? []);
        setMsgSubject(r.commit.subject);
        setMsgBody(r.commit.body);
        setEditorOpen(true);
        stepSet("editor", "ok");
      }
      if (stashedRun()) {
        // the dirt decision was stash-and-continue — bring it back now that the motion is done
        post<{ ok?: boolean; err?: string }>("/dirty-resolve", { branch: props.branch, action: "pop" }).then((p) => {
          stepSet("dirt", p.ok ? "ok" : "fail", p.ok ? "stash popped — your uncommitted changes are back" : `stash pop failed (still stashed):\n${p.err}`);
          setStashedRun(false);
          sync.refetch();
        });
      }
      qc.invalidateQueries({ queryKey: ["head"] });
      qc.invalidateQueries({ queryKey: ["commits", props.branch] });
      qc.invalidateQueries({ queryKey: ["node", props.branch] });
      qc.invalidateQueries({ queryKey: ["model"] });
      qc.invalidateQueries({ queryKey: ["restack-ambient"] });
      sync.refetch();
      preview.refetch();
    },
    onError: (e) => {
      // a transport-level failure still lands in the strip, in full — never a truncated one-liner
      setSyncSteps((s) => (s ?? []).map((x) => (x.state === "run" ? { ...x, state: "fail" as const, note: (e as Error).message || "sync failed" } : x)));
      // the request died mid-motion (server bounce) — re-derive from live state so the panel
      // can't pin a stale holder or verdict (the soft-lock incident, 2026-07-06)
      sync.refetch();
      qc.invalidateQueries({ queryKey: ["head"] });
      qc.invalidateQueries({ queryKey: ["node", props.branch] });
    },
  }));

  // the sync entry point: dirt is a ROUTED DECISION, not a dead end — a dirty holding
  // worktree pauses the motion at step one with the files listed and three explicit
  // choices. Nothing automatic: the incident file was foreign WIP on the wrong branch.
  const startSync = () => {
    setSyncSteps(null);
    setHeldAt(null); // a held banner from an earlier run names a holder that may have moved
    setStashedRun(false);
    if ((sync.data?.dirty?.length ?? 0) > 0) {
      beginSteps();
      stepSet("dirt", "fail", `uncommitted changes in ${sync.data?.dirtyWorktree || "the holding worktree"} — decide below; the motion waits`);
      setDirtGate(true);
      return;
    }
    omniSync.mutate(false);
  };
  const dirtDecide = async (action: "include" | "stash" | "abort") => {
    setDirtGate(false);
    if (action === "abort") {
      stepSet("dirt", "fail", "aborted — working tree untouched");
      return;
    }
    const r = await post<{ ok?: boolean; err?: string }>("/dirty-resolve", { branch: props.branch, action });
    if (!r.ok) {
      stepSet("dirt", "fail", r.err || `${action} failed`);
      setDirtGate(true);
      return;
    }
    if (action === "stash") {
      setStashedRun(true);
    }
    sync.refetch();
    omniSync.mutate(false);
  };

  // free the worktree that 409'd, then resume whichever action hit it.
  const freeAndContinue = () => {
    setOpen(false);
    if (heldFor() === "omniSync") {
      omniSync.mutate(true);
    } else {
      checkout.mutate(true);
    }
  };

  // fork-state vs origin/main — read-only, drives the "behind / push blocked" badge.
  const sync = createQuery(() => ({
    queryKey: ["sync", props.branch],
    queryFn: () => provider.sync(props.branch),
    enabled: !!props.branch,
    placeholderData: keepPreviousData,
  }));
  const behind = () => sync.data?.behind ?? 0;
  const critical = () => sync.data?.deployCritical ?? [];
  const blocked = () => critical().length > 0;
  const shared = () => sync.data?.shared;
  const aheadOfOrigin = () => sync.data?.aheadOfOrigin ?? 0;
  // ambient daemon's dry-run verdict for this branch — folded into the one restack button so a
  // predicted collision warns before you click, instead of living as its own duplicate badge.
  const willConflict = () => props.ambient?.verdict === "will-conflict";

  // Confirm of the already-merged offer above: drop the empty branch and rewire its children
  // onto main (forest contraction). Destructive + Phil-driven — never auto-fired by /sync.
  const contract = createMutation(() => ({
    mutationFn: () =>
      post<{ ok?: boolean; err?: string; summary?: string }>("/contract", { branch: props.branch }),
    onSuccess: (r) => {
      if (!r.ok) {
        setDone(`✗ ${r.err || "contract failed"}`);
        return;
      }
      setContractKids(null);
      setDone(`✓ ${r.summary || "contracted"}`);
      qc.invalidateQueries({ queryKey: ["model"] });
      qc.invalidateQueries({ queryKey: ["node", props.branch] });
      qc.invalidateQueries({ queryKey: ["forest-health"] });
      qc.invalidateQueries({ queryKey: ["restack-ambient"] });
    },
    onError: (e) => setDone(`✗ ${(e as Error).message || "contract failed"}`),
  }));

  // A review/pr-<N> node tracks someone else's PR. When they force-push, re-fetch their new
  // head into the local branch. Blessings are keyed by file content, not the tip SHA, so they
  // survive: unchanged files stay blessed, changed files fall to stale for re-review.
  const isReview = () => props.isReview;
  // node-load hint: ls-remote the PR head and compare to our tip, so we can surface "they
  // pushed" the moment you open a stale review node — no blind clicking.
  const remote = createQuery(() => ({
    queryKey: ["review-remote", props.branch],
    queryFn: () => provider.reviewRemote(props.branch),
    enabled: isReview(),
    staleTime: 20_000,
  }));
  const pull = createMutation(() => ({
    mutationFn: () =>
      post<{ ok?: boolean; err?: string; changed?: boolean; after?: string }>("/review-pull", {
        branch: props.branch,
      }),
    onSuccess: (r) => {
      if (!r.ok) {
        setDone(`✗ ${r.err || "pull failed"}`);
        return;
      }
      setDone(r.changed ? `✓ pulled to ${r.after} — re-review the files now marked stale` : "✓ already at their state");
      qc.invalidateQueries({ queryKey: ["node", props.branch] });
      qc.invalidateQueries({ queryKey: ["commits", props.branch] });
      qc.invalidateQueries({ queryKey: ["model"] });
      qc.invalidateQueries({ queryKey: ["review-remote", props.branch] });
      sync.refetch();
    },
    onError: (e) => setDone(`✗ ${(e as Error).message || "pull failed"}`),
  }));

  // ── the editor — where every sync lands: the one outgoing commit, editable pre-push ──
  const [editorOpen, setEditorOpen] = createSignal(false);
  const [msgSubject, setMsgSubject] = createSignal("");
  const [msgBody, setMsgBody] = createSignal("");
  const [routedNotes, setRoutedNotes] = createSignal<string[]>([]);
  const refreshAfterPrep = () => {
    qc.invalidateQueries({ queryKey: ["node", props.branch] });
    qc.invalidateQueries({ queryKey: ["commits", props.branch] });
    qc.invalidateQueries({ queryKey: ["model"] });
    sync.refetch();
    preview.refetch();
  };
  const saveMsg = createMutation(() => ({
    mutationFn: () =>
      post<{ ok?: boolean; err?: string }>("/prep-message", {
        branch: props.branch, subject: msgSubject(), body: msgBody(),
      }),
    onSuccess: (r) => {
      if (!r.ok) {
        setDone(`✗ ${r.err || "couldn't save the message"}`);
        return;
      }
      setDone("✓ message saved");
      setEditorOpen(false);
      refreshAfterPrep();
    },
    onError: (e) => setDone(`✗ ${(e as Error).message || "couldn't save the message"}`),
  }));

  // the opt-in claude pass — prep commits with a mechanical message so it never waits
  // on a model; this button is the only thing that asks claude to voice it
  const draftMsg = createMutation(() => ({
    mutationFn: () =>
      post<{ ok?: boolean; err?: string; subject?: string; body?: string }>("/draft-message", {
        branch: props.branch,
      }),
    onSuccess: (r) => {
      if (!r.ok || !r.subject) {
        setDone(`✗ ${r.err || "couldn't draft the message"}`);
        return;
      }
      setMsgSubject(r.subject);
      setMsgBody(r.body ?? "");
    },
    onError: (e) => setDone(`✗ ${(e as Error).message || "couldn't draft the message"}`),
  }));

  // recompute this branch's forest-plan block from stack config and fold it into the body,
  // replacing any stale plan already there. Free — no model call, just where-it-fits facts.
  const planFill = createMutation(() => ({
    mutationFn: () =>
      fetch(withRepo("/plan-section") + "?branch=" + encodeURIComponent(props.branch)).then((r) =>
        r.text(),
      ),
    onSuccess: (section) => {
      const s = section.trim();
      if (!s) {
        setDone("✗ no plan — this branch isn't in a project");
        return;
      }
      const lines = msgBody().split("\n");
      const cut = lines.findIndex((l) => l.startsWith("Part of "));
      const prose = (cut === -1 ? msgBody() : lines.slice(0, cut).join("\n")).replace(/\s+$/, "");
      setMsgBody(prose ? `${prose}\n\n${s}` : s);
    },
    onError: (e) => setDone(`✗ ${(e as Error).message || "couldn't recompute the plan"}`),
  }));

  // what prep WOULD do — the read-only routed verdict, so the button teaches before it acts
  const prepRoute = createQuery(() => ({
    queryKey: ["prep-route", props.branch],
    queryFn: () =>
      fetch(withRepo("/prep-route") + "?branch=" + encodeURIComponent(props.branch)).then(
        (r) => r.json() as Promise<{ route?: string; why?: string; needsBody?: boolean }>,
      ),
    enabled: !!props.branch && !props.isReview,
  }));

  // push: the Phase-1 wards, mirrored from the /push card — server recomputes them all
  // at push time; this button only arms when the read-only verdict is green.
  const preview = createQuery(() => ({
    queryKey: ["push-preview", props.branch],
    queryFn: () =>
      fetch(withRepo("/push-preview") + "?branch=" + encodeURIComponent(props.branch)).then(
        (r) => r.json() as Promise<{ ok?: boolean; outgoing?: number; reasons?: string[]; web?: string; originExists?: boolean; published?: boolean; commit?: { sha: string; subject: string; body: string } | null }>,
      ),
    enabled: !!props.branch && !props.isReview,
  }));
  const [pushedWeb, setPushedWeb] = createSignal<string | null>(null);
  const pushOrigin = createMutation(() => ({
    mutationFn: () =>
      post<{ ok?: boolean; err?: string; web?: string; opened?: boolean }>("/push-origin", { branch: props.branch }),
    onSuccess: (r) => {
      refreshAfterPrep();
      if (!r.ok) {
        setDone(`✗ ${r.err || "push refused"}`);
        return;
      }
      // The server opens the target in the local browser on success (the open PR if one
      // exists, else the compare-and-create form); the link below is the fallback
      // (mobile, or a headless host with no `open`).
      const isPr = (r.web ?? "").includes("/pull/");
      setDone(
        r.opened
          ? isPr
            ? "✓ pushed — opening the open PR"
            : "✓ pushed — opening the compare view to author the PR"
          : "✓ pushed — origin has it",
      );
      setPushedWeb(r.web ?? null);
    },
    onError: (e) => setDone(`✗ ${(e as Error).message || "push failed"}`),
  }));

  // outgoing==0 but the branch is up-to-date on origin: no push to make, so open the PR page
  // directly — the open PR if one exists (view), else the compare-and-create form (author).
  // The push-less exit from the dead-push-button trap; opens a browser tab, never gh pr create.
  const openPr = createMutation(() => ({
    mutationFn: () =>
      post<{ ok?: boolean; web?: string; opened?: boolean; hadPr?: boolean }>("/open-pr", { branch: props.branch }),
    onSuccess: (r) => {
      if (!r.ok) {
        setDone("✗ no origin remote to open");
        return;
      }
      setDone(r.opened ? (r.hadPr ? "✓ opening the open PR" : "✓ opening the compare view to author the PR") : "✓ PR page ready");
      setPushedWeb(r.web ?? null);
    },
    onError: (e) => setDone(`✗ ${(e as Error).message || "couldn’t open"}`),
  }));

  // reconcile — the ⋯ override for a divergence prep can't route (no PR, or you want
  // Claude to work out the source of truth in a worktree). No force-push, no blind pull.
  const reconcile = createMutation(() => ({
    mutationFn: () => post<{ ok?: boolean; err?: string }>("/reconcile", { branch: props.branch }),
    onSuccess: (r) => {
      setOpen(false);
      setDone(r.ok ? "✦ Claude is reconciling in a worktree — watch the chat" : `✗ ${r.err || "reconcile refused"}`);
    },
    onError: (e) => setDone(`✗ ${(e as Error).message || "reconcile failed"}`),
  }));

  const busy = () => checkout.isPending || omniSync.isPending || pull.isPending || contract.isPending || pushOrigin.isPending;

  // ── the waymark spine: one chip (station), one slot (edge) ──────────────────
  // Station = where the branch stands on its real path — the DOMINANT position, not a
  // gate: a branch can sit at "review" with shaping left; the slot still offers prep.
  const blessedAll = () => !!props.blessing && props.blessing.total > 0 && props.blessing.blessed === props.blessing.total;
  const station = (): Station =>
    stationOf({
      merged: props.merged,
      gone: shared() === "gone",
      nothingOutgoing: prepRoute.data?.route === "nothing",
      ready: prepRoute.data?.route === "ready",
      blessed: props.blessing?.blessed,
      total: props.blessing?.total,
    });
  // Reasons live in the tooltip — why the branch sits at this station. What used to be
  // four separate header chips (shared / blocked / behind / diverged) is this one string.
  const reasons = () => {
    const parts: string[] = [];
    if (shared() === "local") {
      parts.push("local only — never pushed; the team cannot see this branch");
    } else if (shared() === "ahead") {
      parts.push(`origin is ${aheadOfOrigin()} commit${aheadOfOrigin() === 1 ? "" : "s"} behind your local`);
    } else if (shared() === "synced") {
      parts.push("in sync with origin — the team sees exactly this");
    }
    if (blocked()) {
      parts.push(`⚠ push blocked — origin/main changed deploy-critical files this branch lacks:\n${critical().join("\n")}`);
    }
    if (props.blessing && props.blessing.blessed < props.blessing.total) {
      parts.push(`${props.blessing.blessed}/${props.blessing.total} files blessed`);
    }
    if (prepRoute.data?.why) {
      parts.push(prepRoute.data.why);
    }
    const h = props.health;
    if (h?.drifted) {
      parts.push(`⤺ off its parent (${h.parent ?? "?"}) — not a git ancestor, so diff-vs-parent ≈ vs main (⋯ → reseat)`);
    }
    if (h?.upstreamBad) {
      parts.push(`⚠ tracks ${h.upstream ?? "?"} — ${h.upstreamReason ?? "wrong remote"} (⋯ → detach)`);
    }
    if (h?.diverged) {
      parts.push(`⇄ diverged from ${h.upstream ?? "its pushed head"} (${h.ahead ?? 0}↑ ${h.behind ?? 0}↓) — ⌁ prep carries it additively; ⋯ → inspect / reconcile`);
    }
    if ((sync.data?.dirty?.length ?? 0) > 0) {
      parts.push(`± ${sync.data!.dirty!.length} uncommitted in ${sync.data!.dirtyWorktree}:\n${sync.data!.dirty!.join("\n")}`);
    }
    return parts.join("\n\n");
  };
  // Edge = the single LOCAL next step (Phil: "whatever we do here locally is fine").
  // The shared world never moves from this slot — that's the red button's sole job.
  const edge = (): SpineEdge | null => {
    const step = nextStepOf({
      merged: props.merged,
      contractable: props.health?.contractable,
      contractKids: contractKids(),
      drifted: props.health?.drifted,
      behind: behind(),
      syncable: sync.data?.syncable,
      prepRoute: prepRoute.data?.route,
      prepWhy: prepRoute.data?.why,
    });
    if (!step) {
      return null;
    }
    const contracting = step.kind === "contract";
    return {
      label: step.label,
      kind: step.kind,
      title: step.title,
      pending: contracting ? contract.isPending : omniSync.isPending,
      onClick: fire(contracting ? () => contract.mutate() : startSync),
    };
  };
  const fire = (fn: () => void) => () => {
    setDone(null);
    setDoneAlert(false);
    fn();
  };

  return (
    <div class="node-actions relative flex flex-wrap items-center gap-[9px]" ref={root}>
      {/* the waymark spine — one chip (where the branch stands: edit → review → ready →
          shared → merged, each station lit in its own material) and one slot (the single
          next step, hidden at rest). What used to be the shared chip, the push-blocked
          badge, the prep/push button pair, and the contract button is now: station,
          reasons (tooltip), edge. */}
      <Show when={!isReview()}>
        <NodeSpine
          station={station()}
          blessedAll={blessedAll()}
          reasons={reasons()}
          edge={edge()}
          dirty={sync.data?.dirty?.length ?? 0}
        />
      </Show>

      {/* THE red button — the only way anything here reaches origin (Phil: "whatever is
          being shared publicly needs to be with me at the helm"). Deliberately not the
          spine's slot: local motions and the shared-history door never share a control.
          Appears only when a commit is actually outgoing; arms only when the wards are
          green; the server re-verifies everything at push time regardless. */}
      <Show when={!isReview() && (preview.data?.outgoing ?? 0) > 0}>
        <button
          class={`nh-fix nh-push-red ${PUSH_RED} ${armed() === "pushOrigin" ? "armed bg-del text-vellum-night" : "bg-transparent text-del enabled:hover:bg-del-bg"}`}
          disabled={busy() || !preview.data?.ok}
          title={
            preview.data?.ok
              ? "push to origin — the team sees this the moment it lands (fast-forward, one reviewed commit)"
              : `not pushable yet:\n${(preview.data?.reasons ?? ["reading the branch…"]).join("\n")}`
          }
          onClick={fire(() => trigger("pushOrigin", () => pushOrigin.mutate()))}
        >
          {pushOrigin.isPending ? "pushing…" : armed() === "pushOrigin" ? "confirm: push to origin" : "⇧ push to origin"}
        </button>
      </Show>

      {/* open the ONE outgoing commit's message on demand — play with it (or ✦ voice it) and
          push, without running the whole sync motion first. Pre-filled from the push-preview
          verdict; the editor it opens is the same one prep ends at. Hidden while it's already
          open so a re-click can't clobber unsaved edits. */}
      <Show when={!isReview() && preview.data?.commit && !editorOpen()}>
        <button
          class={`nh-fix nh-open-pr ${FIX}`}
          disabled={busy()}
          title="edit this commit's message (subject + body) before pushing — no sync needed"
          onClick={() => {
            const c = preview.data!.commit!;
            setMsgSubject(c.subject);
            setMsgBody(c.body);
            setEditorOpen(true);
          }}
        >
          ✎ message
        </button>
      </Show>

      {/* the branch IS on origin: the PR page is one click away regardless of outgoing state.
          Open the PR (view/tweak) or the compare-and-create form (author) — no push, no gh pr
          create. With a commit still outgoing it shows what origin has NOW; push adds yours. */}
      <Show when={!isReview() && preview.data?.originExists}>
        <button
          class={`nh-fix nh-open-pr ${FIX}`}
          disabled={busy() || openPr.isPending}
          title={
            preview.data?.published
              ? "opens this branch's open PR in a browser — tweak it on github.com (no push)"
              : (preview.data?.outgoing ?? 0) > 0
                ? "opens the compare-and-create page for what origin already has — author or tweak the PR there; the outgoing commit joins it once you push (no push, no gh pr create)"
                : "pushed to origin but no PR yet — opens the compare-and-create page to author it (no push, no gh pr create)"
          }
          onClick={() => openPr.mutate()}
        >
          {openPr.isPending ? "opening…" : preview.data?.published ? "↗ view PR" : "↗ open PR"}
        </button>
      </Show>

      {/* review node: when the author pushed, surface it on load + offer the keep-blessings pull */}
      <Show when={isReview() && remote.data?.available}>
        <span
          class="nh-pushed cursor-help text-[12px] font-semibold text-del"
          title={`they pushed — your branch is at ${remote.data?.local}, theirs at ${remote.data?.remote}`}
        >
          ↯ they pushed
        </span>
        <button
          class={`nh-fix ${FIX}`}
          disabled={busy()}
          title="re-fetch this PR's pushed head into your local review branch. Your blessings stay — files whose content is unchanged remain blessed; changed files fall to stale for re-review."
          onClick={fire(() => pull.mutate())}
        >
          {pull.isPending ? "pulling…" : "pull to their state"}
        </button>
      </Show>

      {/* held-elsewhere banner: checkout / sync 409'd because another worktree holds the
          branch. Offer to free it and resume whichever action hit it. */}
      <Show when={heldAt()}>
        <span class="nh-held inline-flex items-center gap-[8px] text-[12px] text-ink-faint">
          held in {heldAt()}{heldWhy() ? ` — ${heldWhy()}` : ""}
          <button class="nh-held-btn cursor-pointer rounded-[5px] border border-del bg-transparent px-[7px] py-[2px] text-[11px] leading-[1.55] text-del disabled:cursor-default disabled:opacity-50" disabled={busy()} onClick={freeAndContinue}>
            free &amp; {heldFor() === "omniSync" ? "sync" : "checkout"}
          </button>
          <button class="nh-held-btn cursor-pointer rounded-[5px] border border-del bg-transparent px-[7px] py-[2px] text-[11px] leading-[1.55] text-del disabled:cursor-default disabled:opacity-50" onClick={() => setHeldAt(null)}>cancel</button>
        </span>
      </Show>

      {/* ⋯ menu — plain checkout, conditional repairs, interest, chats. */}
      <button
        class="icon-btn"
        classList={{ on: open() }}
        aria-haspopup="true"
        aria-expanded={open()}
        title="branch actions — checkout, conditional repairs, interest, chats"
        onClick={() => setOpen((o) => !o)}
      >
        ⋯
      </button>

      <Show when={open()}>
        <div class="nh-menu absolute top-[calc(100%+7px)] right-0 z-20 flex min-w-[196px] flex-col gap-[2px] rounded-[9px] border border-rule bg-vellum-raise p-[6px] shadow-[0_12px_34px_-14px_rgba(0,0,0,0.75)]" role="menu">
          {/* checkout — move the primary working tree onto this branch without squashing (view it) */}
          <button
            class={`nh-item ${ITEM}`}
            role="menuitem"
            disabled={busy()}
            title="move this repo's main checkout onto this branch (no squash — just switch to it)"
            onClick={fire(() => checkout.mutate(false))}
          >
            <span class={`nh-item-ic ${IC}`}>⤓</span>
            {checkout.isPending ? "checking out…" : "checkout here"}
          </button>

          {/* preview — spin a dev server for this branch on a side port and open it, WITHOUT
              moving your main checkout off :3000 (loops-preview). Stop it from the Activity dock. */}
          <button
            class={`nh-item ${ITEM}`}
            role="menuitem"
            disabled={busy() || devServer.isPending}
            title="spin up a dev server for this branch on a side port (3010+) and open it — leaves :3000 and your checkout alone"
            onClick={fire(() => devServer.mutate())}
          >
            <span class={`nh-item-ic ${IC}`}>▷</span>
            {devServer.isPending ? "starting preview…" : "preview (dev server)"}
          </button>

          {/* conditional repairs — appear only with their condition; everything routine
              lives in ⟲ sync (Phil's menu cull, 2026-07-05: restack / reconcile / push-card /
              worktree crossed out — "the more I look at this menu the more I want an omni
              sync button") */}
          <Show when={!isReview()}>
            <Show when={props.health?.drifted && props.onReseat}>
              <button
                class={`nh-item ${ITEM}`}
                role="menuitem"
                title={`rebase this branch (and any orphaned siblings, recursively) back onto ${props.health?.parent ?? "its parent"}'s current tip — local only, nothing pushed, nothing else moves`}
                onClick={() => { setOpen(false); props.onReseat!(); }}
              >
                <span class={`nh-item-ic ${IC}`}>⤴</span> reseat onto {props.health?.parent ?? "parent"}
              </button>
            </Show>
            <Show when={props.health?.upstreamBad && props.onDetach}>
              <button
                class={`nh-item ${ITEM}`}
                role="menuitem"
                title="unset this tracking ref so a Pull/Push can't merge the wrong remote in — keeps every commit"
                onClick={() => { setOpen(false); props.onDetach!(); }}
              >
                <span class={`nh-item-ic ${IC}`}>✂</span> detach tracking ref
              </button>
            </Show>
            <Show when={props.health?.diverged && props.onInspect}>
              <button
                class={`nh-item ${ITEM}`}
                role="menuitem"
                title="show exactly what diverged: each side's commits (rebased twins flagged) + the PR's diff now vs after an additive update"
                onClick={() => { setOpen(false); props.onInspect!(); }}
              >
                <span class={`nh-item-ic ${IC}`}>⇄</span> inspect divergence
              </button>
            </Show>
          </Show>

          {/* interest + all-threads — demoted off the header bar (strike-6 trim) */}
          <Show when={props.onBump}>
            <button class={`nh-item ${ITEM}`} role="menuitem" onClick={() => props.onBump!(1)}>
              <span class={`nh-item-ic ${IC}`}>▲</span> promote forest on Home{(props.interest ?? 0) > 0 ? ` (now ${props.interest})` : ""}
            </button>
            <Show when={(props.interest ?? 0) > 0}>
              <button class={`nh-item ${ITEM}`} role="menuitem" onClick={() => props.onBump!(-1)}>
                <span class={`nh-item-ic ${IC}`}>▼</span> demote
              </button>
            </Show>
          </Show>
          <Show when={props.onAllChats}>
            <button class={`nh-item ${ITEM}`} role="menuitem" onClick={() => { setOpen(false); props.onAllChats!(); }}>
              <span class={`nh-item-ic ${IC}`}>💬</span> all chat threads
            </button>
          </Show>

        </div>
      </Show>

      {/* the sync step strip — the wards pattern for the motion itself: every step visible,
          a failing step carrying its reason IN FULL (never truncated), and the dirt decision
          rendered inline when the working tree needs a human call. */}
      <Show when={syncSteps()}>
        <div class="nh-strip">
          <div class="nh-strip-row">
            <For each={syncSteps()!}>
              {(s) => (
                <span class="nh-step" data-state={s.state}>
                  {/* fixed-width marker: the ·→⟳→✓ swaps must not nudge their neighbors */}
                  <i class="nh-step-ic">
                    {s.state === "ok" ? "✓" : s.state === "fail" ? "✗" : s.state === "run" ? "⟳" : s.state === "skip" ? "↷" : "·"}
                  </i>
                  {s.label}
                  <Show when={s.state === "run" && s.startedAt && nowTick() - s.startedAt > 2500}>
                    <span class="nh-step-s">{Math.floor((nowTick() - s.startedAt!) / 1000)}s</span>
                  </Show>
                </span>
              )}
            </For>
            <button class="nh-strip-x" title="dismiss" onClick={() => { setSyncSteps(null); setDirtGate(false); }}>×</button>
          </div>
          <For each={syncSteps()!.filter((s) => s.note)}>
            {(s) => (
              <div class="nh-step-note" data-state={s.state}>
                <b>{s.label}:</b> {s.note}
              </div>
            )}
          </For>
          <Show when={dirtGate()}>
            <div class="nh-dirt">
              <div class="nh-dirt-files">
                <For each={sync.data?.dirty ?? []}>{(f) => <code>{f}</code>}</For>
              </div>
              <div class="nh-dirt-acts">
                <button class={`nh-fix ${FIX}`} onClick={() => dirtDecide("include")} title="stage + commit everything in the holding worktree; the squash folds it into the outgoing commit">
                  fold into the commit
                </button>
                <button class={`nh-fix ${FIX}`} onClick={() => dirtDecide("stash")} title="stash (incl. untracked), run the motion, pop the stash after — your changes come back">
                  stash &amp; continue
                </button>
                <button class={`nh-fix nh-dirt-abort ${FIX}`} onClick={() => dirtDecide("abort")} title="stop — the working tree stays exactly as it is">
                  abort
                </button>
              </div>
            </div>
          </Show>
        </div>
      </Show>

      <Show when={done()}>
        <span class={`nh-done ${DONE} ${doneAlert() ? "nh-done-alert overflow-visible whitespace-normal rounded-[5px] border border-del bg-del-bg px-[7px] py-[2px] font-semibold text-del" : "max-w-[22ch] overflow-hidden text-ellipsis whitespace-nowrap text-patina opacity-90"}`} title={done() ?? ""}>{done()}</span>
      </Show>
      <Show when={pushedWeb()}>
        <a class={`nh-pushed-link text-add ${DONE}`} href={pushedWeb()!} target="_blank" rel="noreferrer">
          {pushedWeb()!.includes("/pull/") ? "view the open PR ↗" : "author PR on github.com ↗"}
        </a>
      </Show>

      {/* the message editor — prep always ends here: the ONE outgoing commit's subject +
          body, editable before the push. Saving rewrites only that unpushed commit
          (server-verified); the tree, author, and gates verdict are untouched. */}
      <Show when={editorOpen()}>
        <div class="nh-editor">
          <Show when={routedNotes().length}>
            <div class="nh-editor-routed text-[11px] italic text-patina">{routedNotes().join(" · ")}</div>
          </Show>
          <input
            class="nh-editor-subject border-x-0 border-t-0 border-b border-rule bg-transparent px-[1px] py-[3px] font-display text-[17px] font-semibold italic text-ink outline-none focus:border-b-gold-leaf"
            value={msgSubject()}
            placeholder="subject — the one line the team reads in history"
            onInput={(e) => setMsgSubject(e.currentTarget.value)}
          />
          {/* each step's line writes its OWN branch's durable story — so a story survives this
              branch's merge, instead of being frozen as text in this one commit's plan block */}
          <PlanStepsEditor branch={props.branch} onSaved={() => planFill.mutate()} />
          <textarea
            class="nh-editor-body resize-y border-0 bg-transparent p-[1px] font-mono text-[12px] leading-[1.55] text-ink-dim outline-none"
            value={msgBody()}
            placeholder="body — what ships and why"
            rows={5}
            onInput={(e) => setMsgBody(e.currentTarget.value)}
          />
          <div class="nh-editor-row flex items-center gap-[10px]">
            <button
              class={`nh-fix nh-editor-save ${FIX}`}
              disabled={saveMsg.isPending || !msgSubject().trim()}
              onClick={() => saveMsg.mutate()}
            >
              {saveMsg.isPending ? "saving…" : "save message"}
            </button>
            <button
              class={`nh-editor-close ${EDITOR_CLOSE}`}
              disabled={planFill.isPending}
              title="recompute this branch's forest-plan block from the stack config (free — no model call)"
              onClick={() => planFill.mutate()}
            >
              {planFill.isPending ? "…" : "↻ plan"}
            </button>
            <button
              class={`nh-editor-close ${EDITOR_CLOSE}`}
              disabled={draftMsg.isPending}
              title="ask claude to draft the message in your voice from the outgoing diff"
              onClick={() => draftMsg.mutate()}
            >
              {draftMsg.isPending ? "voicing…" : "✦ voice"}
            </button>
            <button class={`nh-editor-close ${EDITOR_CLOSE}`} onClick={() => setEditorOpen(false)}>
              close
            </button>
          </div>
        </div>
      </Show>

      <Show when={rebaseStreaming()}>
        <RebaseStream
          branch={props.branch}
          onClose={() => setRebaseStreaming(false)}
          onSettled={(outcome) => {
            if (outcome === "done") {
              // the headless rebase landed cleanly — the branch now contains origin/main, so
              // pick the motion back up where it ejected (checkout → one commit → gates → editor)
              // instead of stranding a ticking spinner that waits on a manual re-click.
              stepSet("rebase", "ok", "landed — merging it in");
              setRebaseStreaming(false);
              sync.refetch().then(() => omniSync.mutate(false));
            } else if (outcome === "stopped") {
              stepSet("rebase", "fail", "stopped — re-run sync to retry the rebase");
            } else if (outcome === "gone") {
              stepSet("rebase", "fail", "rebase job gone (expired or server restarted) — re-run sync to see where it landed");
            } else {
              stepSet("rebase", "fail", "rebase stream errored — re-run sync to retry");
            }
          }}
        />
      </Show>
    </div>
  );
}
