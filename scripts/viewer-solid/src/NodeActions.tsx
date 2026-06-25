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
import { provider, canMutate } from "./provider";
import { useArm } from "./actions";
import { useViewerLocation } from "./router";

interface CheckoutResult {
  ok?: boolean;
  err?: string;
  worktree?: string; // set on 409: the worktree currently holding the branch
}

interface SquashResult {
  ok?: boolean;
  n?: number; // commits collapsed into the working tree
  unstaged?: boolean; // changes left unstaged for GitHub Desktop (no commit)
  err?: string;
}

async function post<T>(url: string, body: unknown): Promise<T> {
  const r = await fetch(url, {
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

export function NodeActions(props: { branch: string; isReview: boolean }) {
  if (!canMutate) return null; // static snapshot: no rebase/checkout/squash actions
  const qc = useQueryClient();
  const { navigate } = useViewerLocation();
  // 409 stash: the worktree holding the branch, awaiting a force-confirm.
  const [heldAt, setHeldAt] = createSignal<string | null>(null);
  // squash is history-rewriting → two-click arm (shared useArm) before it fires.
  const { armed, trigger } = useArm(4000);
  // transient result line ("✓ …" / "✗ …"), cleared on the next action.
  const [done, setDone] = createSignal<string | null>(null);
  // /sync found the branch already merged into main — children awaiting a drop+rewire confirm.
  const [contractKids, setContractKids] = createSignal<string[] | null>(null);
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
        setDone(`✓ checked out in ~/coding/loops`);
        qc.invalidateQueries({ queryKey: ["head"] });
      } else if (r.worktree) {
        setHeldAt(r.worktree); // held elsewhere → offer to free it
      } else {
        setDone(`✗ ${r.err || "checkout failed"}`);
      }
    },
    onError: (e) => setDone(`✗ ${(e as Error).message || "checkout failed"}`),
  }));

  const squash = createMutation(() => ({
    mutationFn: () => post<SquashResult>("/squash", { branch: props.branch }),
    onSuccess: (r) => {
      setOpen(false);
      if (r.ok) {
        const n = r.n ?? 0;
        setDone(`✓ uncommitted ${n} commit${n === 1 ? "" : "s"} — unstaged for GitHub Desktop`);
        qc.invalidateQueries({ queryKey: ["commits", props.branch] });
        qc.invalidateQueries({ queryKey: ["node", props.branch] });
        qc.invalidateQueries({ queryKey: ["model"] });
        qc.invalidateQueries({ queryKey: ["head"] });
      } else {
        setDone(`✗ ${r.err || "squash failed"}`);
      }
    },
    onError: (e) => setDone(`✗ ${(e as Error).message || "squash failed"}`),
  }));

  // fork-state vs origin/main — read-only, drives the "behind / push blocked" badge.
  const sync = createQuery(() => ({
    queryKey: ["sync", props.branch],
    queryFn: () => provider.sync(props.branch),
    enabled: !!props.branch,
  }));
  const behind = () => sync.data?.behind ?? 0;
  const critical = () => sync.data?.deployCritical ?? [];
  const blocked = () => critical().length > 0;

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
      } else if (r.contract) {
        const kids = r.children ?? [];
        setContractKids(kids);
        setDone(`● already merged into origin/main — drop it & rewire ${kids.length} child${kids.length === 1 ? "" : "ren"} onto main?`);
      } else if (r.conflict) {
        setDone("✓ conflict — Claude is resolving it in a worktree");
      } else {
        setDone("✓ rebasing on main — Claude is on it in a worktree");
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

  const busy = () => checkout.isPending || squash.isPending || rebase.isPending || pull.isPending || contract.isPending;
  const fire = (fn: () => void) => () => {
    setDone(null);
    fn();
  };

  return (
    <div class="node-actions" ref={root}>
      {/* fork-state vs origin/main — calm "behind", escalating to ember "push blocked" when
          main changed deploy-critical files this branch lacks (what the pre-push hook rejects).
          When blocked the fix (rebase forward) surfaces inline next to the alarm; the full
          list of missing files lives in the tooltip rather than spread across the header. */}
      <Show when={behind() > 0}>
        <Show
          when={blocked()}
          fallback={<span class="nh-behind">↓ {behind()} behind</span>}
        >
          <span
            class="nh-blocked"
            title={`origin/main changed deploy-critical files this branch is missing:\n${critical().join("\n")}\n\nrebase forward to clear the push block`}
          >
            ⚠ push blocked
          </span>
        </Show>
      </Show>

      {/* rebase onto origin/main — first-class + always visible (not just when behind, not buried
          in ⋯). Disabled, reading "on origin/main", once current. Hidden on review nodes (there
          "pull to their state" is the move). The /sync gate still refuses a stacked / open-PR
          branch and explains why in the result line. */}
      <Show when={!isReview()}>
        <button
          class="nh-fix"
          disabled={busy() || behind() === 0}
          title={
            behind() === 0
              ? "already up to date with origin/main"
              : "rebase this branch forward onto origin/main — lands instantly when clean, ejects to Claude on a conflict (never your main checkout); a stacked or open-PR branch is refused with the reason"
          }
          onClick={fire(() => rebase.mutate())}
        >
          {rebase.isPending ? "rebasing…" : behind() === 0 ? "✦ on origin/main" : "⟳ rebase onto main"}
        </button>
      </Show>

      {/* already-merged: /sync found this branch's work squash-merged to main, so a forward
          rebase replays nothing. Offer the contraction (drop + rewire children) instead of a
          Claude grinding the empty-rebase conflict. */}
      <Show when={contractKids()}>
        {(kids) => (
          <button
            class="nh-fix"
            disabled={busy()}
            title={`this branch's work already merged into origin/main — drop the empty branch and rewire its ${kids().length} child${kids().length === 1 ? "" : "ren"} onto main (forest contraction)`}
            onClick={fire(() => contract.mutate())}
          >
            {contract.isPending ? "contracting…" : `drop & rewire ${kids().length} →`}
          </button>
        )}
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

      {/* ⋯ menu — the three rare, history-touching mutations, collapsed off the header */}
      <button
        class="icon-btn"
        classList={{ on: open() }}
        aria-haspopup="true"
        aria-expanded={open()}
        title="branch actions — checkout, squash"
        onClick={() => setOpen((o) => !o)}
      >
        ⋯
      </button>

      <Show when={open()}>
        <div class="nh-menu" role="menu">
          {/* checkout — move the primary working tree onto this branch */}
          <Show
            when={heldAt()}
            fallback={
              <button
                class="nh-item"
                role="menuitem"
                disabled={busy()}
                title="move your main checkout (~/coding/loops) onto this branch"
                onClick={fire(() => checkout.mutate(false))}
              >
                <span class="nh-item-ic">⤓</span>
                {checkout.isPending ? "checking out…" : "checkout here"}
              </button>
            }
          >
            <div class="nh-item-note">held in {heldAt()}</div>
            <button class="nh-item" role="menuitem" disabled={busy()} onClick={() => checkout.mutate(true)}>
              <span class="nh-item-ic">⤓</span> free &amp; checkout
            </button>
            <button class="nh-item" role="menuitem" onClick={() => setHeldAt(null)}>
              <span class="nh-item-ic" /> cancel
            </button>
          </Show>

          {/* squash & unstage — collapse parent..branch into unstaged working-tree changes,
              no commit, so you write the commit in GitHub Desktop (two-click: rewrites history) */}
          <button
            class="nh-item"
            classList={{ armed: armed() === "squash" }}
            role="menuitem"
            disabled={busy()}
            title="collapse parent..branch into unstaged working-tree changes (no commit) — commit it in GitHub Desktop"
            onClick={fire(() => trigger("squash", () => squash.mutate()))}
          >
            <span class="nh-item-ic">⊟</span>
            {squash.isPending ? "unstaging…" : armed() === "squash" ? "confirm squash & unstage" : "squash & unstage"}
          </button>

          {/* prepare to push — the mobile card: squash unpushed → run gates → FF push.
              Not for review nodes (those track someone else's PR — you don't push it). */}
          <Show when={!isReview()}>
            <button
              class="nh-item"
              role="menuitem"
              title="open the prepare-to-push card: squash unpushed → run gates → fast-forward push to a safe remote"
              onClick={() => {
                setOpen(false);
                navigate({ kind: "push", branch: props.branch });
              }}
            >
              <span class="nh-item-ic">↑</span> prepare to push
            </button>
          </Show>

        </div>
      </Show>

      <Show when={done()}>
        <span class="nh-done" title={done() ?? ""}>{done()}</span>
      </Show>
    </div>
  );
}
