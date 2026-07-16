// Where a branch stands, and the one local step that moves it — decided as plain data.
//
// This is domain logic, not view logic: the waymark spine, the forest map and the review
// surface all need the same answer, so it can't live inside whichever component asked
// first. Pure functions over plain inputs — no signals, no queries, no JSX — so a caller
// with only part of the picture (the map knows blessings and merges, but never runs a
// prep-route query) can still ask, and any caller can be tested without mounting anything.

export type Station = "edit" | "review" | "ready" | "shared" | "merged";

// Station = the DOMINANT position on the branch's real path, not a gate: a branch can sit
// at "review" with shaping left, and the next step still offers prep. Absent evidence the
// answer degrades toward "edit" rather than claiming a station it can't see.
export function stationOf(input: {
  merged?: boolean;
  shared?: "local" | "ahead" | "synced" | "gone";
  prepRoute?: string;
  blessed?: number;
  total?: number;
}): Station {
  if (input.merged || input.shared === "gone") {
    return "merged";
  }
  if (input.prepRoute === "nothing") {
    return "shared";
  }
  if (input.prepRoute === "ready") {
    return "ready";
  }
  if (input.blessed != null && input.total != null && input.blessed < input.total) {
    return "review";
  }
  return "edit";
}

// The single LOCAL next step (Phil: "whatever we do here locally is fine") — the shared
// world never moves from this slot; that's the red push button's sole job. Returns the
// DECISION only (kind + its copy); the caller wires the handler and pending state to the
// kind, so this stays testable and the same decision can render as a chip, a map badge or
// a button. null → truly at rest: the slot does not render.
export function nextStepOf(input: {
  merged?: boolean;
  contractable?: boolean;
  contractKids?: string[] | null;
  drifted?: boolean;
  behind?: number;
  syncable?: boolean;
  prepRoute?: string;
  prepWhy?: string;
}): { kind: "contract" | "prep"; label: string; title: string } | null {
  // contractable = droppable NOW (rebase-classify exit 20); contractKids means /sync already
  // verified it. A merged PR with a follow-on commit is merged but NOT contractable — /contract
  // refuses it, so offer the forward rebase (push the follow-on) instead of a dead drop.
  if (input.contractKids || (input.merged && input.contractable)) {
    return {
      kind: "contract",
      label: input.contractKids ? `drop ghost & rewire ${input.contractKids.length} →` : "drop ghost & rewire →",
      title:
        "this branch's work already merged (a ghost) — drop it, rewire its children onto main, drop any requires edge on it",
    };
  }
  if (input.merged) {
    return {
      kind: "prep",
      label: "↑ rebase forward →",
      title:
        "the PR merged but a newer commit rides on top — not droppable. ⟲ sync rebases it forward onto fresh origin/main: the merged commit drops (already upstream), the follow-on stays, then routes to one commit to push.",
    };
  }
  const r = input.prepRoute;
  if ((!r || r === "nothing") && !input.drifted && !input.behind) {
    return null;
  }
  const steps: string[] = [];
  if (input.drifted) {
    steps.push("reseat onto its parent");
  }
  if ((input.behind ?? 0) > 0 && input.syncable) {
    steps.push(`rebase forward (${input.behind} behind)`);
  }
  steps.push("checkout here");
  if (r && r !== "nothing" && r !== "ready") {
    steps.push(input.prepWhy ?? "route to one outgoing commit");
  }
  steps.push("open the message editor");
  return {
    kind: "prep",
    label: "⟲ sync",
    title: `sync — everything local, in one motion:\n· ${steps.join("\n· ")}\n(Claude steps in when a divergence has no mechanical route)`,
  };
}
