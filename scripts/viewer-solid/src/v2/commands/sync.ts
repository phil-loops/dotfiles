// ⟲ sync — everything local that makes a branch pushable, in one motion and v1's order: a dirty
// tree is a decision (fold, stash or stop), a drifted branch is reseated on its parent, a branch
// behind main rebases (or its forest's restack is queued), the outgoing commits take one voiced
// shape (/prep-push), then the gates start detached and the related tests run as advice. A
// conflict or a divergence with no mechanical route goes to Claude — the server's own hand-offs
// (/sync ejects a headless rebase into the branch's worktree; /reconcile opens a Claude session
// there) — and the ship line says so. Each step is a registered command posted through the runner,
// so every one is measured; the motion only sequences them.
//
// Also here: the rare repairs, in the space menu only when they apply — reseat, detach a footgun
// upstream, inspect a divergence.
import { createSignal } from "solid-js";
import { atRepo, model } from "../model";
import { command, type Write } from "../registry";
import { dispatch, say } from "../runner";
import { view, world } from "../store";
import { getJSON } from "../sync";
import { leaf } from "../ship";
import { PHASE_WORD, planSteps, prepOf, rebaseOf, rebases, sealed, testsOf, type DirtRow, type Phase, type Step, type StepId, type StepState, type SyncFacts } from "../syncing";
import type { Via } from "../registry";
import { page as pg } from "../review/page";

export interface Motion {
  steps: Step[];
  phase: Phase;
  /** the dirty files the motion waits on a decision about */
  dirt?: { files: string[]; rows: DirtRow[]; worktree: string };
  stashed: boolean;
  /** the tip when it stopped — a hand-off to Claude reads as done once the tip moves */
  tip: string;
}

const [motions, setMotions] = createSignal<ReadonlyMap<string, Motion>>(new Map());
/** The branch's sync motion this page load, if one ran. */
export const motionOf = (id: string | undefined): Motion | undefined => (id ? motions().get(id) : undefined);
const put = (id: string, m: Motion | undefined) =>
  setMotions((all) => {
    const next = new Map(all);
    if (m) next.set(id, m);
    else next.delete(id);
    return next;
  });
const patch = (id: string, fn: (m: Motion) => Motion) => {
  const m = motions().get(id);
  if (m) put(id, fn(m));
};
const setStep = (id: string, step: StepId, state: StepState, note?: string) =>
  patch(id, (m) => ({
    ...m,
    steps: m.steps.map((s) => (s.id === step ? { ...s, state, note: note ?? s.note, t0: state === "run" ? (s.t0 ?? Date.now()) : s.t0 } : s)),
  }));
const setPhase = (id: string, phase: Phase) => patch(id, (m) => ({ ...m, phase }));
const running = (id: string | undefined) => {
  const p = motionOf(id)?.phase;
  return p === "running";
};

const bv = (id: string | undefined) => (id ? model.branchView(id) : undefined);
const facts = (repo: string, name: string) => getJSON<SyncFacts>(atRepo(repo, `/sync?branch=${encodeURIComponent(name)}`));

// ── one step: a registered write whose answer the motion waits for ──

type Answer = { ok: boolean; body: Record<string, unknown> };
interface StepArg {
  done?: (ok: boolean, body: Record<string, unknown>) => void;
  started?: boolean;
  [k: string]: unknown;
}

/** Post step `id` through the runner and resolve with the server's answer (a refusal before it
 *  sends resolves at once). */
function step(id: string, target: string, via: Via, extra: Record<string, unknown> = {}): Promise<Answer> {
  return new Promise((resolve) => {
    const arg: StepArg = { ...extra, done: (ok, body) => resolve({ ok, body }) };
    dispatch(id, via, { target, arg });
    if (!arg.started) resolve({ ok: false, body: { err: "refused before it was sent" } });
  });
}

/** A step's Write, wired so the motion hears its answer. */
function stepWrite(arg: unknown, w: Write): Write {
  const a = (arg ?? {}) as StepArg;
  a.started = true;
  return a.done ? { ...w, silent: true, answered: a.done } : w;
}

const nameOf = (id: string) => view("branch", id)!.name;
const repoOf = (id: string) => view("branch", id)!.repo;

