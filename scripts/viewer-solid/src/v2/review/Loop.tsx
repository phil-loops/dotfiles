// The branch's place in the dev loop, one strip under the title: each step done, in the way, or
// later — the one in the way says what it waits on, and words flag what the PR form would carry.
import { For, Show } from "solid-js";
import { useOutline } from "../Commits";
import { loopSteps, type StepId } from "../loop";
import { model } from "../model";
import { prHints } from "../words";
import { page as pg } from "./page";

const WORD: Record<StepId, string> = { words: "words", gates: "gates", push: "push", pr: "PR", review: "review", merged: "merged" };

export default function LoopStrip() {
  const v = () => model.branchView(pg.id());
  useOutline(() => pg.id());
  const steps = () => (v() ? loopSteps(v()!.b, v()!.pr, v()!.st, prHints(pg.id())) : []);
  return (
    <Show when={v() && !pg.integration()}>
      <div class="rv-loop flex flex-wrap items-baseline gap-x-2 text-[12px]">
        <For each={steps()}>
          {(s, i) => (
            <>
              <Show when={i() > 0}>
                <span class="text-ink-faint">▸</span>
              </Show>
              <span
                class={s.flag ? "text-gold-leaf" : s.state === "now" ? "text-gold-leaf" : s.state === "done" ? "text-patina" : "text-ink-faint"}
              >
                {s.state === "done" && !s.flag ? "✓ " : ""}
                {WORD[s.id]}
                <Show when={s.state === "now" && s.note}>
                  <span class="text-ink-dim"> {s.note}</span>
                </Show>
              </span>
            </>
          )}
        </For>
      </div>
    </Show>
  );
}
