// The push window: where the clock stands against the 15:00 PT cliff, and what crossing it costs.
// Measured over Phil's 2026 PRs — opened before three, a median 3.2h to merge; at or after, 18.8h
// (the review lands tomorrow). Shown, not enforced: the only lever is a hold, which moves a row
// into the morning lane and pushes nothing.
import { Show } from "solid-js";
import { fmtDayPT, fmtSpan, nextMorning, pushWindow, type PushWindowFacts } from "./outboxModel";

export function PushWindow(props: {
  facts: PushWindowFacts;
  now: number;
  holdable: number;
  due: number;
  onHoldAll?: () => void;
  compact?: boolean;
}) {
  const w = () => pushWindow(props.now, props.facts);
  const late = () => w().phase === "late" || w().phase === "weekend";
  const morning = () => fmtDayPT(nextMorning(props.now, props.facts.morningHourPT));
  const show = () => w().phase !== "open" || props.due > 0;
  const text = () => {
    switch (w().phase) {
      case "open": return "";
      case "closing": return `${fmtSpan(w().minutesToCliff)} to 3pm — after it, PRs take ~${Math.round(props.facts.slowH)}h to merge`;
      case "late": return `Past 3pm — a PR opened now takes ~${Math.round(props.facts.slowH)}h to merge, ~${Math.round(props.facts.fastH)}h in the morning`;
      case "weekend": return "Weekend — nobody reviews until Monday";
    }
  };
  // One quiet line, and only when the clock matters: silent while the window is comfortably open.
  return (
    <Show when={show()}>
      <div
        class={`ob-window mb-[10px] flex flex-wrap items-baseline gap-x-[14px] gap-y-[4px] font-display text-[14px] italic ${late() ? "text-ember" : "text-gold-leaf"}`}
        data-phase={w().phase}
        title={`opened before three, PRs merge in a median ${props.facts.fastH}h; at or after, ${props.facts.slowH}h`}
      >
        <Show when={text()}><span>{text()}</span></Show>
        <Show when={props.due}>
          <span class="text-gold-leaf">☀ {props.due} held overnight {props.due === 1 ? "is" : "are"} due</span>
        </Show>
        <Show when={late() && props.holdable && props.onHoldAll && !props.compact}>
          <button
            class="cursor-pointer border-0 bg-transparent p-0 font-mono text-[11px] not-italic text-ember underline decoration-ember/40 underline-offset-4 hover:decoration-ember"
            title="stamp a hold on every ready, unopened branch — they wait in the morning lane; nothing pushes by itself"
            onClick={() => props.onHoldAll?.()}
          >
            hold {props.holdable} for {morning()}
          </button>
        </Show>
      </div>
    </Show>
  );
}