command({
  id: "branch.sync.dirt",
  title: "Fold, stash or pop the uncommitted changes of the worktree holding the branch",
  scope: "branch",
  budget: "git-write",
  quiet: true,
  v1: ["dirty-resolve"],
  write: (id, arg) =>
    view("branch", id)
      ? stepWrite(arg, { ops: [], path: atRepo(repoOf(id), "/dirty-resolve"), body: { branch: nameOf(id), action: (arg as StepArg).action }, settled: () => true, failed: "the working tree didn't move" })
      : null,
});
command({
  id: "branch.sync.rebase",
  title: "Rebase it onto origin/main (or say its forest needs a restack)",
  scope: "branch",
  budget: "slow-io",
  quiet: true,
  v1: ["sync"],
  write: (id, arg) =>
    view("branch", id) ? stepWrite(arg, { ops: [], path: atRepo(repoOf(id), "/sync"), body: { branch: nameOf(id) }, settled: () => true, failed: "the rebase didn't run" }) : null,
});
command({
  id: "branch.sync.restack",
  title: "Queue its forest's restack onto origin/main",
  scope: "branch",
  budget: "git-write",
  quiet: true,
  v1: ["restack"],
  write: (id, arg) =>
    view("branch", id)
      ? stepWrite(arg, { ops: [], path: atRepo(repoOf(id), "/restack"), body: { project: (arg as StepArg).project }, settled: () => true, failed: "the restack didn't start" })
      : null,
});
command({
  id: "branch.sync.prep",
  title: "Shape the outgoing commits — seal placeholders into one voiced commit",
  scope: "branch",
  budget: "slow-io",
  quiet: true,
  v1: ["prep-push"],
  write: (id, arg) =>
    view("branch", id) ? stepWrite(arg, { ops: [], path: atRepo(repoOf(id), "/prep-push"), body: { branch: nameOf(id) }, settled: () => true, failed: "prep failed" }) : null,
});
command({
  id: "branch.sync.reconcile",
  title: "Hand a divergence with no mechanical route to Claude, in the branch's worktree",
  scope: "branch",
  budget: "slow-io",
  quiet: true,
  v1: ["reconcile"],
  write: (id, arg) =>
    view("branch", id) ? stepWrite(arg, { ops: [], path: atRepo(repoOf(id), "/reconcile"), body: { branch: nameOf(id) }, settled: () => true, failed: "Claude didn't start" }) : null,
});
command({
  id: "branch.sync.tests",
  title: "Run the tests related to the branch's changes (advisory)",
  scope: "branch",
  budget: "slow-io",
  quiet: true,
  v1: ["delta-tests"],
  write: (id, arg) =>
    view("branch", id)
      ? stepWrite(arg, { ops: [], path: atRepo(repoOf(id), "/delta-tests"), body: { branch: nameOf(id) }, settled: () => true, failed: "the tests didn't run", alone: true })
      : null,
});

// ── the motion ──

command({
  id: "branch.sync",
  label: "sync",
  title: "Sync — fold or stash dirt, reseat, rebase, shape the commits, then gates and tests",
  scope: "branch",
  budget: "local",
  keys: ["s"],
  v1: ["prep-push"],
  available: (id) => !!bv(id) && !!bv(id)!.b.tip && !running(id) && motionOf(id)?.phase !== "dirt",
  local: (id, e) => void start(id!, e instanceof MouseEvent ? "click" : "key"),
});
command({
  id: "review.sync",
  label: "sync",
  title: "Sync this branch — fold or stash dirt, reseat, rebase, shape the commits, then gates and tests",
  scope: "review",
  budget: "local",
  keys: ["s"],
  route: (id) => (id && bv(id) ? { id: "branch.sync", target: id } : null),
});

async function start(id: string, via: Via): Promise<void> {
  const b = view("branch", id)!;
  put(id, { steps: [{ id: "dirt", label: "working tree", state: "run", t0: Date.now() }], phase: "running", stashed: false, tip: b.tip });
  let f: SyncFacts;
  try {
    f = await facts(b.repo, b.name);
  } catch (e) {
    setStep(id, "dirt", "fail", `couldn't read the branch — ${(e as Error).message}`);
    return setPhase(id, "stopped");
  }
  put(id, { steps: planSteps({ drifted: b.drifted, facts: f }), phase: "running", stashed: false, tip: b.tip });
  if (f.dirty.length) {
    setStep(id, "dirt", "fail", `${f.dirty.length} uncommitted in ${f.dirtyWorktree || "the holding worktree"} — fold them into the commit, stash them for the run, or stop`);
    patch(id, (m) => ({ ...m, phase: "dirt", dirt: { files: f.dirty, rows: f.dirtyRows ?? [], worktree: f.dirtyWorktree } }));
    return say(`${leaf(b.name)}: ${f.dirty.length} uncommitted — fold, stash or stop on its page`);
  }
  await run(id, via, f, undefined);
}

