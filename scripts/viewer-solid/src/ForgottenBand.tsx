import { createMemo, Show, For } from "solid-js";
import type { JSX } from "solid-js";
import type { Project } from "./types";

// ── forgotten: provisional bets that went quiet ─────────────────────────────
// The bands rank by momentum and the tiers rank by conviction; neither can see a decision
// going stale. `trying`/`spike` are provisional — a bet you meant to settle — so one that has
// sat untouched for weeks isn't being tried, it's forgotten. Those rows already render in the
// tier sections, sorted newest-first by a clock that a rebase resets, so a 21-day-old spike
// reads as "touched 1d ago" and looks like live work. This band pulls them out and dates them
// by lastAuthored (author-date survives a rebase), so the age is the row's loudest fact.
//
// A row leaves ONLY by a decision — never by decay. That is the whole point: the forcing
// function nothing else supplies. It carries no actions of its own; the row's own right-click
// menu already shelves (drop), re-tiers (commit to it), and pins (do it now).
const DAY = 86400e3;
export const FORGOTTEN_AFTER_DAYS = 7;

export const idleDays = (p: Project): number | null =>
  p.lastAuthored ? (Date.now() - p.lastAuthored * 1000) / DAY : null;

// A provisional bet, still in play, with work that never left this machine. `committed` is
// deliberately out: dropping a commitment is a different, louder conversation than settling a
// spike, and the lifecycle bands already hold it.
export const isForgotten = (p: Project): boolean => {
  if (p.shelved || p.focus != null || p.tier === "committed") return false;
  if (!(p.unpushed ?? 0)) return false;
  const idle = idleDays(p);
  return idle != null && idle > FORGOTTEN_AFTER_DAYS;
};

export function ForgottenBand(props: {
  projects: () => Project[] | undefined;
  forestRow: (p: Project, folded: boolean) => JSX.Element;
}) {
  const rows = createMemo(() =>
    (props.projects() || []).filter(isForgotten).sort((a, b) => (idleDays(b) ?? 0) - (idleDays(a) ?? 0)));

  return (
    <Show when={rows().length}>
      <section class="forgotten-band mt-7">
        <h2 class="eyebrow font-display text-[12px] tracking-[0.08em] text-ink-dim uppercase">
          forgotten
          <span class="eyebrow-ask ml-2 font-display text-[14px] normal-case italic tracking-normal text-ink-dim">
            — bets you never settled, oldest first · right-click to drop, keep, or pick up
          </span>
        </h2>
        <div class="forgotten-rows mt-2 flex flex-col gap-[2px]">
          <For each={rows()}>
            {(p) => (
              <div class="forgotten-entry grid grid-cols-[3.25rem_1fr] items-baseline gap-x-2">
                <span
                  class="forgotten-age justify-self-end font-mono text-[11px] text-ember tabular-nums"
                  title={`last written ${Math.round(idleDays(p) ?? 0)} days ago · ${p.unpushed} unpushed${p.green ? ` · ${p.green} green` : ""}`}
                >
                  {Math.round(idleDays(p) ?? 0)}d
                </span>
                <div class="min-w-0">{props.forestRow(p, false)}</div>
              </div>
            )}
          </For>
        </div>
      </section>
    </Show>
  );
}
