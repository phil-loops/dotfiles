// The sync motion's rules — what makes a branch need ⟲ sync, the steps it walks in v1's order, and
// how each server answer reads as a step — pure, so node --test pins them. The driver
// (commands/sync.ts) runs the steps; the ship line (review/Ship.tsx) draws them.
import type { Branch } from "./types";

/** GET /sync — v1's fork-staleness read for one branch (srv/sync.py state). */
export interface SyncFacts {
  behind: number;
  syncable: boolean;
  restack: boolean;
  published: boolean;
  dirty: string[];
  /** each dirty file's patch against HEAD (an untracked file's against nothing) */
  dirtyRows?: DirtRow[];
  dirtyWorktree: string;
  why: string;
}

export interface DirtRow {
  path: string;
  code: string;
  patch: string;
}

/** GET /prep-route — the one motion prep would make next (srv/prep.py). */
export interface PrepRoute {
  route: string;
  why: string;
}

/** Why ⟲ sync is worth a press on this branch, one short reason each — empty at rest. */
export function syncNeeds(b: Branch, facts?: SyncFacts | null, prep?: PrepRoute | null): string[] {
  const out: string[] = [];
  const dirty = facts?.dirty.length ?? 0;
  if (dirty) out.push(`${dirty} uncommitted`);
  if (b.drifted) out.push(`off ${b.parent}'s tip`);
  if (facts && facts.behind > 0 && (facts.syncable || facts.restack)) out.push(`${facts.behind} behind main`);
  if (prep?.route === "squash") out.push("not one voiced commit");
  if (prep?.route === "additive") out.push("diverged from its PR");
  else if (b.diverged) out.push("diverged from origin");
  return out;
}

export type StepId = "dirt" | "reseat" | "rebase" | "prep" | "gates" | "tests";
export type StepState = "idle" | "run" | "ok" | "fail" | "skip";
export interface Step {
  id: StepId;
  label: string;
  state: StepState;
  /** the step's full reason — a failure's is never cut short */
  note?: string;
  t0?: number;
}

/** The motion's steps, in v1's order: only the repairs this branch needs, then shape, gates, tests. */
export function planSteps(input: { drifted: boolean; facts: SyncFacts }): Step[] {
  const s: Step[] = [{ id: "dirt", label: "working tree", state: "idle" }];
  if (input.drifted) s.push({ id: "reseat", label: "reseat", state: "idle" });
  if (rebases(input.facts)) s.push({ id: "rebase", label: input.facts.restack ? "restack" : "rebase", state: "idle" });
  s.push({ id: "prep", label: "commit shape", state: "idle" }, { id: "gates", label: "gates", state: "idle" }, { id: "tests", label: "tests", state: "idle" });
  return s;
}

export const rebases = (f: SyncFacts) => f.behind > 0 && (f.syncable || f.restack);

/** What a POST /sync answer means for the motion. */
export type Rebase =
  | { kind: "rebased"; note?: string }
  | { kind: "restack"; project: string }
  | { kind: "contract" }
  | { kind: "conflict" }
  | { kind: "refused"; note: string };

export function rebaseOf(ok: boolean, body: Record<string, unknown>): Rebase {
  if (!ok) return { kind: "refused", note: `refused (${str(body.err) || "stacked, or an open PR"}) — the commit shape step handles it` };
  if (body.restack) return { kind: "restack", project: str(body.project) };
  if (body.contract) return { kind: "contract" };
  if (!body.rebased) return { kind: "conflict" };
  return { kind: "rebased", note: str(body.summary) || undefined };
}

/** What a POST /prep-push answer means: a state (nothing to push, a built vehicle) is not a failure. */
export type Prep =
  | { kind: "ok"; note?: string }
  | { kind: "rest"; note: string }
  | { kind: "claude"; note: string }
  | { kind: "fail"; note: string };

export function prepOf(ok: boolean, body: Record<string, unknown>): Prep {
  const err = str(body.err);
  if (ok) return { kind: "ok", note: ((body.routed as string[] | undefined) ?? []).join(" · ") || undefined };
  if (body.reconcile) return { kind: "claude", note: err || "no mechanical route — handing to Claude" };
  if (body.vehiclePending) return { kind: "rest", note: "additive vehicle already built — push it, or delete it to rebuild" };
  if (err.startsWith("nothing to push")) return { kind: "rest", note: "nothing to push — origin already has this" };
  return { kind: "fail", note: err || "prep failed" };
}

/** POST /delta-tests, as the tests step's state and note — advisory, so a failure never stops the
 *  motion. Its `ok` is the tests' verdict, so the answer is read whole, not as a refusal. */
export function testsOf(body: Record<string, unknown>): { state: StepState; note: string } {
  if (body.ran === undefined && body.noTests === undefined) return { state: "ok", note: "couldn't run" };
  if (body.noTests) return { state: "ok", note: "no changed tests" };
  if (!body.ran) return { state: "ok", note: str(body.summary) || "couldn't run" };
  if (body.ok) return { state: "ok", note: `${body.passed ?? "?"} ✓` };
  return { state: "fail", note: `${body.failed ?? "?"} failed (advisory — the motion went on):\n${str(body.summary)}` };
}

/** Whether the prep answer sealed the outgoing commits — their words are new and want a look. */
export const sealed = (body: Record<string, unknown>): boolean => ((body.routed as string[] | undefined) ?? []).some((r) => r.startsWith("sealed "));

const str = (x: unknown) => (typeof x === "string" ? x : "");

/** Where a motion ended up, as the ship line says it. */
export type Phase = "running" | "dirt" | "restacking" | "conflict" | "claude" | "stopped" | "done";

export const PHASE_WORD: Record<Exclude<Phase, "running" | "done">, string> = {
  dirt: "uncommitted — fold, stash or stop",
  restacking: "restack queued",
  conflict: "conflict — with Claude",
  claude: "no mechanical route — with Claude",
  stopped: "sync stopped",
};
