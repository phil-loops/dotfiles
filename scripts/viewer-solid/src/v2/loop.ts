// The dev loop as one strip — words ▸ gates ▸ push ▸ PR ▸ review ▸ merged — so a branch page says
// where the branch is and what stands in the way, without reading three surfaces. Pure.
import type { Hint } from "./outlineHints";
import type { Stand } from "./ship";
import type { Branch, Pr } from "./types";

export type StepId = "words" | "gates" | "push" | "pr" | "review" | "merged";
export interface Step {
  id: StepId;
  state: "done" | "now" | "later";
  /** what this step waits on, when it's the one in the way */
  note?: string;
  /** words only: something to fix that doesn't stop the loop */
  flag?: boolean;
}

const ORDER: Exclude<StepId, "words">[] = ["gates", "push", "pr", "review", "merged"];

/** Each step's state; `words` are the title and body hints, which flag but never block — null
 *  while they're unread, which leaves the step out rather than claim it's clean. */
export function loopSteps(b: Branch, pr: Pr | undefined, st: Stand, words: Hint[] | null): Step[] {
  const merged = st.ship === "landed";
  const done: Record<Exclude<StepId, "words">, boolean> = {
    gates: b.gates === "green" || (st.ship !== "local" && b.pushed !== "ahead"),
    push: st.ship !== "local" && st.ship !== "green" && b.pushed !== "ahead",
    pr: !!pr,
    review: st.ship === "approved" || merged,
    merged,
  };
  const now = ORDER.find((id) => !done[id]);
  const steps: Step[] = ORDER.map((id) => ({ id, state: done[id] ? "done" : id === now ? "now" : "later" }));
  const at = steps.find((s) => s.state === "now");
  if (at) at.note = noteFor(at.id, b, pr, st);
  if (words === null) return steps;
  const wrong = words.filter((h) => h.tone !== "note");
  const wordsStep: Step = pr
    ? { id: "words", state: "done" }
    : { id: "words", state: wrong.length ? "now" : "done", flag: wrong.length > 0, note: wrong.length ? wrong.map((h) => h.id).join(" · ") : undefined };
  return [wordsStep, ...steps];
}

function noteFor(id: StepId, b: Branch, pr: Pr | undefined, st: Stand): string | undefined {
  switch (id) {
    case "gates":
      return b.gates === "running" ? "running" : b.gates === "red" ? `${b.redGates.join(", ") || "red"}` : b.gates === "stale" ? "stale" : "not run";
    case "push":
      return b.pushed === "ahead" ? `${b.ahead} to push` : `${b.commits} local`;
    case "pr":
      return "open it";
    case "review":
      return pr?.review === "CHANGES_REQUESTED" ? "changes requested" : pr?.draft ? "draft" : "waiting";
    case "merged":
      return st.waiting[0]?.label;
    default:
      return undefined;
  }
}
