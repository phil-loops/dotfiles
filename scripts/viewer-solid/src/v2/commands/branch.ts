// A branch's way to main: push it (POST /push-origin — two keypresses, never by itself), open its
// PR (the compare form, prefilled by /packet-compare, in Phil's browser), open its page, and hold
// work for the morning (POST /outbox-hold). Nothing here pushes, opens or merges on its own.
import { atRepo, bkey, branchPage, compareUrl, model, type BranchView } from "../model";
import { command, type Write } from "../registry";
import { leave } from "../router";
import { fmtMorning, leaf, nextMorning } from "../ship";
import { view, world } from "../store";
import { armed, launching, now, setArmed, setCursor, setOpened, toggleIn } from "../ui";

const bv = (id: string | undefined) => (id ? model.branchView(id) : undefined);

command({
  id: "branch.push",
  title: "Push to origin",
  scope: "branch",
  budget: "local",
  keys: ["p"],
  route: (id) => {
    const v = bv(id);
    if (!v || v.st.action !== "push" || v.b.pending) return null;
    return armed() === id ? "branch.push.confirm" : "branch.push.arm";
  },
});
command({
  id: "branch.push.arm",
  title: "Ready a push (the next press sends it)",
  scope: "branch",
  budget: "local",
  quiet: true,
  available: (id) => bv(id)?.st.action === "push",
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
      failed: `${leaf(v.b.name)} didn't push`,
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
  title: "Open the PR (the prefilled compare form if there's none yet)",
  scope: "branch",
  budget: "local",
  keys: ["P"],
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
  id: "branch.open",
  title: "Open the branch",
  scope: "branch",
  budget: "local",
  keys: ["l", "right"],
  available: (id) => !!bv(id),
  local: (id) => leave(branchPage(bv(id)!.b)),
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
  title: "Hold for the morning",
  scope: "row",
  budget: "config-write",
  keys: ["z"],
  v1: ["outbox-hold"],
  available: (row) => holdable(row).some((v) => !v.b.holdUntil),
  write: (row, arg) => {
    const ids = Array.isArray(arg) ? (arg as string[]) : holdable(row).filter((v) => !v.b.holdUntil).map((v) => v.b.id);
    return holdWrite(row, ids, new Date(nextMorning(now())).toISOString());
  },
});
command({
  id: "hold.release",
  title: "Release the hold",
  scope: "row",
  budget: "config-write",
  keys: ["Z"],
  available: (row) => holdable(row).some((v) => v.b.holdUntil),
  write: (row, arg) => {
    const ids = Array.isArray(arg) ? (arg as string[]) : holdable(row).filter((v) => v.b.holdUntil).map((v) => v.b.id);
    return holdWrite(row, ids, null);
  },
});
