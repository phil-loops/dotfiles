// The wiki: durable prose about the repo (srv/wiki.py). A map page describes code that exists and
// cites it — a citation opens its lines from origin/main beside the page, never the working tree,
// so a page reads the same whatever is checked out. A plan page describes code that doesn't exist
// yet, bound to its forest. The list on the left is the cursor's: j/k move, ↵ opens.
import { createEffect, For, on, onCleanup, onMount, Show } from "solid-js";
import { model } from "./model";
import { highlight, langOf } from "./review/highlight";
import { bind, dispatch } from "./runner";
import { sectionsOf, wikiHtml, type SrcReply } from "./wikitext";
import { wiki, wkey } from "./wikiread";
import { setCursor } from "./ui";

const LABEL = "text-[11px] font-normal uppercase tracking-[0.14em] text-ink-faint";

function List() {
  const current = () => wiki.current()?.slug;
  return (
    <nav class="sticky top-0 max-h-[calc(100vh-3.5rem)] overflow-y-auto pb-6 pl-4 pr-2 max-[860px]:static max-[860px]:max-h-[40vh] max-[860px]:border-b max-[860px]:border-rule" aria-label="pages">
      <For each={sectionsOf(wiki.pages())}>
        {(s) => (
          <section class="mb-4">
            <h2 class={`m-0 mb-1 pl-3 ${LABEL}`}>{s.name}</h2>
            <For each={s.pages}>
              {(p) => {
                const on = () => model.selected() === wkey(p.slug);
                return (
                  <div
                    data-row={wkey(p.slug)}
                    class="flex cursor-default items-baseline gap-2 border-l-2 py-[3px] pl-[10px] pr-2 text-[12.5px] leading-snug transition-colors duration-150"
                    classList={{
                      "border-gold-leaf bg-gold-wash": on(),
                      "border-transparent hover:bg-vellum-raise": !on(),
                      "text-gold-leaf": current() === p.slug,
                      "text-ink-dim": current() !== p.slug,
                    }}
                    onClick={bind("wiki.open", p.slug)}
                  >
                    <span class="min-w-0 flex-1">{p.title}</span>
                    <Show when={p.kind === "design"}>
                      <span class="shrink-0 text-[9.5px] uppercase tracking-wider text-ember" title={`a plan for ${p.project}`}>
                        plan
                      </span>
                    </Show>
                  </div>
                );
              }}
            </For>
          </section>
        )}
      </For>
    </nav>
  );
}

/** A citation's lines, the cited ones lit, a few either side for context. */
function Source(props: { anchor: string; src?: SrcReply }) {
  const lines = () => (props.src?.text ?? "").split("\n");
  const lang = () => langOf(props.src?.path ?? "");
  return (
    <figure class="m-0 border border-rule bg-diff-bg">
      <figcaption class="flex items-baseline gap-3 border-b border-rule bg-vellum-raise px-3 py-1.5 text-[11px]">
        <span class="min-w-0 flex-1 truncate text-ink-dim" title={props.anchor}>
          {props.src?.path ?? props.anchor}
        </span>
        <span class="shrink-0 text-ink-faint">
          {!props.src ? "…" : props.src.err ? "unresolved" : `${props.src.start}–${props.src.end} · ${props.src.ref}`}
        </span>
      </figcaption>
      <Show when={props.src && !props.src.err} fallback={<p class="m-0 px-3 py-2 text-[12px] text-del">{props.src?.err}</p>}>
        <pre class="m-0 max-h-[70vh] overflow-auto max-[1280px]:max-h-[38vh] py-1.5 text-[11.5px] leading-[1.6]">
          <For each={lines()}>
            {(text, i) => {
              const n = () => props.src!.from + i();
              const lit = () => n() >= props.src!.start && n() <= props.src!.end;
              return (
                <div class="flex" classList={{ "bg-gold-wash": lit() }}>
                  <span class="w-[44px] shrink-0 select-none pr-3 text-right text-ink-faint">{n()}</span>
                  <code class="whitespace-pre pr-3" classList={{ "text-ink": lit(), "text-ink-dim": !lit() }} innerHTML={highlight(text, lang())} />
                </div>
              );
            }}
          </For>
        </pre>
      </Show>
    </figure>
  );
}

