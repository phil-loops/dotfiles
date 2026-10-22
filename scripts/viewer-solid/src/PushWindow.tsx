// The push window: where the clock stands against the 15:00 PT cliff, and what crossing it costs.
// Measured over Phil's 2026 PRs — opened before three, a median 3.2h to merge; at or after, 18.8h
// (the review lands tomorrow). Shown, not enforced: the only lever is a hold, which moves a row
// into the morning lane and pushes nothing.
import { Show } from "solid-js";
import { fmtDayPT, fmtPT, fmtSpan, nextMorning, pushWindow, type PushWindowFacts } from "./outboxModel";

const DAY_START = 6;
const DAY_END = 21;

export function PushWindow(props: {
  facts: PushWindowFacts;
  now: number;
  holdable: number;
  due: number;
  onHoldAll?: () => void;
  compact?: boolean;
}) {
  const w = () => pushWindow(props.now, props.facts);
  const pct = (h: number) => `${(100 * (Math.min(DAY_END, Math.max(DAY_START, h)) - DAY_START)) / (DAY_END - DAY_START)}%`;
  const late = () => w().phase === "late" || w().phase === "weekend";
  const morning = () => fmtDayPT(nextMorning(props.now, props.facts.morningHourPT));
  const headline = () => {
    switch (w().phase) {
      case "open": return `Window open · ${fmtSpan(w().minutesToCliff)} before the 3pm cliff`;
      case "closing": return `Closing · ${fmtSpan(w().minutesToCliff)} to the cliff`;
      case "late": return `Past the cliff · ${fmtPT(props.now)} PT`;
      case "weekend": return `Weekend · ${fmtPT(props.now)} PT`;
    }
  };
  const line = () => late()
    ? `A PR opened now takes a median ${props.facts.slowH}h to merge — ${props.facts.fastH}h before three.${w().phase === "weekend" ? " Nobody reviews until Monday." : ""}`
    : `Opened before three, PRs merge in a median ${props.facts.fastH}h; after, ${props.facts.slowH}h. Ship what's ready now.`;
  return (
    <section
      class={`ob-window relative mb-[8px] overflow-hidden rounded-[12px] border px-[18px] pt-[14px] pb-[12px] ${late() ? "border-[#5a3424] bg-[linear-gradient(180deg,rgba(210,115,42,0.07),transparent)]" : "border-gold-deep bg-[linear-gradient(180deg,rgba(230,182,78,0.06),transparent)]"}`}
      data-phase={w().phase}
    >
      <div class="flex flex-wrap items-baseline gap-x-[14px] gap-y-[4px]">
        <span class="font-mono text-[10px] tracking-[0.22em] text-ink-faint uppercase">push window</span>
        <span class={`font-display text-[19px] italic ${late() ? "text-ember" : w().phase === "closing" ? "text-gold-leaf" : "text-ink"}`}>{headline()}</span>
        <Show when={props.due}>
          <span class="font-mono text-[11px] text-gold-leaf">☀ {props.due} held from last night {props.due === 1 ? "is" : "are"} due</span>
        </Show>
      </div>
      <Show when={!props.compact}>
        <div class="relative mt-[12px] mb-[18px] h-[8px] rounded-full bg-vellum-edge" title="06:00–21:00 PT">
          <div class="absolute inset-y-0 left-0 rounded-l-full bg-gold-wash" style={{ width: pct(props.facts.cliffHourPT) }} />
          <div class="absolute inset-y-0 right-0 rounded-r-full bg-ember-wash" style={{ left: pct(props.facts.cliffHourPT) }} />
          <div class="absolute top-[-4px] bottom-[-4px] w-px bg-ember" style={{ left: pct(props.facts.cliffHourPT) }} />
          <span class="absolute top-[12px] -translate-x-1/2 font-mono text-[9.5px] text-ember" style={{ left: pct(props.facts.cliffHourPT) }}>3pm</span>
          <span class="absolute top-[12px] left-0 font-mono max-[640px]:hidden text-[9.5px] text-ink-faint">6am · {props.facts.fastH}h to merge</span>
          <span class="absolute top-[12px] right-0 font-mono max-[640px]:hidden text-[9.5px] text-ink-faint">{props.facts.slowH}h to merge · 9pm</span>
          <Show when={w().phase !== "weekend"}>
            <span
              class={`absolute top-1/2 h-[14px] w-[14px] -translate-x-1/2 -translate-y-1/2 rounded-full border-2 border-vellum-night ${late() ? "bg-ember" : "bg-gold-leaf"} shadow-[0_0_0_3px_rgba(230,182,78,0.18)]`}
              style={{ left: pct(w().hourFloat) }}
              title={`now · ${fmtPT(props.now)} PT`}
            />
          </Show>
        </div>
      </Show>
      <div class="flex flex-wrap items-center gap-x-[14px] gap-y-[6px]">
        <p class="m-0 flex-1 font-display text-[13.5px] leading-[1.5] text-ink-dim">{line()}</p>
        <Show when={late() && props.holdable && props.onHoldAll}>
          <button
            class="cursor-pointer rounded-[7px] border border-ember px-[11px] py-[3px] font-mono text-[11px] text-ember transition-colors hover:bg-ember-wash"
            title="stamp a hold on every ready, unopened branch — they wait in the morning lane; nothing pushes by itself"
            onClick={() => props.onHoldAll?.()}
          >
            ☾ hold {props.holdable} for {morning()}
          </button>
        </Show>
      </div>
    </section>
  );
}
