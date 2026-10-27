// The wiki, read once per page load (GET /wiki-pages holds every page's body) and kept: moving
// between pages never waits. A citation's lines come from GET /wiki-src, at origin/main.
import { createMemo, createRoot, createSignal } from "solid-js";
import { routeArg, surface } from "./router";
import { getJSON } from "./sync";
import type { PagesReply, SrcReply, WikiPage } from "./wikitext";

export const wkey = (slug: string) => `w:${slug}`;

export const wiki = createRoot(() => {
  const [read, setRead] = createSignal<PagesReply | undefined>();
  let asked = false;
  /** Read the pages, once — the menu's finder asks too. */
  function load(): void {
    if (asked) return;
    asked = true;
    getJSON<PagesReply>("/wiki-pages").then(setRead, (e) => {
      asked = false;
      setRead({ pages: [], ref: "", repo: "", problems: [], err: String(e) });
    });
  }
  const pages = createMemo<WikiPage[]>(() => read()?.pages ?? []);
  const page = (slug: string | undefined) => (slug ? pages().find((p) => p.slug === slug) : undefined);
  /** The page the URL names; the first page when it names none. Undefined for a slug that isn't a page. */
  const current = createMemo(() => {
    if (surface().id !== "wiki") return undefined;
    const slug = routeArg();
    return slug ? page(slug) : pages()[0];
  });

  /** The citation open under the page: its anchor, then its lines once they arrive. */
  const [cite, setCite] = createSignal<{ anchor: string; src?: SrcReply } | undefined>();
  function showCite(anchor: string | undefined): void {
    if (!anchor || cite()?.anchor === anchor) return void setCite(undefined);
    setCite({ anchor });
    getJSON<SrcReply>(`/wiki-src?anchor=${encodeURIComponent(anchor)}`).then(
      (src) => cite()?.anchor === anchor && setCite({ anchor, src }),
      (e) => cite()?.anchor === anchor && setCite({ anchor, src: { path: anchor, start: 0, end: 0, from: 0, text: "", ref: "", err: String(e) } }),
    );
  }

  return { read, load, pages, page, current, cite, showCite };
});
