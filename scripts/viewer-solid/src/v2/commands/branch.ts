// A branch's way to main: push it (POST /push-origin — two keypresses, never by itself), open its
// PR (the compare form, prefilled by /packet-compare, in Phil's browser), open its page, and hold
// work for the morning (POST /outbox-hold). Nothing here pushes, opens or merges on its own.
import { createSignal } from "solid-js";
import { atRepo, bkey, compareUrl, model, type BranchView } from "../model";
import { command, type Write } from "../registry";
import { navigate, reviewPath, surface } from "../router";
import { canPush, fmtMorning, leaf, nextMorning, pushableButGates } from "../ship";
import { view, world } from "../store";
import { getJSON } from "../sync";
import { armed, forestFace, launching, now, setArmed, setCursor, setDescribing, setOpened, toggleIn } from "../ui";

const bv = (id: string | undefined) => (id ? model.branchView(id) : undefined);

command({
  id: "branch.push",
  label: "push",
  title: "Push to origin",
  scope: "branch",
  budget: "local",
  keys: ["p"],
  route: (id) => pushRoute(id),
});

/** What `p` does: arm, then send — or, when only the gates stand in the way, run them. A branch
 *  diverged from origin can't push; inside the force scope `p` arms a force-with-lease instead. */
export function pushRoute(id: string | undefined): string | null {
  const v = bv(id);
  if (!v) return null;
  if (v.b.diverged) {
    const s = forceScopeOf(id);
    if (!s || v.b.pending) return null;
    if (s.eligible) return armed() === id ? "branch.force.confirm" : "branch.force.arm";
    if (!s.guards.every((g) => g.ok || g.k === "gates")) return null;
    return v.b.gates === "running" ? "branch.gates.wait" : "branch.gates.run";
  }
  if (canPush(v.b, v.pr)) return armed() === id ? "branch.push.confirm" : "branch.push.arm";
  if (!pushableButGates(v.b, v.pr)) return null;
  return v.b.gates === "running" ? "branch.gates.wait" : "branch.gates.run";
}
command({
  id: "branch.gates.run",
  label: "gates",
  title: "Run the push gates",
  scope: "branch",
  budget: "local",
  quiet: true,
  available: (id) => !!bv(id) && bv(id)!.b.gates !== "running",
  write: (id): Write | null => {
    const v = bv(id);
    if (!v) return null;
    return {
      ops: [{ type: "branch", id, fields: { gates: "running" } }],
      path: atRepo(v.b.repo, "/gates"),
      body: { branch: v.b.name, detach: true },
      settled: () => world.entities.branch[id]?.gates !== v.b.gates,
      said: "running the gates — p pushes once they're green",
      failed: "the gates didn't start",
    };
  },
});
/** The gate whose output the strip shows instead of the running one's — "<branch id> <gate>". */
export const [gateShown, setGateShown] = createSignal<string | null>(null);
command({
  id: "branch.gates.show",
  title: "Show a gate's output in the gates strip (again to go back to the running one)",
  scope: "branch",
  budget: "local",
  quiet: true,
  local: (target) => setGateShown((cur) => (cur === target ? null : target!)),
});
command({
  id: "branch.gates.skip",
  title: "Skip a red gate for this code and re-run the rest",
  scope: "branch",
  budget: "local",
  quiet: true,
  write: (target): Write | null => {
    const [id, list] = target.split(" ");
    const v = bv(id);
    const skip = (list ?? "").split(",").filter(Boolean);
    if (!v || !skip.length) return null;
    return {
      ops: [{ type: "branch", id, fields: { gates: "running" } }],
      path: atRepo(v.b.repo, "/gates"),
      body: { branch: v.b.name, detach: true, skip },
      settled: () => world.entities.branch[id]?.gates !== v.b.gates,
      said: `skipping ${skip.join(", ")} for this code — the rest re-run`,
      failed: "the gates didn't start",
    };
  },
});
command({
  id: "branch.gates.wait",
  title: "The gates are running",
  scope: "branch",
  budget: "local",
  quiet: true,
  local: () => {
    throw new Error("the gates are running — p pushes once they're green");
  },
});
command({
  id: "branch.push.arm",
  title: "Ready a push (the next press sends it)",
  scope: "branch",
  budget: "local",
  quiet: true,
  available: (id) => !!bv(id) && canPush(bv(id)!.b, bv(id)!.pr),
  local: (id) => setArmed(id),
});
command({
  id: "branch.push.confirm",
  title: "Send the readied push",
  scope: "branch",
  budget: "git-write",
  quiet: true,
  v1: ["push-origin"],
  available: (id) => !!id && armed() === id,
  write: (id): Write | null => {
    const v = bv(id);
    setArmed(undefined);
    if (!v) return null;
    return {
      ops: [{ type: "branch", id, fields: { pending: "pushing" } }],
      path: atRepo(v.b.repo, "/push-origin"),
      body: { branch: v.b.name, stay: true },
      settled: () => world.entities.branch[id]?.pushed === "synced",
      said: v.pr ? `pushed ${v.b.ahead} follow-up${v.b.ahead === 1 ? "" : "s"} onto #${v.pr.number}` : undefined,
      failed: `${leaf(v.b.name)} didn't push`,
    };
  },
});

