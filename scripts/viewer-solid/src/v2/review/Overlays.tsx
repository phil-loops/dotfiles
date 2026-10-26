// The review page's overlays: the words (`e`) and the forest map (`m`). Each closes on esc; keys
// inside them go through the runner like everywhere else.
import { createMemo, createResource, createSignal, For, onMount, Show } from "solid-js";
import { model } from "../model";
import { keyOf } from "../registry";
import { bind, dispatch } from "../runner";
import { leaf, SHIP } from "../ship";
import { list, view } from "../store";
import { getJSON } from "../sync";
import Commits from "../Commits";
import { plain } from "./markdown";
import type { Thread } from "../types";
import { shown, type Outline } from "../words";
import { atRepoPath, page as pg, short } from "./page";

export function Words() {
  const desc = () => view("branch", pg.id())?.description ?? "";
  return (
    <aside class="rv-words" role="dialog" aria-label="The words">
      <div class="rv-sheet-head">
        words
      </div>
      <div class="rv-words-k">description</div>
      <p class="font-display text-[16px] italic">{desc() || "—"}</p>
      <Commits branchId={pg.id()} landing />
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
    else if (e.key === "p") dispatch("review.leave", "key", { target: pg.id(), event: e });
    else return;
    e.preventDefault();
  };
  return (
    <div class="rv-scrim">
      <div class="rv-map" ref={box} tabIndex={0} onKeyDown={onKey} role="dialog" aria-label="The forest">
        <div class="rv-sheet-head">
          forest{" "}
          <button class="rv-quietbtn" onClick={bind("review.leave", pg.id())}>
            p page
          </button>
        </div>
        <For each={rows()} fallback={<p class="text-ink-faint">nothing else</p>}>
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

/** E on a thread: who writes its fix. Claude (a fresh session in the branch's worktree, the prompt
 *  drafted unsent), you in Helix, or — once a commit exists — pick it, which writes the commit's
 *  `Addresses:` trailer. Keys belong to the sheet while it's open: ↵ or c, o, p, 1–9, esc. */
export function AddressSheet() {
  const id = () => pg.addressing() ?? "";
  const t = () => view("thread", id()) as Thread | undefined;
  const picking = () => pg.addressPicking();
  const b = () => view("branch", pg.id());
  const [o] = createResource(
    () => (picking() && b() ? `${b()!.repo}|${b()!.name}|${b()!.tip}` : null),
    async () => {
      const got = await getJSON<Outline>(atRepoPath(b()!.repo, `/outline?branch=${encodeURIComponent(b()!.name)}`)).catch(() => null);
      if (got) shown.set(pg.id(), got);
      return got;
    },
  );
  const candidates = () => (o()?.commits ?? []).filter((c) => !c.locked).reverse().slice(0, 9);
  let box!: HTMLDivElement;
  onMount(() => requestAnimationFrame(() => box.focus({ preventScroll: true })));
  const onKey = (e: KeyboardEvent) => {
    e.stopPropagation();
    const n = Number(e.key);
    if (e.key === "Escape") {
      pg.setOverlay(null);
      pg.setAddressing(null);
      pg.setAddressPicking(false);
    } else if (!picking() && (e.key === "Enter" || e.key === "c")) dispatch("review.address.claude", "key", { target: id(), event: e });
    else if (!picking() && e.key === "o") dispatch("review.address.helix", "key", { target: id(), event: e });
    else if (e.key === "p") dispatch("review.address.pick.list", "key", { target: id(), event: e });
    else if (picking() && n >= 1 && n <= candidates().length) dispatch("review.address.pick", "key", { target: `${id()} ${candidates()[n - 1].sha}`, event: e });
    else return;
    e.preventDefault();
  };
  return (
    <div class="rv-scrim">
      <div class="rv-map" ref={box} tabIndex={0} onKeyDown={onKey} role="dialog" aria-label="Address it">
        <div class="rv-sheet-head">
          Address it <span class="text-ink-faint">· {t()?.comments[0]?.author} on {t()?.path.split("/").pop()}</span>
        </div>
        <p class="m-0 mb-3 text-[12px] text-ink-dim">{plain(t()?.comments[0]?.body ?? "", 160)}</p>
        <Show
          when={picking()}
          fallback={
            <>
              <button class="rv-map-row" onClick={bind("review.address.claude", id())}>
                <span class="text-gold-leaf">↵ c</span> claude
              </button>
              <button class="rv-map-row" onClick={bind("review.address.helix", id())}>
                <span class="text-gold-leaf">o</span> helix
              </button>
              <button class="rv-map-row" onClick={bind("review.address.pick.list", id())}>
                <span class="text-gold-leaf">p</span> pick its commit
              </button>
            </>
          }
        >
          <Show when={o()} fallback={<p class="text-ink-faint">{o.loading ? "reading the commits…" : "couldn't read the commits"}</p>}>
            <For each={candidates()} fallback={<p class="text-ink-faint">no unpushed commits</p>}>
              {(c, i) => (
                <button class="rv-map-row" onClick={bind("review.address.pick", `${id()} ${c.sha}`)}>
                  <span class="text-gold-leaf">{i() + 1}</span> <code class="text-gold-leaf">{c.short.slice(0, 7)}</code> {c.subject}
                </button>
              )}
            </For>
          </Show>
        </Show>
      </div>
    </div>
  );
}
