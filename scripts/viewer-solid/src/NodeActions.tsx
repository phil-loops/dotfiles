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
import { useViewerLocation } from "./router";
import RebaseStream from "./RebaseStream";

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
  ambient?: { verdict?: string; behind?: number | null; conflict_pr?: number | null; conflict_title?: string | null } | null;
  interest?: number; // current Home-ordering interest — drives the ⋯ promote/demote items
  onBump?: (delta: number) => void;
  onAllChats?: () => void;
}) {
  if (!canMutate) return null; // static snapshot: no rebase/checkout/squash actions
  const qc = useQueryClient();
  const { navigate } = useViewerLocation();
  // 409 stash: the worktree holding the branch, awaiting a force-confirm — plus which action
  // hit it, so freeing the worktree resumes the right one (plain checkout vs full prep-to-merge).
  const [heldAt, setHeldAt] = createSignal<string | null>(null);
  const [heldFor, setHeldFor] = createSignal<"checkout" | "prepMerge">("checkout");
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
  const prepMerge = createMutation(() => ({
    mutationFn: async (force: boolean) => {
      if (behind() > 0) {
        setDone("⟳ fetching origin/main + rebasing…");
        const sy = await post<SyncResult>("/sync", { branch: props.branch });
        if (!sy.ok) {
          return { phase: "blocked" as const, msg: sy.err || "rebase onto origin/main refused" };
        }
        if (sy.contract) {
          return { phase: "blocked" as const, msg: "already merged into origin/main — drop & rewire it instead (restack)" };
        }
        if (!sy.rebased) {
          // ejected to a headless rebase → stream it inline; re-run prep to merge once it lands.
          return { phase: "streaming" as const };
        }
      }
      setDone("⤓ checking out onto your main checkout…");
      const co = await post<CheckoutResult>("/checkout", { branch: props.branch, force });
      if (!co.ok) {
        if (co.worktree) {
          return { phase: "held" as const, held: co.worktree };
        }
        return { phase: "error" as const, msg: co.err || "checkout failed" };
      }
      setDone("⊟ squashing the branch + oxfmt…");
      const pr = await post<PrepResult>("/prep", { branch: props.branch });
      if (!pr.ok) {
        return { phase: "error" as const, msg: `checked out, but squash failed: ${pr.err || "?"}` };
      }
      setDone("⧗ running changed tests…");
      let tests: DeltaTestResult | null = null;
      try {
        tests = await post<DeltaTestResult>("/delta-tests", { branch: props.branch });
      } catch {
        tests = null; // tests are advisory — a runner crash never blocks the merge prep
      }
      return { phase: "done" as const, n: pr.n ?? 0, header: pr.header, formatted: pr.formatted, tests };
    },
    onSuccess: (r) => {
      setOpen(false);
      if (r.phase === "held") {
        setHeldFor("prepMerge");
        setHeldAt(r.held);
        sync.refetch(); // the rebase already ran → retry skips it (behind == 0)
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
      if (r.phase === "error") {
        setDone(`✗ ${r.msg}`);
        qc.invalidateQueries({ queryKey: ["head"] });
        return;
      }
      setHeldAt(null);
      const n = r.n ?? 0;
      const fmt = r.formatted ? `, fmt ${r.formatted}` : "";
      const squashed = n > 1 ? `squashed ${n} → 1${fmt}` : `1 commit${fmt}`;
      const head = r.header ? `: ${r.header}` : "";
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
      setDone(`✓ ready — checked out + ${squashed}${head}${t} — push from GitHub Desktop`);
      qc.invalidateQueries({ queryKey: ["head"] });
      qc.invalidateQueries({ queryKey: ["commits", props.branch] });
      qc.invalidateQueries({ queryKey: ["node", props.branch] });
      qc.invalidateQueries({ queryKey: ["model"] });
      qc.invalidateQueries({ queryKey: ["restack-ambient"] });
      sync.refetch();
    },
    onError: (e) => setDone(`✗ ${(e as Error).message || "prep to merge failed"}`),
  }));

  // free the worktree that 409'd, then resume whichever action hit it.
  const freeAndContinue = () => {
    setOpen(false);
    if (heldFor() === "prepMerge") {
      prepMerge.mutate(true);
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

  // rebase forward onto origin/main. The server rebases in place when the branch is behind a
  // clean main (the common 1-behind case) → {rebased:true} lands instantly; a real conflict or
  // an unsafe layout ejects to a standalone Claude in an isolated worktree → {ejected:true}.
  // Non-syncable branches (open PR / stacked) come back 409 with the reason, surfaced via done().
  const rebase = createMutation(() => ({
    mutationFn: () =>
      post<{ ok?: boolean; err?: string; rebased?: boolean; ejected?: boolean; conflict?: boolean; contract?: boolean; children?: string[]; summary?: string }>(
        "/sync",
        { branch: props.branch },
      ),
    onSuccess: (r) => {
      setOpen(false);
      if (!r.ok) {
        setDone(`✗ ${r.err || "rebase failed"}`);
        return;
      }
      if (r.rebased) {
        setDone(`✓ rebased — ${r.summary || "up to date with origin/main"}`);
        qc.invalidateQueries({ queryKey: ["node", props.branch] });
        qc.invalidateQueries({ queryKey: ["commits", props.branch] });
        qc.invalidateQueries({ queryKey: ["model"] });
        qc.invalidateQueries({ queryKey: ["restack-ambient"] });
      } else if (r.contract) {
        const kids = r.children ?? [];
        setContractKids(kids);
        setDone(`● already merged into origin/main — drop it & rewire ${kids.length} child${kids.length === 1 ? "" : "ren"} onto main?`);
      } else {
        // ejected (real conflict or unsafe layout) → headless rebase running; tail it inline.
        setDone(null);
        setRebaseStreaming(true);
      }
      sync.refetch();
    },
    onError: (e) => setDone(`✗ ${(e as Error).message || "rebase failed"}`),
  }));

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

  // reveal-in-Finder — demoted from the work-tab rows into this menu (telemetry trim).
  const worktree = createMutation(() => ({
    mutationFn: () => post<{ ok?: boolean; err?: string }>("/worktree", { branch: props.branch }),
    onSuccess: (r) => {
      setOpen(false);
      setDone(r.ok ? "⌂ revealed in Finder" : `✗ ${r.err || "couldn't open worktree"}`);
    },
    onError: (e) => setDone(`✗ ${(e as Error).message || "couldn't open worktree"}`),
  }));

  // ── the two-button flow (design.md "the header is two buttons") ──────────────
  // prep to push: ONE state-routed motion (additive / restack / squash — the server
  // decides) that always lands on exactly one outgoing commit, opened in the editor.
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
  const prepPush = createMutation(() => ({
    mutationFn: () =>
      post<{ ok?: boolean; err?: string; routed?: string[]; commit?: { sha: string; subject: string; body: string } | null }>(
        "/prep-push", { branch: props.branch }),
    onSuccess: (r) => {
      refreshAfterPrep();
      if (!r.ok || !r.commit) {
        setDone(`✗ ${r.err || "prep failed"}`);
        return;
      }
      setRoutedNotes(r.routed ?? []);
      setMsgSubject(r.commit.subject);
      setMsgBody(r.commit.body);
      setEditorOpen(true);
    },
    onError: (e) => setDone(`✗ ${(e as Error).message || "prep failed"}`),
  }));
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
        (r) => r.json() as Promise<{ route?: string; why?: string }>,
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

  const busy = () => checkout.isPending || prepMerge.isPending || rebase.isPending || pull.isPending || contract.isPending || prepPush.isPending || pushOrigin.isPending;
  const fire = (fn: () => void) => () => {
    setDone(null);
    setDoneAlert(false);
    fn();
  };

  return (
    <div class="node-actions" ref={root}>
      {/* local-vs-shared chip — read-only: what (if anything) of this branch the team can
          see on origin. ○ never pushed · ◐ origin behind by N · ● in sync · ✕ deleted on
          origin (merged — contract it). Deliberately its own visual register, distinct from
          the forest chips: those are local relations, this is the shared-with-the-team one. */}
      <Show when={!isReview() && shared()}>
        <span
          class={`nh-shared nh-shared-${shared()}`}
          title={
            shared() === "local"
              ? "local only — never pushed; the team cannot see this branch"
              : shared() === "ahead"
                ? `pushed, but origin is ${aheadOfOrigin()} commit${aheadOfOrigin() === 1 ? "" : "s"} behind your local`
                : shared() === "synced"
                  ? "in sync with origin — the team sees exactly this"
                  : "origin's copy was deleted (squash-merged) — finished work; contract it"
          }
        >
          {shared() === "local"
            ? "○ local"
            : shared() === "ahead"
              ? `◐ ${aheadOfOrigin()}↑`
              : shared() === "synced"
                ? "● shared"
                : "✕ merged"}
        </span>
      </Show>

      {/* fork-state vs origin/main — calm "behind", escalating to ember "push blocked" when
          main changed deploy-critical files this branch lacks (what the pre-push hook rejects).
          When blocked the fix (rebase forward) surfaces inline next to the alarm; the full
          list of missing files lives in the tooltip rather than spread across the header. */}
      {/* the plain "↓ N behind" count is folded into the restack button below; only the
          escalated push-blocked alarm stays as its own ember badge. */}
      <Show when={blocked()}>
        <span
          class="nh-blocked"
          title={`origin/main changed deploy-critical files this branch is missing:\n${critical().join("\n")}\n\nrebase forward to clear the push block`}
        >
          ⚠ push blocked
        </span>
      </Show>

      {/* the header is two buttons (Phil, design.md 2026-07-05): ⌁ prep routes by state —
          additive vehicle for a diverged PR, restack-then-squash for a messy tail, no-op
          when clean — and always opens the outgoing commit's message in the editor below.
          ⇧ push is the Phase-1 warded door, mirrored here from the /push card. Everything
          else (restack, prep-to-merge, reconcile) is an override in ⋯. */}
      <Show when={!isReview()}>
        <button
          class="nh-fix nh-prep"
          disabled={busy()}
          title={
            prepRoute.data?.route
              ? `prep to push — would ${prepRoute.data.route}: ${prepRoute.data.why ?? ""}\nthen open the commit message in the editor`
              : "prep to push — one motion, routed by state: carry a diverged PR's rework as an additive commit / restack forward / seal the unpushed tail into one voiced commit — then edit its message before pushing"
          }
          onClick={fire(() => prepPush.mutate())}
        >
          {prepPush.isPending ? "prepping…" : "⌁ prep to push"}
        </button>
        <button
          class="nh-fix nh-push"
          classList={{ armed: armed() === "pushOrigin" }}
          disabled={busy() || !preview.data?.ok}
          title={
            preview.data?.ok
              ? "push to origin — shared with the team the moment it lands (fast-forward, one reviewed commit)"
              : `the wards aren't green yet:\n${(preview.data?.reasons ?? ["reading the branch…"]).join("\n")}`
          }
          onClick={fire(() => trigger("pushOrigin", () => pushOrigin.mutate()))}
        >
          {pushOrigin.isPending ? "pushing…" : armed() === "pushOrigin" ? "confirm: push to origin" : "⇧ push"}
        </button>
      </Show>

      {/* already-merged ghost → offer the contraction directly. Two ways to get here: the page-load
          health badge (props.merged, the common case — no need to restack-into-a-conflict to find it)
          or /sync reporting an empty-rebase conflict (contractKids, with a known child count). Either
          way /contract re-verifies already-merged server-side, then drops the branch + rewires its
          children onto main AND drops any integrator's requires edge on it. */}
      <Show when={!isReview() && (contractKids() || props.merged)}>
        <button
          class="nh-fix nh-contract"
          disabled={busy()}
          title="this branch's work already merged into origin/main (a ghost) — drop the empty branch, rewire its children onto main, and drop any integrator's requires edge on it (forest contraction). Do this BEFORE restacking an integrator that fans it in."
          onClick={fire(() => contract.mutate())}
        >
          {contract.isPending
            ? "contracting…"
            : contractKids()
              ? `drop ghost & rewire ${contractKids()!.length} →`
              : "drop ghost & rewire →"}
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

      {/* held-elsewhere banner: checkout / prep-to-merge 409'd because another worktree holds the
          branch. Offer to free it and resume whichever action hit it. Lives outside the menu so it
          shows even when the primary prep-to-merge button triggered it. */}
      <Show when={heldAt()}>
        <span class="nh-held">
          held in {heldAt()}
          <button class="nh-held-btn" disabled={busy()} onClick={freeAndContinue}>
            free &amp; {heldFor() === "prepMerge" ? "prep" : "checkout"}
          </button>
          <button class="nh-held-btn" onClick={() => setHeldAt(null)}>cancel</button>
        </span>
      </Show>

      {/* ⋯ menu — the rarer branch actions (view-only checkout, pre-push gates), collapsed off
          the header. The merge-prep workflow is the primary button above. */}
      <button
        class="icon-btn"
        classList={{ on: open() }}
        aria-haspopup="true"
        aria-expanded={open()}
        title="branch actions — checkout, pre-push gates"
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

          {/* overrides — the old first-class buttons live here now (design.md: two buttons) */}
          <Show when={!isReview()}>
            <button
              class="nh-item"
              role="menuitem"
              disabled={busy() || behind() === 0}
              title="rebase this branch forward onto origin/main — lands instantly when clean, ejects to Claude on a conflict; a stacked or open-PR branch is refused with the reason"
              onClick={fire(() => rebase.mutate())}
            >
              <span class="nh-item-ic">⟳</span>
              {rebase.isPending ? "restacking…" : behind() === 0 ? "on origin/main ✦" : `restack · ${behind()} behind`}
            </button>
            <button
              class="nh-item"
              role="menuitem"
              disabled={busy()}
              title="prep to merge — move your main checkout onto this branch, then squash all unpushed commits into one voiced commit"
              onClick={() => trigger("prepMerge", () => { setOpen(false); prepMerge.mutate(false); })}
            >
              <span class="nh-item-ic">↧</span>
              {prepMerge.isPending ? "prepping…" : armed() === "prepMerge" ? "confirm prep to merge" : "prep to merge (checkout)"}
            </button>
            <button
              class="nh-item"
              role="menuitem"
              disabled={reconcile.isPending}
              title="eject a standalone Claude in this branch's worktree to work out the source of truth on a divergence — no force-push, no blind pull"
              onClick={() => reconcile.mutate()}
            >
              <span class="nh-item-ic">⚖</span>
              {reconcile.isPending ? "ejecting…" : "reconcile divergence"}
            </button>
            <button
              class="nh-item"
              role="menuitem"
              title="the full push card — the crossing, wards, and remote (phone) surface of the same flow"
              onClick={() => {
                setOpen(false);
                navigate({ kind: "push", branch: props.branch });
              }}
            >
              <span class="nh-item-ic">⤢</span> open the push card
            </button>
          </Show>

          {/* worktree reveal — demoted here from the work-tab rows (telemetry trim) */}
          <button
            class="nh-item"
            role="menuitem"
            disabled={worktree.isPending}
            title="reveal this branch's worktree in Finder — materialises a scratch one if it's checked out nowhere"
            onClick={fire(() => worktree.mutate())}
          >
            <span class="nh-item-ic">⌂</span>
            {worktree.isPending ? "revealing…" : "reveal worktree"}
          </button>

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