// ── the one sanctioned force: replace origin's copy while nobody else has read it ──

export interface Guard {
  k: string;
  label: string;
  ok: boolean;
}
/** GET /force-scope (srv/sync.py force_scope): no PR, or a draft no one else has
 *  touched, and gates green on this tree. /force-origin checks it all again; this only says. */
export interface ForceScope {
  eligible: boolean;
  guards: Guard[];
  lease: string;
  prNumber: number | null;
  prUrl: string | null;
}

const scopeKey = (id: string) => {
  const b = view("branch", id);
  return b ? `${b.tip}|${b.ahead}|${b.gates}` : "";
};
const [scopes, setScopes] = createSignal<ReadonlyMap<string, { key: string; scope?: ForceScope | null }>>(new Map());
const putScope = (id: string, key: string, scope?: ForceScope | null) => setScopes((m) => new Map(m).set(id, { key, scope }));
/** The force scope read for this tip — undefined until read, null when it couldn't be. */
export function forceScopeOf(id: string | undefined): ForceScope | null | undefined {
  const s = id ? scopes().get(id) : undefined;
  return s && s.key === scopeKey(id!) ? s.scope : undefined;
}
/** Read the scope once per tip (it asks GitHub, so never on a poll). A run's green shows in /state
 *  a moment before its verdict lands in git config, which is what the scope reads — so a gates ✗
 *  under green gates is read again, a few times. */
export function readForceScope(id: string, tries = 0): void {
  const b = view("branch", id);
  const key = scopeKey(id);
  if (!b || (!tries && scopes().get(id)?.key === key)) return;
  if (!tries) putScope(id, key);
  void getJSON<{ forceScope?: ForceScope }>(atRepo(b.repo, `/force-scope?branch=${encodeURIComponent(b.name)}`))
    .then((d) => {
      if (scopeKey(id) !== key) return;
      putScope(id, key, d.forceScope ?? null);
      const early = b.gates === "green" && d.forceScope?.guards.some((g) => g.k === "gates" && !g.ok);
      if (early && tries < 4) window.setTimeout(() => readForceScope(id, tries + 1), 1000 * (tries + 1));
    })
    .catch(() => putScope(id, key, null));
}

command({
  id: "branch.force.arm",
  title: "Ready a force-with-lease over origin (the next press sends it)",
  scope: "branch",
  budget: "local",
  quiet: true,
  available: (id) => !!bv(id)?.b.diverged && !!forceScopeOf(id)?.eligible,
  local: (id) => setArmed(id),
});
command({
  id: "branch.force.confirm",
  title: "Send the readied force-with-lease",
  scope: "branch",
  budget: "git-write",
  quiet: true,
  v1: ["force-origin"],
  available: (id) => !!id && armed() === id && !!forceScopeOf(id)?.eligible,
  write: (id): Write | null => {
    const v = bv(id);
    const s = forceScopeOf(id);
    setArmed(undefined);
    if (!v || !s) return null;
    const key = scopeKey(id);
    return {
      ops: [{ type: "branch", id, fields: { pending: "pushing" } }],
      path: atRepo(v.b.repo, "/force-origin"),
      body: { branch: v.b.name, lease: s.lease },
      settled: () => !world.entities.branch[id]?.diverged,
      said: `replaced origin's ${s.lease.slice(0, 7)}`,
      failed: `${leaf(v.b.name)} didn't replace origin`,
      answered: (_ok, body) => {
        if (body.forceScope) putScope(id, key, body.forceScope as ForceScope);
      },
    };
  },
});

/** In a launch, the next node with a step left after `id` — where the cursor goes once this one's done. */
function advance(after: BranchView): void {
  const f = model.forests().get(after.b.project);
  if (!f || launching() !== after.b.project) return;
  const i = f.unopened.findIndex((v) => v.b.id === after.b.id);
  const next = f.unopened.slice(i + 1)[0];
  if (next) setCursor(bkey(next.b.id));
}

command({
  id: "branch.pr",
  label: "pr",
  title: "Go to the PR (the prefilled compare form if there's none yet)",
  scope: "branch",
  budget: "local",
  keys: ["g h"],
  v1: ["open-pr"],
  available: (id) => bv(id)?.st.action === "pr",
  local: (id) => {
    const v = bv(id)!;
    window.open(v.pr?.url ?? compareUrl(v), "_blank", "noopener");
    if (!v.pr) {
      setOpened((s) => toggleIn(s, v.b.id, true));
      advance(v);
    }
  },
});

