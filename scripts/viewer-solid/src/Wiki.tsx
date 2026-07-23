// The wiki — durable prose about this repo, living where the forest lives instead of in a
// throwaway artifact. Two kinds of page, from one frontmatter field (see srv/wiki.py):
//
//   map     describes code that EXISTS; every claim carries a citation that resolves
//   design  describes code that DOESN'T yet, bound to a forest; nothing to cite
//
// Citations render as inline buttons. Clicking one pulls the real lines from origin/main —
// never the working tree, which is routinely on somebody's feature branch — so a page means
// the same thing regardless of what is checked out.
import { createResource, createSignal, For, Show, createMemo } from "solid-js";
import { fetchJSON } from "./api";
import { renderMarkdown } from "./markdown";
import { useViewerLocation, Link } from "./router";

type WikiPage = {
  slug: string;
  title: string;
  section: string;
  order: number;
  ask: string;
  lede: string;
  project: string;
  kind: "map" | "design";
  body: string;
  words: number;
};

type PagesReply = {
  pages: WikiPage[]; ref: string; repo: string; problems: string[]; err?: string;
  searched?: string[]; // where pages were looked for
  roots?: string[]; // which of those exist — none, with pages empty, is a misconfiguration
};
type SrcReply = { path: string; start: number; end: number; from: number; text: string; kind: string; ref: string; err?: string };

const CITE = /\[([^\]]+)\]\(src:([^)\s]+)\)/g;
const WIKILINK = /\[\[([a-z0-9-]+)\]\]/g;

// Citations and wikilinks are ours, not markdown's — swap them for real markup before marked
// sees them, so the renderer never has to know about `src:` or `[[…]]`.
function prepare(body: string): string {
  return body
    .replace(CITE, (_m, label, anchor) =>
      `<button class="wiki-cite" data-anchor="${anchor}" title="${anchor}">${label}</button>`)
    .replace(WIKILINK, (_m, slug) =>
      `<a class="wiki-link" href="/wiki/${slug}" data-slug="${slug}">${slug.replace(/-/g, " ")}</a>`);
}

