// Does the whole forest merge? POST /integrate {project} octopus-merges the forest's tips onto main
// in an ephemeral ref (refs/stack/<project>-integration — never a branch, never pushed) and answers
// clean or the leaves that conflict. One verdict per forest per shape: a new tip anywhere makes it
// a claim about a forest that no longer exists, so it's dropped and (on the forest page) re-asked.
// It costs a second or more of git per forest, so Forests never asks on paint — only the forest
// page, a forest row the cursor rests on, and the re-check command do.
import { createSignal } from "solid-js";
import { atRepo, model } from "./model";
import { view } from "./store";
import { ask } from "./sync";

export type Verdict = { state: "checking" | "clean" | "conflicts" | "failed"; detail: string; stamp: string };

const [verdicts, setVerdicts] = createSignal<ReadonlyMap<string, Verdict>>(new Map());

/** The forest's shape: its branches and their tips. */
const stampOf = (pid: string) =>
  (model.forests().get(pid)?.branches ?? []).map((v) => `${v.b.name}@${v.b.tip}`).join("|");

/** A forest has a whole to integrate once it spans more than one branch and isn't all landed —
 *  a one-branch forest's integration is the branch itself (stack-forest draws no ✦ for it). */
export function integratable(pid: string | undefined): boolean {
  const bs = pid ? model.forests().get(pid)?.branches ?? [] : [];
  return bs.length > 1 && bs.some((v) => v.st.ship !== "landed");
}

/** The verdict for the forest as it stands now, if one was asked for this shape. */
export function verdict(pid: string | undefined): Verdict | undefined {
  if (!pid) return undefined;
  const v = verdicts().get(pid);
  return v && v.stamp === stampOf(pid) ? v : undefined;
}

const put = (pid: string, v: Verdict) => setVerdicts((m) => new Map(m).set(pid, v));

/** Ask whether the forest merges — once per shape unless `again`; a check in flight isn't doubled. */
export async function checkIntegration(pid: string, again = false): Promise<void> {
  const p = view("project", pid);
  if (!p || !integratable(pid)) return;
  const stamp = stampOf(pid);
  const had = verdict(pid);
  if (had && (had.state === "checking" || !again)) return;
  put(pid, { state: "checking", detail: had?.detail ?? "", stamp });
  const r = await ask<{ ok: boolean; clean: boolean; detail?: string }>(atRepo(p.repo, "/integrate"), { project: p.name });
  if (verdicts().get(pid)?.stamp !== stamp) return;
  put(pid, {
    // a check that never ran is not a conflict: saying so would call a forest broken when the server merely went away
    state: !r || !r.ok ? "failed" : r.clean ? "clean" : "conflicts",
    detail: !r ? "the check couldn't run" : (r.detail ?? ""),
    stamp,
  });
}
