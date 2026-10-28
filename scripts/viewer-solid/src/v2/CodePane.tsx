// One file at one commit, its lit lines scrolled to — the Tutor's pinned code and the review page's
// side pane for a place outside the diff. Every line is a code cell carrying its file, line and
// commit, so space k and the g keys work inside it and keep going from wherever they land.
import { createEffect, createMemo, Index, Show, type JSX } from "solid-js";
import { highlight, langOf } from "./review/highlight";
import { notePointer } from "./review/types";

const short = (ref: string) => ref.replace(/^([0-9a-f]{10})[0-9a-f]{30}$/, "$1");

export default function CodePane(props: { path: string; refLabel: string; text?: string; err?: string; lit?: [number, number]; repo: string; sha: string; close?: JSX.Element }) {
  let pane: HTMLDivElement | undefined;
  const lines = createMemo(() => (props.text ?? "").replace(/\n$/, "").split("\n"));
  const lang = () => langOf(props.path);
  const lit = (n: number) => !!props.lit && n >= props.lit[0] && n <= props.lit[1];
  createEffect(() => {
    lines();
    const start = props.lit?.[0];
    if (!start || !pane) return;
    requestAnimationFrame(() => pane?.querySelector(`[data-line="${start}"]`)?.scrollIntoView({ block: "center" }));
  });
  return (
    <div class="flex min-h-0 flex-col bg-diff-bg max-[900px]:max-h-[50vh]">
      <div class="flex items-baseline justify-between gap-3 border-b border-rule bg-vellum-raise px-4 py-2 text-[11px]">
        <span class="truncate text-ink-dim">{props.path}</span>
        <span class="shrink-0 text-ink-faint">
          {props.lit ? `L${props.lit[0]}–${props.lit[1]} · ` : ""}
          {short(props.refLabel)}
        </span>
        {props.close}
      </div>
      <div ref={pane} class="min-h-0 flex-1 overflow-auto py-1.5 text-[11.5px] leading-[1.6]" onPointerMove={notePointer}>
        <Show when={!props.err} fallback={<p class="m-0 px-4 text-[12px] text-del">{props.err}</p>}>
          <Show when={props.text != null} fallback={<p class="m-0 px-4 text-[12px] text-ink-faint">reading {props.path}…</p>}>
            <Index each={lines()}>
              {(text, i) => (
                <div data-line={i + 1} class="flex" classList={{ "bg-gold-wash": lit(i + 1) }}>
                  <span class="w-[48px] shrink-0 select-none pr-3 text-right text-ink-faint">{i + 1}</span>
                  <code
                    data-code
                    data-path={props.path}
                    data-line={i + 1}
                    data-side="new"
                    data-sha={props.sha}
                    data-repo={props.repo}
                    class="whitespace-pre pr-3"
                    classList={{ "text-ink": lit(i + 1), "text-ink-dim": !lit(i + 1) }}
                    innerHTML={highlight(text(), lang())}
                  />
                </div>
              )}
            </Index>
          </Show>
        </Show>
      </div>
    </div>
  );
}