function Empty() {
  const r = () => wiki.read()!;
  return (
    <div class="border border-del/70 px-4 py-3">
      <p class="m-0 mb-1 font-display text-[17px] text-ink">no pages for {r().repo}</p>
      <Show when={(r().roots ?? []).length === 0} fallback={<p class="m-0 text-ink-dim">add a markdown file to {r().roots![0]}</p>}>
        <p class="m-0 text-ink-dim">none of these exist — the wiki is looking in the wrong place:</p>
        <ul class="m-0 mt-1 text-del">
          <For each={r().searched ?? []}>{(d) => <li>{d}</li>}</For>
        </ul>
      </Show>
    </div>
  );
}

function Article() {
  let prose: HTMLDivElement | undefined;
  const page = () => wiki.current()!;
  const titleOf = (slug: string) => wiki.page(slug)?.title;
  // the body is rendered HTML, so its citations and wikilinks dispatch through one listener here
  onMount(() => {
    const click = (e: MouseEvent) => {
      const el = (e.target as HTMLElement).closest<HTMLElement>("[data-anchor], [data-slug]");
      if (!el) return;
      e.preventDefault();
      if (el.dataset.slug) dispatch("wiki.open", "click", { target: el.dataset.slug, event: e });
      else dispatch("wiki.cite", "click", { target: el.dataset.anchor, event: e });
    };
    prose!.addEventListener("click", click);
    onCleanup(() => prose?.removeEventListener("click", click));
  });
  createEffect(() => {
    const open = wiki.cite()?.anchor;
    page();
    prose?.querySelectorAll<HTMLElement>("[data-anchor]").forEach((b) => b.classList.toggle("wk-on", b.dataset.anchor === open));
  });
  return (
    <article class="min-w-0 max-w-[72ch]">
      <header class="mb-6 border-b border-rule pb-4">
        <div class="mb-2 flex items-baseline gap-3">
          <span class={LABEL}>{page().section}</span>
          <Show when={page().kind === "design"}>
            <button class="text-[11px] uppercase tracking-[0.14em] text-ember hover:text-gold-leaf" title="the forest this plan describes" onClick={bind("wiki.forest")}>
              plan · {page().project}
            </button>
          </Show>
        </div>
        <h1 class="m-0 mb-2 font-display text-[26px] font-normal leading-tight text-ink">{page().title}</h1>
        <Show when={page().lede}>
          <p class="m-0 text-[14px] leading-relaxed text-ink-dim">{page().lede}</p>
        </Show>
      </header>
      <div ref={prose} class="md wk-prose" innerHTML={wikiHtml(page().body, titleOf)} />
      <footer class="mt-8 border-t border-rule pt-3 text-[11px] text-ink-faint">
        {page().words} words
        <Show when={page().kind === "map"}> · citations resolve against {wiki.read()?.ref}</Show>
      </footer>
    </article>
  );
}

export default function Wiki() {
  onMount(() => wiki.load());
  // the page the URL names is the one under the cursor when it opens, and reads from the top
  createEffect(
    on(
      () => wiki.current()?.slug,
      (slug) => {
        if (!slug) return;
        setCursor(wkey(slug));
        wiki.showCite(undefined);
        window.scrollTo(0, 0);
      },
    ),
  );
  return (
    <Show when={wiki.read()} fallback={<p class="px-4 pl-11 text-ink-faint">reading pages…</p>}>
      <div data-paint="wiki" class="grid grid-cols-[240px_minmax(0,1fr)] gap-x-10 max-[860px]:grid-cols-1">
        <List />
        <div class="grid min-w-0 grid-cols-[minmax(0,72ch)_minmax(0,1fr)] gap-x-8 pr-4 max-[1280px]:grid-cols-1 max-[860px]:px-4 max-[860px]:pt-4">
          <Show when={!wiki.read()!.err} fallback={<p class="m-0 text-del">{wiki.read()!.err}</p>}>
            <Show when={wiki.pages().length} fallback={<Empty />}>
              <Show when={wiki.current()} fallback={<p class="m-0 text-ink-faint">no such page</p>}>
                <Article />
              </Show>
            </Show>
          </Show>
          <Show when={wiki.cite()}>
            {(c) => (
              <aside class="sticky top-4 self-start max-[1280px]:fixed max-[1280px]:bottom-4 max-[1280px]:left-4 max-[1280px]:right-4 max-[1280px]:top-auto max-[1280px]:z-20 max-[1280px]:shadow-2xl">
                <Source anchor={c().anchor} src={c().src} />
              </aside>
            )}
          </Show>
        </div>
      </div>
    </Show>
  );
}
