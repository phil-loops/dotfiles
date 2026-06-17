// NodeActions — the two node-level "do something to this branch" affordances that
// live in NodeDetail's node-head: move the main checkout (~/coding/loops) onto this
// branch, and squash parent..branch into one voiced commit. Both are SECONDARY
// actions, so they wear --patina (stale/tarnished green), never gold — gold is
// reserved for blessed work. This component owns its own wiring + styling so it can
// drop into App.tsx with a single import + mount line (no shared lines).
//
//   <NodeActions branch={active()} />
//
// Endpoints (Python review server, unchanged):
//   POST /checkout {branch, force?}  → {ok} | 409 {ok:false, worktree} when another
//                                       worktree holds the branch (force:true frees it)
//   POST /squash   {branch}          → {ok, n, sha, header, voiced, …}  (stack-squash)
import { createSignal, Show } from "solid-js";
import { createMutation, createQuery, useQueryClient } from "@tanstack/solid-query";
import { fetchJSON } from "./api";

interface CheckoutResult {
  ok?: boolean;
  err?: string;
  worktree?: string; // set on 409: the worktree currently holding the branch
}

interface SquashResult {
  ok?: boolean;
  n?: number; // commits collapsed
  sha?: string; // new short sha
  header?: string; // the voiced subject line
  err?: string;
}

interface SyncState {
  behind: number; // commits on origin/main not in this branch
  syncable: boolean; // safe to rebase onto origin/main with no force-push (unpublished root)
  why: string; // when not syncable, why (stacked / published / up-to-date)
  deployCritical?: string[]; // deploy-critical files changed on main → pre-push hook hard-fails
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

// patina-tinted secondary button; gold stays the sole property of blessed.
const btn = {
  font: "inherit",
  "font-size": "12px",
  color: "var(--patina)",
  background: "transparent",
  border: "1px solid var(--patina)",
  "border-radius": "5px",
  padding: "3px 9px",
  cursor: "pointer",
  opacity: "0.85",
} as const;

const note = {
  "font-size": "12px",
  color: "var(--patina)",
  opacity: "0.9",
} as const;

export function NodeActions(props: { branch: string }) {
  const qc = useQueryClient();
  // 409 stash: the worktree holding the branch, awaiting a force-confirm.
  const [heldAt, setHeldAt] = createSignal<string | null>(null);
  // squash is history-rewriting → two-click arm before it fires.
  const [armed, setArmed] = createSignal(false);
  let armT: ReturnType<typeof setTimeout>;
  // transient success line ("✓ …"), cleared on the next node.
  const [done, setDone] = createSignal<string | null>(null);

  const checkout = createMutation(() => ({
    mutationFn: (force: boolean) =>
      post<CheckoutResult>("/checkout", { branch: props.branch, force }),
    onSuccess: (r) => {
      if (r.ok) {
        setHeldAt(null);
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
      setArmed(false);
      if (r.ok) {
        setDone(`✓ squashed ${r.n ?? ""} → ${r.sha ?? ""} ${r.header ?? ""}`.trim());
        qc.invalidateQueries({ queryKey: ["commits", props.branch] });
        qc.invalidateQueries({ queryKey: ["node", props.branch] });
        qc.invalidateQueries({ queryKey: ["model"] });
      } else {
        setDone(`✗ ${r.err || "squash failed"}`);
      }
    },
    onError: (e) => {
      setArmed(false);
      setDone(`✗ ${(e as Error).message || "squash failed"}`);
    },
  }));

  const armSquash = () => {
    if (armed()) {
      squash.mutate();
      return;
    }
    setArmed(true);
    clearTimeout(armT);
    armT = setTimeout(() => setArmed(false), 4000); // disarm if not confirmed
  };

  // branch state vs origin/main — drives the "N behind / push blocked" badge + rebase.
  const sync = createQuery(() => ({
    queryKey: ["sync", props.branch],
    queryFn: () =>
      fetchJSON<SyncState>("/sync?branch=" + encodeURIComponent(props.branch)),
    enabled: !!props.branch,
  }));
  const behind = () => sync.data?.behind ?? 0;
  const critical = () => sync.data?.deployCritical ?? [];
  const blocked = () => critical().length > 0; // the pre-push hook hard-fails on these

  const rebase = createMutation(() => ({
    mutationFn: () =>
      post<{ ok?: boolean; err?: string }>("/sync", { branch: props.branch }),
    onSuccess: (r) => {
      if (r.ok) {
        setDone("✓ rebased onto origin/main");
        sync.refetch();
        qc.invalidateQueries({ queryKey: ["model"] });
        qc.invalidateQueries({ queryKey: ["node", props.branch] });
      } else {
        // 409 = not syncable (stacked/published) — show the server's reason
        setDone(`✗ ${r.err || "rebase failed"}`);
      }
    },
    onError: (e) => setDone(`✗ ${(e as Error).message || "rebase failed"}`),
  }));

  const busy = () => checkout.isPending || squash.isPending || rebase.isPending;

  return (
    <div class="node-actions" style={{ display: "flex", "align-items": "center", gap: "8px" }}>
      {/* branch state vs origin/main: behind count, push-blocking deploy-critical files, rebase */}
      <Show when={behind() > 0}>
        <span
          style={blocked() ? { ...note, opacity: "1", "font-weight": "600" } : note}
          title={
            blocked()
              ? `push BLOCKED by the pre-push hook — origin/main changed deploy-critical files you're missing:\n${critical().join("\n")}\n\nrebase onto origin/main to clear it`
              : `${behind()} commit(s) on origin/main not yet in this branch`
          }
        >
          {blocked() ? "⚠" : "↓"} {behind()} behind{blocked() ? " · push blocked" : ""}
        </span>
        <Show
          when={sync.data?.syncable}
          fallback={
            <span style={note} title={sync.data?.why}>
              ({sync.data?.why})
            </span>
          }
        >
          <button
            style={btn}
            disabled={busy()}
            title="git rebase origin/main onto this branch"
            onClick={() => {
              setDone(null);
              rebase.mutate();
            }}
          >
            {rebase.isPending ? "rebasing…" : "⟳ rebase onto main"}
          </button>
        </Show>
      </Show>

      {/* checkout — move the primary working tree onto this branch */}
      <Show
        when={heldAt()}
        fallback={
          <button
            style={btn}
            disabled={busy()}
            title="move your main checkout (~/coding/loops) onto this branch"
            onClick={() => {
              setDone(null);
              checkout.mutate(false);
            }}
          >
            {checkout.isPending ? "checking out…" : "⤓ checkout here"}
          </button>
        }
      >
        <span style={note}>open in {heldAt()} —</span>
        <button style={btn} disabled={busy()} onClick={() => checkout.mutate(true)}>
          free &amp; checkout
        </button>
        <button style={{ ...btn, border: "1px solid transparent" }} onClick={() => setHeldAt(null)}>
          cancel
        </button>
      </Show>

      {/* squash — collapse parent..branch into one voiced commit (two-click) */}
      <button
        style={armed() ? { ...btn, opacity: "1", "border-color": "var(--patina)" } : btn}
        disabled={busy()}
        title="collapse parent..branch into one commit with a generated subject"
        onClick={() => {
          setDone(null);
          armSquash();
        }}
      >
        {squash.isPending ? "squashing…" : armed() ? "confirm squash" : "⊟ squash → 1"}
      </button>

      <Show when={done()}>
        <span style={note}>{done()}</span>
      </Show>
    </div>
  );
}
