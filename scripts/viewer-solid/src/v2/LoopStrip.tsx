// A branch's place in the dev loop, one strip: each step done, in the way, or later — the one in the
// way says what it waits on. The branch page also reads its words (the PR form's title and body
// hints) and links them to the commits tab; a forest row leaves words out rather than fetch them.
import { For, Show } from "solid-js";
import { useOutline } from "./Commits";
import { loopSteps, type StepId } from "./loop";
import { model } from "./model";
import { bind } from "./runner";
import { prHints, shown } from "./words";

const WORD: Record<StepId, string> = { words: "words", gates: "gates", push: "push", pr: "PR", review: "review", merged: "merged" };

export default function LoopStrip(props: { branchId: string; words?: boolean; class?: string }) {
  const v = () => model.branchView(props.branchId);
  if (props.words) useOutline(() => props.branchId);
  const words = () => (props.words && shown.get(props.branchId) ? prHints(props.branchId) : null);
  const steps = () => (v() ? loopSteps(v()!.b, v()!.pr, v()!.st, words()) : []);
  return (
    <Show when={v()}>
      <div class={`rv-loop flex flex-wrap items-baseline gap-x-2 ${props.class ?? "text-[12px]"}`}>
        <For each={steps()}>
          {(s, i) => (
            <>
              <Show when={i() > 0}>
                <span class="text-ink-faint">▸</span>
              </Show>
              <Show
                when={s.id === "words"}
                fallback={
                  <span class={s.state === "now" ? "text-gold-leaf" : s.state === "done" ? "text-patina" : "text-ink-faint"}>
                    {s.state === "done" ? "✓ " : ""}
                    {WORD[s.id]}
                    <Show when={s.state === "now" && s.note}>
                      <span class="text-ink-dim"> {s.note}</span>
                    </Show>
                  </span>
                }
              >
                <button class={`rv-quietbtn ${s.flag ? "text-gold-leaf" : "text-patina"}`} onClick={bind("review.tab.commits")} title="the commits tab — where the title and body are edited">
                  {s.flag ? "" : "✓ "}words
                  <Show when={s.note}>
                    <span class="text-ink-dim"> {s.note}</span>
                  </Show>
                </button>
              </Show>
            </>
          )}
        </For>
      </div>
    </Show>
  );
}
