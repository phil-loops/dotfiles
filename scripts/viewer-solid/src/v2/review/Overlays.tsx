// The review page's overlays: the words (`e`) and the forest map (`m`). Each closes on esc; keys
// inside them go through the runner like everywhere else.
import { createMemo, createResource, createSignal, For, onMount, Show } from "solid-js";
import { model } from "../model";
import { bind, dispatch } from "../runner";
import { leaf, SHIP } from "../ship";
import { list, view } from "../store";
import { getJSON } from "../sync";
import { atRepoPath, page as pg, short } from "./page";

interface Outline {
  description: string;
  commits: { short: string; subject: string; pushed: boolean }[];
  draft?: { title?: string };
}

export function Words() {
  const t = () => pg.target()!;
  const [o] = createResource(
    () => `${t().repo}:${t().name}@${pg.tip()}`,
    () => getJSON<Outline>(atRepoPath(t().repo, `/outline?branch=${encodeURIComponent(t().name)}`)).catch(() => null),
  );
  const desc = () => view("branch", pg.id())?.description ?? o()?.description ?? "";
  return (
    <aside class="rv-words" role="dialog" aria-label="The words">
      <div class="rv-sheet-head">
        The words <span class="text-ink-faint">· e closes</span>
      </div>
      <div class="rv-words-k">description</div>
      <p class="font-display text-[16px] italic">{desc() || "—"}</p>
      <div class="rv-words-k">lands on main as</div>
      <p>{o()?.draft?.title || pg.conv()?.title || "—"}</p>
      <div class="rv-words-k">outline</div>
      <Show when={o()} fallback={<p class="text-ink-faint">reading…</p>}>
        <For each={o()!.commits}>
          {(c) => (
            <div class="rv-words-commit">
              <code class={c.pushed ? "text-ink-faint" : "text-gold-leaf"}>{c.short.slice(0, 7)}</code> {c.subject}
              <Show when={!c.pushed}>
                <span class="text-ink-faint"> · local</span>
              </Show>
            </div>
          )}
        </For>
      </Show>
      <Show when={pg.conv()?.unpushed.length}>
        <p class="text-ink-faint">
          {pg.conv()!.unpushed.length} commit{pg.conv()!.unpushed.length === 1 ? "" : "s"} past the PR head ({short(pg.conv()!.head)}) aren't on GitHub yet.
        </p>
      </Show>
    </aside>
  );
}

export function MapOverlay() {
  const here = () => pg.id();
  const rows = createMemo(() => {
    const b = view("branch", here());
    const out: { id: string; label: string; depth: number; word: string; threads: number }[] = [];
    const open = (id: string) => list("thread").filter((t) => `${t.repo}:${t.branch}` === id && !t.resolved && !t.outdated).length;
    if (b) {
      const f = model.forests().get(b.project);
      const depth = (id: string | null, n = 0): number => {
        const p = id ? view("branch", id) : undefined;
        return p && n < 32 ? depth(p.parentId, n + 1) : n;
      };
      for (const v of f?.branches ?? []) {
        if (v.st.ship === "landed") continue;
        out.push({ id: v.b.id, label: v.b.name, depth: depth(v.b.parentId), word: SHIP[v.st.ship].word, threads: open(v.b.id) });
      }
    }
    for (const c of list("conv")) {
      if (out.some((x) => x.id === c.id)) continue;
      if (b && view("branch", c.id)?.project === b.project) continue;
      out.push({ id: c.id, label: `#${c.number} ${c.title}`, depth: 0, word: c.author === c.viewer ? "yours" : `@${c.author}`, threads: open(c.id) });
    }
    return out;
  });
  const [i, setI] = createSignal(Math.max(0, rows().findIndex((r) => r.id === here())));
  let box!: HTMLDivElement;
  // focusing forces a layout of the whole diff behind the scrim: let the overlay paint first
  onMount(() => requestAnimationFrame(() => box.focus({ preventScroll: true })));
  const onKey = (e: KeyboardEvent) => {
    e.stopPropagation();
    if (e.key === "j" || e.key === "ArrowDown") setI((n) => Math.min(rows().length - 1, n + 1));
    else if (e.key === "k" || e.key === "ArrowUp") setI((n) => Math.max(0, n - 1));
    else if (e.key === "Enter" && rows()[i()]) dispatch("review.map.go", "key", { target: rows()[i()].id, event: e });
    else if (e.key === "Escape" || e.key === "m") dispatch("review.map", "key", { event: e });
    else if (e.key === "p") dispatch("review.forest", "key", { target: pg.id(), event: e });
    else return;
    e.preventDefault();
  };
  return (
    <div class="rv-scrim">
      <div class="rv-map" ref={box} tabIndex={0} onKeyDown={onKey} role="dialog" aria-label="The forest">
        <div class="rv-sheet-head">
          The forest <span class="text-ink-faint">· j/k · ↵ opens · esc ·</span>{" "}
          <button class="rv-quietbtn" onClick={bind("review.forest", pg.id())}>
            p its page
          </button>
        </div>
        <For each={rows()} fallback={<p class="text-ink-faint">nothing else to review</p>}>
          {(r, n) => (
            <button
              class="rv-map-row"
              classList={{ "rv-on": n() === i(), "rv-map-here": r.id === here() }}
              style={{ "padding-left": `${12 + r.depth * 16}px` }}
              onClick={bind("review.map.go", r.id)}
            >
              <span class="truncate">{r.depth ? "└ " : ""}{leaf(r.label)}</span>
              <span class="flex-1" />
              <Show when={r.threads}>
                <span class="rv-dot">{r.threads}</span>
              </Show>
              <span class="text-ink-faint">{r.word}</span>
            </button>
          )}
        </For>
      </div>
    </div>
  );
}
