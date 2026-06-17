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
import { createMutation, useQueryClient } from "@tanstack/solid-query";

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

async function post<T>(url: string, body: unknown): Promise<T> {
  const r = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  // /checkout answers 409 with a JSON body (held elsewhere) — read it either way.
  return (await r.json()) as T;
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

  const busy = () => checkout.isPending || squash.isPending;

  return (
    <div class="node-actions" style={{ display: "flex", "align-items": "center", gap: "8px" }}>
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
