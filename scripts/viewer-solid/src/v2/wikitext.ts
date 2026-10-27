// The wiki's pages as the page draws them (srv/wiki.py): grouped by section in the server's order,
// and a body's two kinds of link — a citation `[label](src:<anchor>)` (a map page's claim, resolved
// against origin/main on click) and a wikilink `[[slug]]` — swapped for markup around the shared
// markdown renderer, which escapes everything else. Pure.
import { inline, renderMarkdown } from "./review/markdown.ts";

export interface WikiPage {
  slug: string;
  title: string;
  section: string;
  order: number;
  lede: string;
  /** a design page's forest; empty on a map page */
  project: string;
  kind: "map" | "design";
  body: string;
  words: number;
}
export interface PagesReply {
  pages: WikiPage[];
  ref: string;
  repo: string;
  problems: string[];
  err?: string;
  /** where pages were looked for, and which of those exist — none, with no pages, is a misconfiguration */
  searched?: string[];
  roots?: string[];
}
export interface SrcReply {
  path: string;
  start: number;
  end: number;
  /** the first line of `text` (a few lines of context above `start`) */
  from: number;
  text: string;
  ref: string;
  err?: string;
}

const CITE = /\[([^\]]+)\]\(src:([^)\s]+)\)/g;
const WIKILINK = /\[\[([a-z0-9-]+)\]\]/g;
/** `[label](slug)` — a plain markdown link to another page by its bare slug */
const PAGELINK = /\[([^\]]+)\]\(([a-z0-9-]+)\)/g;
const attr = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

/** Sections in first-appearance order: the pages arrive sorted by `order`, so the grouping inherits it. */
export function sectionsOf(pages: WikiPage[]): { name: string; pages: WikiPage[] }[] {
  const out: { name: string; pages: WikiPage[] }[] = [];
  for (const p of pages) {
    const hit = out.find((s) => s.name === p.section);
    if (hit) hit.pages.push(p);
    else out.push({ name: p.section, pages: [p] });
  }
  return out;
}

/** A page body as HTML: citations become buttons carrying their anchor, wikilinks links named by the
 *  page's title when it's known. Held out of the renderer as placeholders, so it never sees `src:`. */
export function wikiHtml(body: string, titleOf: (slug: string) => string | undefined = () => undefined): string {
  const held: string[] = [];
  const hold = (html: string) => `\u0001${held.push(html) - 1}\u0001`;
  const src = body
    .replace(CITE, (_m, label: string, anchor: string) => hold(`<button class="wk-cite" data-anchor="${attr(anchor)}" title="${attr(anchor)}">${inline(label)}</button>`))
    .replace(WIKILINK, (_m, slug: string) => hold(`<a class="wk-link" href="/v2/wiki/${slug}" data-slug="${slug}">${attr(titleOf(slug) ?? slug.replace(/-/g, " "))}</a>`))
    .replace(PAGELINK, (_m, label: string, slug: string) => hold(`<a class="wk-link" href="/v2/wiki/${slug}" data-slug="${slug}">${inline(label)}</a>`));
  return renderMarkdown(src).replace(/\u0001(\d+)\u0001/g, (_m, i: string) => held[+i]);
}
