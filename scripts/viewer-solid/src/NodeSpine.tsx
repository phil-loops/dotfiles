import { For, Show } from "solid-js";
import "./NodeSpine.css";

// The node header under the one-chip-one-slot rule (Phil, 2026-07-05): ONE waymark chip —
// the branch's position on its real path, edit → review → ready → shared → merged — and
// ONE slot holding the single next step, hidden (never disabled) when there is none.
// Everything the header used to say with a pile of chips and buttons is either a STATION
// (a place on this path), a REASON (why the branch sits there — the tooltip), or an EDGE
// (the one move forward — the slot). This component is purely presentational: the caller
// derives station/edge from the queries it already runs and passes the mutations in.

export type Station = "edit" | "review" | "ready" | "shared" | "merged";

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

export default function NodeSpine(props: {
  station: Station;
  blessedAll: boolean; // review's mark takes gold only when every file is blessed
  reasons: string; // why the branch sits at this station — the chip's tooltip
  edge: SpineEdge | null; // null → at rest: the slot does not render
}) {
  const reached = () => STATIONS.findIndex((s) => s.id === props.station);
  return (
    <span class="spine-wrap">
      <span class={`spine-chip at-${props.station}`} title={props.reasons}>
        <span class="spine-path" aria-hidden="true">
          <For each={STATIONS}>
            {(s, i) => (
              <span
                class={`spine-mark m-${s.id}`}
                classList={{
                  here: s.id === props.station,
                  past: i() < reached(),
                  lit: s.id === "review" && props.blessedAll,
                }}
              >
                {s.mark}
              </span>
            )}
          </For>
        </span>
        <span class="spine-word">{props.station}</span>
      </span>
      <Show when={props.edge}>
        <button
          class={`spine-slot slot-${props.edge!.kind}`}
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
