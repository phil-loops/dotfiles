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
// Inputs are the FACTS, not the transport that carried them: the review surface learns
// "nothing outgoing" from a prep-route query, the map from upstream && !ahead — same fact,
// and neither has to fake the other's evidence to ask.
export function stationOf(input: {
  merged?: boolean;
  gone?: boolean; // the branch's upstream vanished — it landed and origin dropped it
  nothingOutgoing?: boolean; // every local commit is already on origin: the team sees exactly this
  ready?: boolean; // exactly one voiced commit, waiting on the push
  blessed?: number;
  total?: number;
}): Station {
  if (input.merged || input.gone) {
    return "merged";
  }
  if (input.nothingOutgoing) {
    return "shared";
  }
  if (input.ready) {
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
  drifted?: boolean;
  behind?: number;
  syncable?: boolean;
  prepRoute?: string;
  prepWhy?: string;
}): { kind: "prep"; label: string; title: string } | null {
  // contractable = droppable NOW (rebase-classify exit 20): nothing left to do here — the
  // restack walk drops it. A merged PR with a follow-on commit is merged but NOT contractable,
  // so offer the forward rebase (push the follow-on).
  if (input.merged && input.contractable) {
    return null;
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
  if (r && r !== "nothing" && r !== "ready") {
    steps.push(input.prepWhy ?? "route to one outgoing commit");
  }
  steps.push("hand the words to the outline column");
  return {
    kind: "prep",
    label: "⟲ sync",
    title: `sync — everything local, in one motion:\n· ${steps.join("\n· ")}\n(Claude steps in when a divergence has no mechanical route)`,
  };
}
