// The review page's overlays: Finish your review (GitHub's dropdown), the words (`e`), and the forest
// map (`m`). Each closes on esc; keys inside them go through the runner like everywhere else.
import { createMemo, createResource, createSignal, For, onMount, Show } from "solid-js";
import { model } from "../model";
import { bind, dispatch } from "../runner";
import { leaf, SHIP } from "../ship";
import { list, view } from "../store";
import { getJSON } from "../sync";
import { atRepoPath, page as pg, short } from "./page";

const EVENTS = [
  { id: "COMMENT", title: "Comment", says: "Submit general feedback without explicit approval." },
  { id: "APPROVE", title: "Approve", says: "Give feedback and approve merging these changes." },
  { id: "REQUEST_CHANGES", title: "Request changes", says: "Submit feedback that must be addressed before merging." },
] as const;

export function FinishSheet() {
  let ta!: HTMLTextAreaElement;
  onMount(() => ta.focus());
  const own = () => !!pg.conv() && pg.conv()!.author === pg.conv()!.viewer;
  const pending = () => pg.draft()?.comments.length ?? 0;
  const onKey = (e: KeyboardEvent) => {
    if (e.key === "Escape") {
      e.preventDefault();
      dispatch("review.back", "key", { event: e });
    } else if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
      e.preventDefault();
      dispatch("review.submit", "key", { event: e });
    } else if (e.altKey && ["Digit1", "Digit2", "Digit3"].includes(e.code)) {
      e.preventDefault();
      const ev = EVENTS[+e.code.slice(5) - 1];
      if (!own() || ev.id === "COMMENT") dispatch(`review.event.${ev.id}`, "key", { event: e });
    }
  };
  return (
    <div class="rv-sheet" role="dialog" aria-label="Finish your review">
      <div class="rv-sheet-head">
        Finish your review
        <span class="text-ink-faint">{pending() ? ` · ${pending()} pending comment${pending() === 1 ? "" : "s"} go with it` : ""}</span>
      </div>
      <textarea
        ref={ta}
        class="rv-textarea"
        rows={5}
        placeholder="Leave a comment"
        value={pg.text("finish")}
        onInput={(e) => pg.setText("finish", e.currentTarget.value)}
        onKeyDown={onKey}
      />
      <For each={EVENTS}>
        {(ev, i) => (
          <button
            class="rv-radio"
            classList={{ "rv-radio-on": pg.event() === ev.id, "rv-radio-off": own() && ev.id !== "COMMENT" }}
            disabled={own() && ev.id !== "COMMENT"}
            onClick={bind(`review.event.${ev.id}`)}
          >
            <span class="rv-radio-dot">{pg.event() === ev.id ? "◉" : "○"}</span>
            <span>
              <b>{ev.title}</b> <kbd>⌥{i() + 1}</kbd>
              <br />
              <span class="text-ink-faint">{own() && ev.id !== "COMMENT" ? "You can't do this on your own pull request." : ev.says}</span>
            </span>
          </button>
        )}
      </For>
      <div class="rv-c-actions">
        <span class="flex-1" />
        <button class="rv-quietbtn" onClick={bind("review.back")}>Cancel esc</button>
        <button class="rv-btn rv-btn-gold" onClick={bind("review.submit")}>
          Submit review <kbd>⌘↵</kbd>
        </button>
      </div>
    </div>
  );
}

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
  onMount(() => box.focus());
  const onKey = (e: KeyboardEvent) => {
    e.stopPropagation();
    if (e.key === "j" || e.key === "ArrowDown") setI((n) => Math.min(rows().length - 1, n + 1));
    else if (e.key === "k" || e.key === "ArrowUp") setI((n) => Math.max(0, n - 1));
    else if (e.key === "Enter" && rows()[i()]) dispatch("review.map.go", "key", { target: rows()[i()].id, event: e });
    else if (e.key === "Escape" || e.key === "m") dispatch("review.map", "key", { event: e });
    else return;
    e.preventDefault();
  };
  return (
    <div class="rv-scrim">
      <div class="rv-map" ref={box} tabIndex={0} onKeyDown={onKey} role="dialog" aria-label="The forest">
        <div class="rv-sheet-head">
          The forest <span class="text-ink-faint">· j/k · ↵ opens · esc</span>
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