command({
  id: "branch.preview",
  label: "preview",
  title: "Preview it — a dev server on a side port, opened once it answers",
  scope: "branch",
  budget: "local",
  keys: ["g p"],
  v1: ["node.preview"],
  available: (id) => !!bv(id),
  local: (id) => {
    const b = bv(id)!.b;
    window.open(`${atRepo(b.repo, "/preview-wait")}?branch=${encodeURIComponent(b.name)}`, "_blank", "noopener");
  },
});

command({
  id: "branch.open",
  label: "open",
  title: "Open the branch",
  scope: "branch",
  budget: "local",
  keys: ["l", "right"],
  available: (id) => !!bv(id),
  local: (id, e) => navigate(reviewPath(bv(id)!.b.repo, bv(id)!.b.name), e),
});

// ── its description: the branch's one human line ──

/** The description as the server stores it: one line, runs of space folded (srv/outline.py). */
export const oneLine = (s: string) => s.split(/\s+/).filter(Boolean).join(" ");

command({
  id: "branch.describe",
  title: "Save the branch's description",
  scope: "global",
  budget: "config-write",
  quiet: true,
  write: (id, arg): Write | null => {
    const b = view("branch", id);
    const next = oneLine(String(arg ?? ""));
    if (!b || next === b.description) return null;
    const before = b.description;
    return {
      ops: [{ type: "branch", id, fields: { description: next } }],
      path: atRepo(b.repo, "/outline"),
      body: { branch: b.name, edits: [], description: next },
      settled: () => world.entities.branch[id]?.description === next,
      said: "description saved · u undoes",
      failed: "couldn't save the description",
      inverse: { id: "branch.describe", target: id, arg: before },
    };
  },
});
command({
  id: "branch.describe.edit",
  label: "describe",
  title: "Edit the branch's description in place",
  scope: "branch",
  budget: "local",
  keys: ["i"],
  available: (id) => surface().id === "forest" && forestFace() === "branches" && !!bv(id),
  local: (id) => setDescribing(id),
});

// ── holding work for the morning ──

/** What a hold on this row covers: the branch, or every branch of the forest not yet on GitHub. */
function holdable(row: string | undefined): BranchView[] {
  if (!row) return [];
  if (row.startsWith("b:")) {
    const v = bv(row.slice(2));
    return v && !v.pr && v.st.ship !== "landed" && v.b.commits > 0 ? [v] : [];
  }
  return (model.forests().get(row.slice(2))?.unopened ?? []).filter((v) => v.b.commits > 0);
}

function holdWrite(row: string, ids: string[], until: string | null): Write | null {
  if (!ids.length) return null;
  const repo = view("branch", ids[0])!.repo;
  const names = ids.map((id) => view("branch", id)!.name);
  const what = ids.length === 1 ? leaf(names[0]) : `${ids.length} branches`;
  return {
    ops: ids.map((id) => ({ type: "branch" as const, id, fields: { holdUntil: until } })),
    path: atRepo(repo, "/outbox-hold"),
    body: { branches: names, until: until ?? "" },
    settled: () => ids.every((id) => (world.entities.branch[id]?.holdUntil ?? null) === until),
    said: until ? `holding ${what} for ${fmtMorning(Date.parse(until))} — u lets go` : undefined,
    failed: until ? `couldn't hold ${what}` : `couldn't release ${what}`,
    inverse: until ? { id: "hold.release", target: row, arg: ids } : { id: "hold.morning", target: row, arg: ids },
  };
}

command({
  id: "hold.morning",
  label: "hold",
  title: "Hold for the morning",
  scope: "row",
  budget: "config-write",
  keys: ["b"],
  v1: ["outbox-hold"],
  available: (row) => holdable(row).some((v) => !v.b.holdUntil),
  write: (row, arg) => {
    const ids = Array.isArray(arg) ? (arg as string[]) : holdable(row).filter((v) => !v.b.holdUntil).map((v) => v.b.id);
    return holdWrite(row, ids, new Date(nextMorning(now())).toISOString());
  },
});
command({
  id: "hold.release",
  label: "unhold",
  title: "Release the hold",
  scope: "row",
  budget: "config-write",
  keys: ["B"],
  available: (row) => holdable(row).some((v) => v.b.holdUntil),
  write: (row, arg) => {
    const ids = Array.isArray(arg) ? (arg as string[]) : holdable(row).filter((v) => v.b.holdUntil).map((v) => v.b.id);
    return holdWrite(row, ids, null);
  },
});