export function Wiki() {
  const { location, navigate } = useViewerLocation();
  const [pages] = createResource(() => fetchJSON<PagesReply>("/wiki-pages"));
  const [source, setSource] = createSignal<{ anchor: string; data: SrcReply } | null>(null);

  const all = () => pages()?.pages ?? [];
  const current = createMemo(() => {
    const loc = location();
    const slug = loc.kind === "wiki" ? loc.slug : undefined;
    return all().find((p) => p.slug === slug) ?? all()[0];
  });

  // Sections in first-appearance order — `order` frontmatter already sorted the pages, so the
  // grouping inherits that sequence without a second sort key to keep in step.
  const sections = createMemo(() => {
    const out: { name: string; pages: WikiPage[] }[] = [];
    for (const p of all()) {
      const hit = out.find((s) => s.name === p.section);
      if (hit) hit.pages.push(p);
      else out.push({ name: p.section, pages: [p] });
    }
    return out;
  });

  const onBodyClick = async (e: MouseEvent) => {
    const el = (e.target as HTMLElement).closest("[data-anchor], [data-slug]") as HTMLElement | null;
    if (!el) return;
    e.preventDefault();
    const slug = el.dataset.slug;
    if (slug) {
      setSource(null);
      navigate({ kind: "wiki", slug });
      return;
    }
    const anchor = el.dataset.anchor!;
    if (source()?.anchor === anchor) {
      setSource(null); // clicking the open citation closes it
      return;
    }
    const data = await fetchJSON<SrcReply>(`/wiki-src?anchor=${encodeURIComponent(anchor)}`);
    setSource({ anchor, data });
  };

  return (
    <div class="wiki grid grid-cols-[220px_1fr] max-[860px]:grid-cols-[1fr] gap-0 min-h-screen">
      <nav class="wiki-rail border-r border-rule px-4 py-6 max-[860px]:border-r-0 max-[860px]:border-b">
        <div class="font-mono text-[10px] tracking-[0.14em] uppercase text-ink-faint mb-4">
          {pages()?.repo ?? ""} wiki
        </div>
        <For each={sections()}>
          {(section) => (
            <div class="mb-5">
              <div class="font-display text-[13px] text-ink-dim mb-1.5">{section.name}</div>
              <For each={section.pages}>
                {(p) => (
                  <Link
                    to={{ kind: "wiki", slug: p.slug }}
                    class="block py-1 text-[13px] leading-snug"
                    classList={{
                      "text-gold-leaf": current()?.slug === p.slug,
                      "text-ink-dim hover:text-ink": current()?.slug !== p.slug,
                    }}
                  >
                    {p.title}
                    <Show when={p.kind === "design"}>
                      <span class="ml-1.5 font-mono text-[9px] tracking-wider uppercase text-ember">plan</span>
                    </Show>
                  </Link>
                )}
              </For>
            </div>
          )}
        </For>
      </nav>

      <article class="wiki-body min-w-0 px-8 py-8 max-w-[70ch]">
        <Show when={pages.loading}>
          <div class="text-ink-faint text-sm">reading pages…</div>
        </Show>
        <Show when={pages()?.err}>
          <div class="text-del text-sm font-mono">{pages()!.err}</div>
        </Show>
        {/* An empty wiki must never render as a calm blank page — say whether this repo
            simply has no pages yet, or whether the lookup is pointing at nothing. */}
        <Show when={pages() && !pages()!.err && pages()!.pages.length === 0}>
          <div class="border border-del rounded-sm p-4">
            <div class="font-display text-[17px] text-ink mb-2">
              No pages for <span class="font-mono text-gold-leaf">{pages()!.repo}</span>
            </div>
            <Show
              when={(pages()!.roots ?? []).length === 0}
              fallback={<p class="text-[14px] text-ink-dim m-0">Add a markdown file to {pages()!.roots?.[0]}</p>}
            >
              <p class="text-[14px] text-ink-dim m-0">
                None of these directories exist — the wiki is looking in the wrong place:
              </p>
              <ul class="mt-2 mb-0 font-mono text-[12px] text-del">
                <For each={pages()!.searched ?? []}>{(d) => <li>{d}</li>}</For>
              </ul>
            </Show>
          </div>
        </Show>
        <Show when={current()}>
          {(page) => (
            <>
              <header class="mb-6 pb-4 border-b border-rule">
                <div class="flex items-baseline gap-3 mb-2">
                  <span class="font-mono text-[10px] tracking-[0.14em] uppercase text-ink-faint">
                    {page().section}
                  </span>
                  <Show when={page().kind === "design"}>
                    <Link
                      to={{ kind: "forest", name: page().project }}
                      class="font-mono text-[10px] tracking-[0.14em] uppercase text-ember hover:text-gold-leaf"
                      title="the forest this plan describes"
                    >
                      plan · {page().project}
                    </Link>
                  </Show>
                </div>
                <h1 class="font-display text-[26px] leading-tight text-ink mb-2">{page().title}</h1>
                <Show when={page().lede}>
                  <p class="text-[15px] leading-relaxed text-ink-dim m-0">{page().lede}</p>
                </Show>
              </header>

              {/* innerHTML: same trust boundary as the chat panel — our own markdown files,
                  read off local disk, rendered by the same marked instance. */}
              <div class="wiki-prose" onClick={onBodyClick} innerHTML={renderMarkdown(prepare(page().body))} />

              <Show when={source()}>
                {(hit) => (
                  <figure class="mt-6 border border-rule rounded-sm overflow-hidden">
                    <figcaption class="flex items-baseline justify-between gap-3 px-3 py-2 bg-vellum-raise border-b border-rule font-mono text-[11px]">
                      <span class="text-ink-dim truncate">{hit().data.path}</span>
                      <span class="text-ink-faint shrink-0">
                        {hit().data.err ? "unresolved" : `${hit().data.start}–${hit().data.end} @ ${hit().data.ref}`}
                      </span>
                    </figcaption>
                    <Show when={hit().data.err} fallback={
                      <pre class="cp-pre m-0 text-[12px] overflow-x-auto"><code>{hit().data.text}</code></pre>
                    }>
                      <div class="px-3 py-2 text-[12px] font-mono text-del">{hit().data.err}</div>
                    </Show>
                  </figure>
                )}
              </Show>

              <footer class="mt-8 pt-3 border-t border-rule font-mono text-[10px] text-ink-faint">
                {page().words} words
                <Show when={page().kind === "map"}> · citations resolve against {pages()?.ref}</Show>
              </footer>
            </>
          )}
        </Show>
      </article>
    </div>
  );
}
