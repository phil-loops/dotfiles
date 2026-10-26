// One commit's change to one file, drawn inline under its message on the Commits tab: the same rows
// as Files changed (unified or split, highlighted), its hidden context expandable, and — when no
// later commit touches the file, so this commit's lines are the tip's — the threads anchored there.
import { createMemo, For, Show } from "solid-js";
import { bind } from "../runner";
import { list } from "../store";
import type { Thread } from "../types";
import { expand, rowAnchors, splitRows, unifiedRows, type FileDiff, type Gap, type Line } from "./diff";
import { highlight, langOf } from "./highlight";
import { fileKey, reveals, texts } from "./inline";
import { page as pg } from "./page";
import { ThreadView } from "./Thread";

function Code(props: { line: Line; lang: string }) {
  return <span class="rv-code" innerHTML={highlight(props.line.text, props.lang) || " "} />;
}

export default function InlineDiff(props: { sha: string; file: FileDiff; stable: boolean }) {
  const k = () => fileKey(props.sha, props.file.path);
  const lang = langOf(props.file.path);
  const shown = createMemo(() => expand(props.file, texts().get(k()), reveals().get(k()) ?? new Map()));
  const rows = createMemo(() => (pg.split() ? splitRows(shown().file) : unifiedRows(shown().file)));
  const gapAt = (at: number) => shown().gaps.find((g) => g.at === at);
  // a thread's line is the tip's; it lines up here only when the file at this commit is the file at the tip
  const threadsAt = createMemo(() => {
    const out = new Map<string, Thread[]>();
    if (!props.stable) return out;
    for (const t of list("thread") as Thread[]) {
      if (t.path !== props.file.path || t.branch !== pg.target()?.name || !t.local || (t.outdated && !pg.showOutdated())) continue;
      const a = `${t.side === "LEFT" ? "L" : "R"}:${t.local.line}`;
      out.set(a, [...(out.get(a) ?? []), t]);
    }
    return out;
  });
  const gapRow = (g: Gap) => (
    <div class="rv-hunk rv-gap" onClick={bind("inline.expand", `${props.sha}|${props.file.path}|${g.at}`)} title="show 20 more lines">
      <span class="rv-gap-mark">⋯</span> {g.last == null ? "more lines" : `${g.last - g.first + 1} unchanged lines`}
      <Show when={g.label}>
        <span class="text-ink-faint"> · {g.label}</span>
      </Show>
    </div>
  );
  return (
    <section class="rv-file mb-3">
      <div class="rv-fhead">
        <span>{props.file.path}</span>
        <span class="text-add">+{props.file.add}</span>
        <span class="text-del">−{props.file.del}</span>
      </div>
      <div class="rv-diff" classList={{ "rv-split": pg.split() }}>
        <For each={rows()}>
          {(r, i) => (
            <>
              <Show when={(i() === 0 || rows()[i() - 1].hunk !== r.hunk) && gapAt(r.hunk)} keyed>
                {(g) => gapRow(g)}
              </Show>
              <div class="rv-row">
                <Show
                  when={pg.split()}
                  fallback={
                    <>
                      <span />
                      <span class="rv-num">{r.left?.old ?? ""}</span>
                      <span class="rv-num">{r.right?.new ?? ""}</span>
                      <span class={`rv-sign rv-${(r.left ?? r.right)!.kind === "ctx" ? "ctx" : r.right ? "add" : "del"}`}>{r.right && r.left ? " " : r.right ? "+" : "−"}</span>
                      <span class={`rv-line rv-${r.left && r.right ? "ctx" : r.right ? "add" : "del"}`}>
                        <Code line={(r.right ?? r.left)!} lang={lang} />
                      </span>
                    </>
                  }
                >
                  <span />
                  <span class="rv-num">{r.left?.old ?? ""}</span>
                  <span class={`rv-line rv-half rv-${!r.left ? "none" : r.left.kind === "ctx" ? "ctx" : "del"}`}>
                    <Show when={r.left}>
                      <Code line={r.left!} lang={lang} />
                    </Show>
                  </span>
                  <span class="rv-num">{r.right?.new ?? ""}</span>
                  <span class={`rv-line rv-half rv-${!r.right ? "none" : r.right.kind === "ctx" ? "ctx" : "add"}`}>
                    <Show when={r.right}>
                      <Code line={r.right!} lang={lang} />
                    </Show>
                  </span>
                </Show>
              </div>
              <For each={rowAnchors(r).flatMap((a) => threadsAt().get(a) ?? [])}>{(t) => <ThreadView id={t.id} selected={() => false} />}</For>
            </>
          )}
        </For>
        <Show when={gapAt(shown().file.hunks.length)} keyed>
          {(g) => gapRow(g)}
        </Show>
      </div>
    </section>
  );
}
