// A projection sim in a tutor turn: frozen at the reveal while the learner predicts, then — once
// their answer carries the played result — the reveal's steps, the end state, and every event the
// system skipped, counted twice or left pinned. The engine is deterministic, so the card replays it
// from the scenario and the safeguards rather than storing state.
import { createMemo, For, Show } from "solid-js";
import { createSim, kernelNames, type Kernel, type SimState } from "./sim";
import { scenario as scenarioOf } from "./simScenarios";

const LABEL = "text-[10px] uppercase tracking-[0.08em] text-ink-faint";

function build(id: string, off: string[]) {
  try {
    return createSim(scenarioOf(id), Object.fromEntries(off.map((k) => [k as Kernel, false])));
  } catch {
    return null;
  }
}

function State(props: { s: SimState; marked?: Map<string, string> }) {
  return (
    <div class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1 text-[11.5px] leading-snug">
      <span class={LABEL}>events</span>
      <span class="flex flex-wrap gap-x-3 gap-y-0.5">
        <For each={props.s.events}>
          {(e) => {
            const counted = Object.values(e.applied).reduce((n, x) => n + x, 0);
            const mark = props.marked?.get(e.id);
            return (
              <span classList={{ "text-del": !!mark, "text-ink-dim": !mark && !e.committed, "text-ink": !mark && e.committed }} title={`stamp t${e.stamp}${e.committed ? "" : " · not committed yet"}${e.retained ? "" : " · cleaned up"}`}>
                {e.id}
                <span class="text-ink-faint"> t{e.stamp}</span>
                {e.committed ? "" : " ·uncommitted"}
                {` ×${counted}`}
                {mark ? ` ${mark}` : ""}
              </span>
            );
          }}
        </For>
      </span>
      <span class={LABEL}>bookmarks</span>
      <span class="flex flex-wrap gap-x-3 gap-y-0.5 text-ink-dim">
        <For each={props.s.bookmarks}>
          {(b) => (
            <span classList={{ "line-through opacity-60": !b.live }}>
              {b.name} → {b.cursor.id ? `${b.cursor.id} t${b.cursor.stamp}` : "start"}
            </span>
          )}
        </For>
      </span>
      <span class={LABEL}>workers</span>
      <span class="flex flex-wrap gap-x-3 gap-y-0.5 text-ink-dim">
        <For each={props.s.workers}>{(w) => <span>{w.id} {w.status}</span>}</For>
      </span>
      <span class={LABEL}>clock</span>
      <span class="text-ink-dim">t{props.s.clock}</span>
    </div>
  );
}

/** The setup, frozen before the reveal — what the learner predicts from. */
export function SimFrozen(props: { scenario: string; off: string[] }) {
  const sim = createMemo(() => build(props.scenario, props.off));
  const frozen = createMemo(() => sim()?.toReveal());
  return (
    <Show when={sim() && frozen()} fallback={<p class="my-3 text-[12px] text-del">no sim scenario {props.scenario}</p>}>
      <div class="my-3 border border-rule bg-vellum-night p-3">
        <div class="mb-1 flex items-baseline gap-2">
          <span class={LABEL}>sim · frozen before the reveal</span>
        </div>
        <div class="mb-1 font-display text-[15px] text-ink">{sim()!.scenario.title}</div>
        <Off off={props.off} />
        <p class="m-0 mb-2 text-[13px] leading-relaxed text-ink-dim">{sim()!.scenario.situation}</p>
        <State s={frozen()!} />
        <p class="m-0 mt-2 text-[13px] text-gold-leaf">{sim()!.scenario.question}</p>
      </div>
    </Show>
  );
}

/** The sim played out after the learner's answer: what happened, and where the system diverged. */
export function SimPlayed(props: { scenario: string; off: string[] }) {
  const run = createMemo(() => {
    const sim = build(props.scenario, props.off);
    if (!sim) return null;
    const from = sim.toReveal().log.length;
    const result = sim.runToEnd();
    const end = sim.state();
    return { title: sim.scenario.title, result, end, steps: end.log.slice(from), marked: new Map(result.divergence.map((d) => [d.event, d.kind])) };
  });
  return (
    <Show when={run()}>
      {(r) => (
        <div class="my-3 border p-3" classList={{ "border-add": r().result.outcome === "green", "border-del": r().result.outcome === "red" }}>
          <div class="mb-1 flex items-baseline gap-2">
            <span class={LABEL}>sim · played</span>
            <span class="text-[12px]" classList={{ "text-add": r().result.outcome === "green", "text-del": r().result.outcome === "red" }}>
              {r().result.outcome === "green" ? "✓ every event counted once" : `✗ ${r().result.divergence.map((d) => `${d.event} ${d.kind}`).join(" · ")}`}
            </span>
            <span class="flex-1" />
            <span class="text-[11px] text-ink-faint">
              counted {r().result.actual} of {r().result.truth}
              {r().result.busy ? ` · ${r().result.busy} pages waited on the lock` : ""}
            </span>
          </div>
          <div class="mb-1 text-[13px] text-ink">{r().title}</div>
          <Off off={props.off} />
          <ol class="m-0 mb-2 list-decimal pl-5 text-[11.5px] leading-snug text-ink-dim">
            <For each={r().steps}>{(line) => <li>{line}</li>}</For>
          </ol>
          <State s={r().end} marked={r().marked} />
        </div>
      )}
    </Show>
  );
}

function Off(props: { off: string[] }) {
  return (
    <div class="mb-2 text-[11px] text-ink-faint">
      {props.off.length ? `safeguard off: ${props.off.map((k) => kernelNames[k as Kernel] ?? k).join(" · ")}` : "every safeguard on"}
    </div>
  );
}