async function decide(id: string, via: Via, action: "include" | "stash" | "abort"): Promise<void> {
  if (action === "abort") {
    setStep(id, "dirt", "fail", "stopped — the working tree is untouched");
    return patch(id, (m) => ({ ...m, phase: "stopped", dirt: undefined }));
  }
  patch(id, (m) => ({ ...m, phase: "running" }));
  setStep(id, "dirt", "run", action === "include" ? "folding…" : "stashing…");
  const r = await step("branch.sync.dirt", id, via, { action });
  if (!r.ok) {
    setStep(id, "dirt", "fail", String(r.body.err || `${action} failed`));
    return setPhase(id, "dirt");
  }
  patch(id, (m) => ({ ...m, dirt: undefined, stashed: action === "stash" }));
  const b = view("branch", id)!;
  const f = await facts(b.repo, b.name).catch(() => ({ behind: 0, syncable: false, restack: false, published: false, dirty: [], dirtyWorktree: "", why: "" }));
  await run(id, via, f, action === "stash" ? "stashed for the run" : "folded into the commit");
}

async function run(id: string, via: Via, f: SyncFacts, dirt: string | undefined): Promise<void> {
  const b = view("branch", id)!;
  setStep(id, "dirt", "ok", dirt);
  const has = (s: StepId) => motionOf(id)?.steps.some((x) => x.id === s);

  if (has("reseat")) {
    setStep(id, "reseat", "run");
    const r = await step("review.reseat", id, via);
    if (!r.ok) {
      setStep(id, "reseat", "fail", reseatWhy(r.body));
      return finish(id, via, "stopped");
    }
    setStep(id, "reseat", "ok", `back on ${b.parent}'s tip`);
  }

  if (has("rebase") && rebases(f)) {
    setStep(id, "rebase", "run");
    const r = await step("branch.sync.rebase", id, via);
    const out = rebaseOf(r.ok, r.body);
    if (out.kind === "restack") {
      const q = await step("branch.sync.restack", id, via, { project: out.project });
      if (!q.ok) {
        setStep(id, "rebase", "fail", String(q.body.err || "the restack was refused"));
        return finish(id, via, "stopped");
      }
      setStep(id, "rebase", "ok", q.body.queued ? `queued behind ${q.body.behind || "the running restack"} — sync again once it lands` : `restacking ${out.project} in the background — sync again once it lands`);
      return finish(id, via, "restacking");
    }
    if (out.kind === "contract") {
      setStep(id, "rebase", "fail", "already merged into origin/main — the restack walk drops it");
      return finish(id, via, "stopped");
    }
    if (out.kind === "conflict") {
      setStep(id, "rebase", "fail", "conflict — Claude is rebasing it in the branch's worktree (it never pushes); sync again once it lands");
      return finish(id, via, "conflict");
    }
    setStep(id, "rebase", out.kind === "rebased" ? "ok" : "skip", out.note);
  }

  setStep(id, "prep", "run");
  const p = await step("branch.sync.prep", id, via);
  const shape = prepOf(p.ok, p.body);
  if (shape.kind === "claude") {
    setStep(id, "prep", "fail", shape.note);
    const c = await step("branch.sync.reconcile", id, via);
    if (!c.ok) setStep(id, "prep", "fail", `${shape.note}\nClaude didn't start — ${String(c.body.err || "refused")}`);
    return finish(id, via, "claude");
  }
  if (shape.kind === "fail") {
    setStep(id, "prep", "fail", shape.note);
    return finish(id, via, "stopped");
  }
  setStep(id, "prep", "ok", shape.note);
  if (sealed(p.body) && pg.id() === id) dispatch("review.words", via);
  if (shape.kind === "rest") {
    setStep(id, "gates", "skip");
    setStep(id, "tests", "skip");
    return finish(id, via, "done");
  }

  // the gates run detached on the shaped tip, as `p` starts them; the ship line follows them from there
  if (view("branch", id)?.gates === "running") setStep(id, "gates", "ok", "already running");
  else {
    dispatch("branch.gates.run", via, { target: id });
    setStep(id, "gates", "ok", "started — p pushes once they're green");
  }
  setStep(id, "tests", "run");
  const t = await step("branch.sync.tests", id, via);
  const tests = testsOf(t.body);
  setStep(id, "tests", tests.state, tests.note);
  return finish(id, via, "done");
}

/** Bring a sync stash back once the motion is over, whatever stopped it. */
async function finish(id: string, via: Via, phase: Phase): Promise<void> {
  patch(id, (m) => ({ ...m, phase, tip: view("branch", id)?.tip ?? m.tip }));
  const failed = motionOf(id)?.steps.find((s) => s.state === "fail");
  const name = leaf(view("branch", id)?.name ?? id);
  say(phase === "done" ? `synced ${name}` : phase === "stopped" ? `${name}: ${failed?.label ?? "sync"} — ${(failed?.note ?? "stopped").split("\n")[0]}` : `${name}: ${PHASE_WORD[phase as keyof typeof PHASE_WORD]}`);
  if (!motionOf(id)?.stashed) return;
  const r = await step("branch.sync.dirt", id, via, { action: "pop" });
  patch(id, (m) => ({ ...m, stashed: false }));
  setStep(id, "dirt", r.ok ? "ok" : "fail", r.ok ? "stash popped — your uncommitted changes are back" : `the stash didn't pop (still stashed):\n${String(r.body.err || "")}`);
}

