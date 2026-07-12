import { createMutation, type QueryClient } from "@tanstack/solid-query";
import { withRepo } from "./provider";

// The per-node mutations: bless/unbless (optimistic via the caller's override map, snap back on
// error), interest bump, upstream detach, and scoped child reseat. Fed the active branch, the
// bless-override accessors, the query client, and a health refetch.
export function useNodeMutations(deps: {
  active: () => string;
  // ledger target when it differs from the display id — the ghost node passes its
  // resolved refs/stack/<project>-integration ref (stack-bless fans it out per branch;
  // the "~integration" sentinel is not a blessable ref).
  blessTarget?: () => string;
  blessOverride: () => Record<string, boolean>;
  setOverride: (file: string, val: boolean | undefined) => void;
  qc: QueryClient;
  refetchHealth: () => void;
}) {
  // a 500 from /bless still resolves fetch().json() — without this check the optimistic
  // tick survives a failed write and silently evaporates on the next visit.
  const okOrThrow = async (r: Response) => {
    const j = await r.json().catch(() => ({}));
    if (!r.ok || j.ok === false) { throw new Error(j.err || `bless failed (${r.status})`); }
    return j;
  };
  const blessRef = () => (deps.blessTarget ?? deps.active)();
  const bless = createMutation(() => ({
    mutationFn: (file: string) =>
      fetch(withRepo("/bless"), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ branch: blessRef(), file }),
      }).then(okOrThrow),
    onMutate: (file: string) => { const prev = deps.blessOverride()[file]; deps.setOverride(file, true); return { file, prev }; },
    onError: (_e, _file, ctx) => { if (ctx) { deps.setOverride(ctx.file, ctx.prev); } },
  }));

  const unbless = createMutation(() => ({
    mutationFn: (file: string) =>
      fetch(withRepo("/bless"), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ branch: blessRef(), file, unbless: true }),
      }).then(okOrThrow),
    onMutate: (file: string) => { const prev = deps.blessOverride()[file]; deps.setOverride(file, false); return { file, prev }; },
    onError: (_e, _file, ctx) => { if (ctx) { deps.setOverride(ctx.file, ctx.prev); } },
  }));

  // promote/demote this forest's manual interest level — orders it on the Forests home.
  const bumpInterest = createMutation(() => ({
    mutationFn: (arg: { project: string; delta: number }) =>
      fetch(withRepo("/interest"), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(arg),
      }).then((r) => r.json()),
    onSuccess: () => {
      deps.qc.invalidateQueries({ queryKey: ["model"] });
      deps.qc.invalidateQueries({ queryKey: ["projects"] });
    },
  }));

  // neutralize a footgun tracking ref (renamed/foreign remote or origin/main) by unsetting
  // it — config-only, keeps every commit; GitHub Desktop then offers Publish, not a Pull.
  const detachUpstream = createMutation(() => ({
    mutationFn: (branch: string) =>
      fetch("/fix-upstream", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ branch }),
      }).then((r) => r.json()),
    onSuccess: () => deps.refetchHealth(),
  }));

  // scoped reseat for a drifted node: rebase the parent's off-tip children (this node and any
  // orphaned siblings, recursively) back onto the parent's current tip — nothing else moves,
  // unlike a full restack. Local only; conflicts leave that subtree parked for a manual pass.
  const reseatChildren = createMutation(() => ({
    mutationFn: (parent: string) =>
      fetch("/reseat-children", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ branch: parent }),
      }).then((r) => r.json() as Promise<{ ok: boolean; moved: string[]; conflicts: { branch: string; err: string }[] }>),
    onSuccess: () => {
      deps.refetchHealth();
      deps.qc.invalidateQueries({ queryKey: ["model"] }); // children's SHAs moved — diffs are stale
    },
  }));
  return { bless, unbless, bumpInterest, detachUpstream, reseatChildren };
}
