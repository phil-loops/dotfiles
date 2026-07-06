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
import { createSignal, Show, onCleanup } from "solid-js";
import { createMutation, createQuery, useQueryClient } from "@tanstack/solid-query";
import { provider, canMutate, withRepo } from "./provider";
import { useArm } from "./actions";
import RebaseStream from "./RebaseStream";
import NodeSpine, { type Station, type SpineEdge } from "./NodeSpine";

interface CheckoutResult {
  ok?: boolean;
  err?: string;
  worktree?: string; // set on 409: the worktree currently holding the branch
}

interface PrepResult {
  ok?: boolean;
  n?: number; // unpushed commits collapsed into one
  header?: string; // the new voiced subject
  formatted?: number; // files oxfmt touched
  err?: string;
}

interface SyncResult {
  ok?: boolean;
  err?: string;
  rebased?: boolean; // clean forward-rebase landed in place
  ejected?: boolean; // couldn't rebase in place → handed to a headless claude, streamed
  stream?: string; // the rebase job key to tail over /rebase-stream (set with ejected)
  conflict?: boolean; // hit a conflict → Claude resolving in a worktree
  contract?: boolean; // branch already merged into origin/main → drop & rewire instead
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
    drifted?: boolean; parent?: string;
    upstreamBad?: boolean; upstreamReason?: string; upstream?: string;
    diverged?: boolean; ahead?: number; behind?: number;
  } | null;
  onReseat?: () => void; // rebase drifted children back onto the parent's tip (App owns the mutation)
  onDetach?: () => void; // unset a footgun tracking ref
  onInspect?: () => void; // toggle the diverged-inspect panel (lives in App below the header)
  ambient?: { verdict?: string; behind?: number | null; conflict_pr?: number | null; conflict_title?: string | null } | null;
  interest?: number; // current Home-ordering interest — drives the ⋯ promote/demote items
  onBump?: (delta: number) => void;
  onAllChats?: () => void;
}) {
  if (!canMutate) return null; // static snapshot: no rebase/checkout/squash actions
  const qc = useQueryClient();
  // 409 stash: the worktree holding the branch, awaiting a force-confirm — plus which action
  // hit it, so freeing the worktree resumes the right one (plain checkout vs the omni sync).
  const [heldAt, setHeldAt] = createSignal<string | null>(null);
  const [heldFor, setHeldFor] = createSignal<"checkout" | "omniSync">("checkout");
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
        setDone(`✓ checked out in ${r.worktree || "your main checkout"}`);
        qc.invalidateQueries({ queryKey: ["head"] });
      } else if (r.worktree) {
        setHeldFor("checkout");
        setHeldAt(r.worktree); // held elsewhere → offer to free it
      } else {
        setDone(`✗ ${r.err || "checkout failed"}`);
      }
    },
    onError: (e) => setDone(`✗ ${(e as Error).message || "checkout failed"}`),
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
  // (additive for a diverged PR, squash for a messy tail) → advisory tests → the message
  // editor. When a step isn't mechanically routable, Claude goes in the middle (reconcile
  // eject). NOTHING here touches origin — the shared world moves only via the red button.
  const omniSync = createMutation(() => ({
    mutationFn: async (force: boolean) => {
      if (props.health?.drifted && props.health.parent) {
        setDone("⤴ reseating onto its parent…");
        await post("/reseat-children", { branch: props.health.parent });
      }
      if (behind() > 0 && sync.data?.syncable) {
        setDone("⟳ fetching origin/main + rebasing…");
        const sy = await post<SyncResult>("/sync", { branch: props.branch });
        if (sy.ok && sy.contract) {
          return { phase: "blocked" as const, msg: "already merged into origin/main — drop & rewire (the spine's edge offers it)" };
        }
        if (sy.ok && !sy.rebased) {
          // ejected to a headless rebase → stream it inline; run sync again once it lands.
          return { phase: "streaming" as const };
        }
        // a refusal (stacked / open PR) is fine — those route through prep-push below
      }
      setDone("⤓ checking out onto your main checkout…");
      const co = await post<CheckoutResult>("/checkout", { branch: props.branch, force });
      if (!co.ok) {
        if (co.worktree) {
          return { phase: "held" as const, held: co.worktree };
        }
        return { phase: "error" as const, msg: co.err || "checkout failed" };
      }
      setDone("⊟ routing to one outgoing commit…");
      const pr = await post<{ ok?: boolean; err?: string; reconcile?: boolean; routed?: string[]; commit?: { sha: string; subject: string; body: string } | null }>(
        "/prep-push", { branch: props.branch });
      if (!pr.ok) {
        if (pr.reconcile) {
          return { phase: "claude" as const };
        }
        if ((pr.err ?? "").startsWith("nothing to push")) {
          return { phase: "done" as const, routed: ["nothing to push — origin already has this"], commit: null };
        }
        return { phase: "error" as const, msg: pr.err || "prep failed" };
      }
      setDone("⧗ running changed tests…");
      let tests: DeltaTestResult | null = null;
      try {
        tests = await post<DeltaTestResult>("/delta-tests", { branch: props.branch });
      } catch {
        tests = null; // tests are advisory — a runner crash never blocks a local sync
      }
      return { phase: "done" as const, routed: pr.routed ?? [], commit: pr.commit ?? null, tests };
    },
    onSuccess: (r) => {
      setOpen(false);
      if (r.phase === "held") {
        setHeldFor("omniSync");
        setHeldAt(r.held);
        return;
      }
      if (r.phase === "blocked") {
        setDone(`● ${r.msg}`);
        sync.refetch();
        return;
      }
      if (r.phase === "streaming") {
        setDone(null);
        setRebaseStreaming(true); // the rebase is running headless — tail it inline below
        sync.refetch();
        return;
      }
      if (r.phase === "claude") {
        reconcile.mutate(); // divergence with no mechanical route — Claude in the middle
        return;
      }
      if (r.phase === "error") {
        setDone(`✗ ${r.msg}`);
        qc.invalidateQueries({ queryKey: ["head"] });
        return;
      }
      setHeldAt(null);
      let t = "";
      if (r.tests) {
        if (r.tests.noTests) {
          t = " · no changed tests";
        } else if (r.tests.ran) {
          t = r.tests.ok ? ` · tests ${r.tests.passed ?? "?"}✓` : ` · ✗ tests ${r.tests.failed ?? "?"} FAILED`;
        } else {
          t = " · ⚠ tests couldn't run";
        }
      }
      setDone(`✓ synced — ${(r.routed ?? []).join(" · ") || "clean"}${t}`);
      if (r.commit) {
        setRoutedNotes(r.routed ?? []);
        setMsgSubject(r.commit.subject);
        setMsgBody(r.commit.body);
        setEditorOpen(true);
      }
      qc.invalidateQueries({ queryKey: ["head"] });
      qc.invalidateQueries({ queryKey: ["commits", props.branch] });
      qc.invalidateQueries({ queryKey: ["node", props.branch] });
      qc.invalidateQueries({ queryKey: ["model"] });
      qc.invalidateQueries({ queryKey: ["restack-ambient"] });
      sync.refetch();
      preview.refetch();
    },
    onError: (e) => setDone(`✗ ${(e as Error).message || "sync failed"}`),
  }));

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
        (r) => r.json() as Promise<{ ok?: boolean; outgoing?: number; reasons?: string[]; web?: string }>,
      ),
    enabled: !!props.branch && !props.isReview,
  }));
  const [pushedWeb, setPushedWeb] = createSignal<string | null>(null);
  const pushOrigin = createMutation(() => ({
    mutationFn: () =>
      post<{ ok?: boolean; err?: string; web?: string }>("/push-origin", { branch: props.branch }),
    onSuccess: (r) => {
      refreshAfterPrep();
      if (!r.ok) {
        setDone(`✗ ${r.err || "push refused"}`);
        return;
      }
      setDone("✓ pushed — origin has it");
      setPushedWeb(r.web ?? null);
    },
    onError: (e) => setDone(`✗ ${(e as Error).message || "push failed"}`),
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
  const station = (): Station => {
    if (props.merged || shared() === "gone") {
      return "merged";
    }
    const r = prepRoute.data?.route;
    if (r === "nothing") {
      return "shared";
    }
    if (r === "ready") {
      return "ready";
    }
    if (props.blessing && props.blessing.blessed < props.blessing.total) {
      return "review";
    }
    return "edit";
  };
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
    return parts.join("\n\n");
  };
  // Edge = the single LOCAL next step (Phil: "whatever we do here locally is fine").
  // The shared world never moves from this slot — that's the red button's sole job.
  const edge = (): SpineEdge | null => {
    if (props.merged || contractKids()) {
      return {
        label: contractKids() ? `drop ghost & rewire ${contractKids()!.length} →` : "drop ghost & rewire →",
        kind: "contract",
        pending: contract.isPending,
        title: "this branch's work already merged (a ghost) — drop it, rewire its children onto main, drop any requires edge on it",
        onClick: fire(() => contract.mutate()),
      };
    }
    const r = prepRoute.data?.route;
    const idle = (!r || r === "nothing") && !props.health?.drifted && behind() === 0;
    if (idle) {
      return null; // truly at rest — the slot does not render
    }
    const steps: string[] = [];
    if (props.health?.drifted) {
      steps.push("reseat onto its parent");
    }
    if (behind() > 0 && sync.data?.syncable) {
      steps.push(`rebase forward (${behind()} behind)`);
    }
    steps.push("checkout here");
    if (r && r !== "nothing" && r !== "ready") {
      steps.push(prepRoute.data?.why ?? "route to one outgoing commit");
    }
    steps.push("open the message editor");
    return {
      label: "⟲ sync",
      kind: "prep",
      pending: omniSync.isPending,
      title: `sync — everything local, in one motion:\n· ${steps.join("\n· ")}\n(Claude steps in when a divergence has no mechanical route)`,
      onClick: fire(() => omniSync.mutate(false)),
    };
  };
  const fire = (fn: () => void) => () => {
    setDone(null);
    setDoneAlert(false);
    fn();
  };

  return (
    <div class="node-actions" ref={root}>
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
        />
      </Show>

      {/* THE red button — the only way anything here reaches origin (Phil: "whatever is
          being shared publicly needs to be with me at the helm"). Deliberately not the
          spine's slot: local motions and the shared-history door never share a control.
          Appears only when a commit is actually outgoing; arms only when the wards are
          green; the server re-verifies everything at push time regardless. */}
      <Show when={!isReview() && (preview.data?.outgoing ?? 0) > 0}>
        <button
          class="nh-fix nh-push-red"
          classList={{ armed: armed() === "pushOrigin" }}
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

      {/* review node: when the author pushed, surface it on load + offer the keep-blessings pull */}
      <Show when={isReview() && remote.data?.available}>
        <span
          class="nh-pushed"
          title={`they pushed — your branch is at ${remote.data?.local}, theirs at ${remote.data?.remote}`}
        >
          ↯ they pushed
        </span>
        <button
          class="nh-fix"
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
        <span class="nh-held">
          held in {heldAt()}
          <button class="nh-held-btn" disabled={busy()} onClick={freeAndContinue}>
            free &amp; {heldFor() === "omniSync" ? "sync" : "checkout"}
          </button>
          <button class="nh-held-btn" onClick={() => setHeldAt(null)}>cancel</button>
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
        <div class="nh-menu" role="menu">
          {/* checkout — move the primary working tree onto this branch without squashing (view it) */}
          <button
            class="nh-item"
            role="menuitem"
            disabled={busy()}
            title="move this repo's main checkout onto this branch (no squash — just switch to it)"
            onClick={fire(() => checkout.mutate(false))}
          >
            <span class="nh-item-ic">⤓</span>
            {checkout.isPending ? "checking out…" : "checkout here"}
          </button>

          {/* conditional repairs — appear only with their condition; everything routine
              lives in ⟲ sync (Phil's menu cull, 2026-07-05: restack / reconcile / push-card /
              worktree crossed out — "the more I look at this menu the more I want an omni
              sync button") */}
          <Show when={!isReview()}>
            <Show when={props.health?.drifted && props.onReseat}>
              <button
                class="nh-item"
                role="menuitem"
                title={`rebase this branch (and any orphaned siblings, recursively) back onto ${props.health?.parent ?? "its parent"}'s current tip — local only, nothing pushed, nothing else moves`}
                onClick={() => { setOpen(false); props.onReseat!(); }}
              >
                <span class="nh-item-ic">⤴</span> reseat onto {props.health?.parent ?? "parent"}
              </button>
            </Show>
            <Show when={props.health?.upstreamBad && props.onDetach}>
              <button
                class="nh-item"
                role="menuitem"
                title="unset this tracking ref so a Pull/Push can't merge the wrong remote in — keeps every commit"
                onClick={() => { setOpen(false); props.onDetach!(); }}
              >
                <span class="nh-item-ic">✂</span> detach tracking ref
              </button>
            </Show>
            <Show when={props.health?.diverged && props.onInspect}>
              <button
                class="nh-item"
                role="menuitem"
                title="show exactly what diverged: each side's commits (rebased twins flagged) + the PR's diff now vs after an additive update"
                onClick={() => { setOpen(false); props.onInspect!(); }}
              >
                <span class="nh-item-ic">⇄</span> inspect divergence
              </button>
            </Show>
          </Show>

          {/* interest + all-threads — demoted off the header bar (strike-6 trim) */}
          <Show when={props.onBump}>
            <button class="nh-item" role="menuitem" onClick={() => props.onBump!(1)}>
              <span class="nh-item-ic">▲</span> promote on Home{(props.interest ?? 0) > 0 ? ` (now ${props.interest})` : ""}
            </button>
            <Show when={(props.interest ?? 0) > 0}>
              <button class="nh-item" role="menuitem" onClick={() => props.onBump!(-1)}>
                <span class="nh-item-ic">▼</span> demote
              </button>
            </Show>
          </Show>
          <Show when={props.onAllChats}>
            <button class="nh-item" role="menuitem" onClick={() => { setOpen(false); props.onAllChats!(); }}>
              <span class="nh-item-ic">💬</span> all chat threads
            </button>
          </Show>

        </div>
      </Show>

      <Show when={done()}>
        <span class="nh-done" classList={{ "nh-done-alert": doneAlert() }} title={done() ?? ""}>{done()}</span>
      </Show>
      <Show when={pushedWeb()}>
        <a class="nh-pushed-link" href={pushedWeb()!} target="_blank" rel="noreferrer">
          open on github.com
        </a>
      </Show>

      {/* the message editor — prep always ends here: the ONE outgoing commit's subject +
          body, editable before the push. Saving rewrites only that unpushed commit
          (server-verified); the tree, author, and gates verdict are untouched. */}
      <Show when={editorOpen()}>
        <div class="nh-editor">
          <Show when={routedNotes().length}>
            <div class="nh-editor-routed">{routedNotes().join(" · ")}</div>
          </Show>
          <input
            class="nh-editor-subject"
            value={msgSubject()}
            placeholder="subject — the one line the team reads in history"
            onInput={(e) => setMsgSubject(e.currentTarget.value)}
          />
          <textarea
            class="nh-editor-body"
            value={msgBody()}
            placeholder="body — what ships and why"
            rows={5}
            onInput={(e) => setMsgBody(e.currentTarget.value)}
          />
          <div class="nh-editor-row">
            <button
              class="nh-fix nh-editor-save"
              disabled={saveMsg.isPending || !msgSubject().trim()}
              onClick={() => saveMsg.mutate()}
            >
              {saveMsg.isPending ? "saving…" : "save message"}
            </button>
            <button class="nh-editor-close" onClick={() => setEditorOpen(false)}>
              close
            </button>
          </div>
        </div>
      </Show>

      <Show when={rebaseStreaming()}>
        <RebaseStream branch={props.branch} onClose={() => setRebaseStreaming(false)} />
      </Show>
    </div>
  );
}
