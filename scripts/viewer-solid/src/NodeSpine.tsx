import { For, Show } from "solid-js";
import type { Station } from "./nodeStation";

// The node header under the one-chip-one-slot rule (Phil, 2026-07-05): ONE waymark chip —
// the branch's position on its real path, edit → review → ready → shared → merged — and
// ONE slot holding the single next step, hidden (never disabled) when there is none.
// Everything the header used to say with a pile of chips and buttons is either a STATION
// (a place on this path), a REASON (why the branch sits there — the tooltip), or an EDGE
// (the one move forward — the slot). This component is purely presentational: the caller
// derives station/edge from the queries it already runs and passes the mutations in.
// Station itself is domain, not view — it lives in nodeStation.ts alongside the rules that
// decide it, because the forest map and review surface need the same answer.
//
// Every color is an existing register, honestly applied: gold is blessed and nothing else;
// ember is heat before the crossing; sage is work planted in the shared world; patina is
// finished history. No new tokens.

export interface SpineEdge {
  label: string; // the step, named as the step: "prep: squash 3→1", "edit the why", "push"
  kind: "prep" | "edit" | "push" | "contract";
  pending: boolean;
  armed?: boolean; // push only: two-click arm state
  title: string;
  onClick: () => void;
}

const STATIONS: { id: Station; mark: string }[] = [
  { id: "edit", mark: "○" },
  { id: "review", mark: "✦" },
  { id: "ready", mark: "▲" },
  { id: "shared", mark: "●" },
  { id: "merged", mark: "✕" },
];

const SLOT =
  "min-w-[5.5em] rounded-full border px-3 py-[3px] text-[12px] leading-[1.55] transition-[border-color,color,background] duration-[140ms] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ember motion-reduce:transition-none";

export default function NodeSpine(props: {
  station: Station;
  blessedAll: boolean; // review's mark takes gold only when every file is blessed
  reasons: string; // why the branch sits at this station — the chip's tooltip
  edge: SpineEdge | null; // null → at rest: the slot does not render
  dirty?: number; // uncommitted files in the holding worktree — a small ± mark, details in reasons + the rail
}) {
  const actionable = () => props.station === "merged" && !!props.edge;
  // gold is earned, not positional: the review mark gilds only at every-file-blessed,
  // whether the branch stands there or has moved on
  const markTint = (id: Station): string => {
    if (id === "review" && props.blessedAll) return "text-gold-leaf [text-shadow:0_0_8px_var(--color-gold-wash)]";
    if (id !== props.station) return "text-ink-faint";
    if (id === "ready") return "text-ember [text-shadow:0_0_7px_var(--color-ember-wash)]";
    if (id === "shared") return "text-add";
    if (id === "merged") return actionable() ? "text-ember" : "text-patina";
    return "text-ink";
  };
  // an actionable merged ghost is NOT done: the slot offers the next move (drop & rewire), so
  // the station reads active in ember — not the struck-through patina of a truly closed branch.
  const wordTint = (): string => {
    if (props.station === "merged") {
      return actionable() ? "text-ember" : "text-ink-dim line-through decoration-patina";
    }
    if (props.station === "shared") return "text-add";
    return "text-ink";
  };
  const slotState = (e: SpineEdge): string => {
    const cursor = e.pending ? "cursor-progress" : "cursor-pointer";
    if (e.kind === "push") {
      return e.armed
        ? `${cursor} border-ember bg-ember-wash text-ink`
        : `${cursor} border-ember bg-transparent text-ember hover:bg-ember-wash`;
    }
    return `${cursor} border-rule bg-transparent hover:border-ink-dim ${e.pending ? "text-ink-dim" : "text-ink"}`;
  };

  return (
    <span class="spine-wrap inline-flex items-center gap-[10px]">
      <span
        class={`spine-chip at-${props.station} inline-flex cursor-default items-center gap-[9px] rounded-full border border-rule bg-vellum-raise py-[3px] pr-[11px] pl-[9px]`}
        classList={{ actionable: actionable() }}
        title={props.reasons}
      >
        {/* one mark only — the current station (plus the review ✦ when it's earned gold);
            the journey's other stations live in the tooltip, not the chrome */}
        <span class="spine-path inline-flex items-center gap-[7px] text-[10px] leading-none" aria-hidden="true">
          <For each={STATIONS.filter((s) => s.id === props.station || (s.id === "review" && props.blessedAll))}>
            {(s) => (
              <span
                class={`spine-mark m-${s.id} transition-[color,text-shadow] duration-[160ms] motion-reduce:transition-none ${markTint(s.id)}`}
                classList={{ here: s.id === props.station, lit: s.id === "review" && props.blessedAll }}
              >
                {s.mark}
              </span>
            )}
          </For>
        </span>
        <span class={`spine-word font-display text-[12.5px] italic tracking-[0.02em] ${wordTint()}`}>
          {props.station}
        </span>
        <Show when={(props.dirty ?? 0) > 0}>
          <span class="spine-dirt ml-[6px] text-[10px] tracking-normal text-ink-dim">±{props.dirty}</span>
        </Show>
      </span>
      <Show when={props.edge}>
        <button
          class={`spine-slot slot-${props.edge!.kind} ${SLOT} ${slotState(props.edge!)}`}
          classList={{ armed: !!props.edge!.armed, pending: props.edge!.pending }}
          disabled={props.edge!.pending}
          title={props.edge!.title}
          onClick={props.edge!.onClick}
        >
          {props.edge!.pending ? "…" : props.edge!.armed ? `confirm: ${props.edge!.label}` : props.edge!.label}
        </button>
      </Show>
    </span>
  );
}