function reseatWhy(body: Record<string, unknown>): string {
  const c = (body.conflicts as { branch: string; files?: string; detail?: string }[] | undefined) ?? [];
  if (c.length) return `hit a conflict reseating ${c.map((x) => leaf(x.branch)).join(", ")} — the forest's restack resolves it`;
  return String(body.err || "the reseat was refused");
}

// ── the dirt decision, on the branch page ──

const deciding = (id: string | undefined) => motionOf(id)?.phase === "dirt";
command({
  id: "review.sync.fold",
  label: "fold",
  title: "Fold the uncommitted changes into the commit, then sync",
  scope: "review",
  budget: "local",
  available: deciding,
  local: (id, e) => void decide(id!, e instanceof MouseEvent ? "click" : "menu", "include"),
});
command({
  id: "review.sync.stash",
  label: "stash",
  title: "Stash the uncommitted changes for the sync, and pop them after",
  scope: "review",
  budget: "local",
  available: deciding,
  local: (id, e) => void decide(id!, e instanceof MouseEvent ? "click" : "menu", "stash"),
});
command({
  id: "review.sync.stop",
  label: "stop",
  title: "Stop the sync — leave the working tree as it is",
  scope: "review",
  budget: "local",
  available: deciding,
  local: (id, e) => void decide(id!, e instanceof MouseEvent ? "click" : "menu", "abort"),
});
/** The dirty file whose change is open under the dirt decision — "<branch id>|<path>". */
export const [dirtOpen, setDirtOpen] = createSignal<string | null>(null);
command({
  id: "review.sync.dirt.show",
  title: "Show or hide a dirty file's uncommitted change",
  scope: "review",
  budget: "local",
  quiet: true,
  available: (target) => deciding(target?.split("|")[0]),
  local: (target) => setDirtOpen((cur) => (cur === target ? null : target!)),
});
command({
  id: "review.sync.dismiss",
  title: "Put the sync's steps away",
  scope: "review",
  budget: "local",
  quiet: true,
  available: (id) => !!motionOf(id) && !running(id) && !deciding(id),
  local: (id) => put(id!, undefined),
});

// ── the rare repairs: in the menu only when they apply ──

command({
  id: "review.reseat",
  label: "reseat",
  title: "Reseat it on its parent's tip (every drifted child of the parent moves back)",
  scope: "review",
  budget: "git-write",
  v1: ["reseat-children"],
  available: (id) => !!bv(id)?.b.drifted,
  write: (id, arg): Write | null => {
    const b = view("branch", id);
    if (!b) return null;
    return stepWrite(arg, {
      ops: [{ type: "branch", id, fields: { drifted: false } }],
      path: atRepo(b.repo, "/reseat-children"),
      body: { branch: b.parent },
      settled: () => !world.entities.branch[id]?.drifted,
      said: `reseated ${leaf(b.name)} on ${leaf(b.parent)}`,
      failed: `${leaf(b.name)} didn't reseat — a conflict; the forest's restack resolves it`,
    });
  },
});
command({
  id: "review.upstream.detach",
  label: "detach",
  title: "Detach its upstream — it tracks the trunk, so a Pull would merge main into it",
  scope: "review",
  budget: "config-write",
  v1: ["fix-upstream"],
  available: (id) => !!bv(id)?.b.upstreamBad,
  write: (id): Write | null => {
    const b = view("branch", id);
    if (!b) return null;
    return {
      ops: [{ type: "branch", id, fields: { upstream: "", upstreamBad: false } }],
      path: atRepo(b.repo, "/fix-upstream"),
      body: { branch: b.name },
      settled: () => world.entities.branch[id]?.upstream === "",
      said: `${leaf(b.name)} tracks nothing now — a Pull can't merge main in`,
      failed: `couldn't detach ${leaf(b.name)}'s upstream`,
    };
  },
});

/** The divergence being inspected on the branch page — its id, for Ship.tsx to read. */
export const [inspecting, setInspecting] = createSignal<string | undefined>();
command({
  id: "review.diverged.inspect",
  label: "divergence",
  title: "Inspect the divergence — what's only here, what's only on origin, what the PR becomes",
  scope: "review",
  budget: "local",
  available: (id) => !!bv(id)?.b.diverged && !!bv(id)?.b.upstream,
  local: (id) => setInspecting((cur) => (cur === id ? undefined : id)),
});
