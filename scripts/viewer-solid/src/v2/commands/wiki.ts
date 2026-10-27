// The wiki's moves: open a page (from the list, a wikilink or the finder), show a citation's lines,
// put them away, and go to the forest a plan page describes.
import { command } from "../registry";
import { forestPath, navigate, wikiPath } from "../router";
import { view } from "../store";
import { menuOpen, setCursor, setMenuOpen, setSheetOpen, sheetOpen } from "../ui";
import { wiki, wkey } from "../wikiread";

const go = (slug: string, e?: Event) => {
  wiki.showCite(undefined);
  setCursor(wkey(slug));
  navigate(wikiPath(slug), e);
};

command({
  id: "wiki.open",
  label: "open",
  title: "Open the wiki page",
  scope: "article",
  budget: "local",
  keys: ["ret"],
  available: (slug) => !!wiki.page(slug),
  local: (slug, e) => go(slug!, e),
});

command({
  id: "wiki.cite",
  title: "Show a citation's lines on main",
  scope: "wiki",
  budget: "local",
  quiet: true,
  local: (anchor) => wiki.showCite(anchor),
});

command({
  id: "wiki.back",
  label: "back",
  title: "Back out",
  scope: "wiki",
  budget: "local",
  keys: ["esc"],
  quiet: true,
  local: () => {
    if (menuOpen() || sheetOpen()) {
      setMenuOpen(false);
      setSheetOpen(false);
    } else if (wiki.cite()) wiki.showCite(undefined);
    else throw new Error("nothing to close");
  },
});

const planForest = () => {
  const p = wiki.current();
  return p?.kind === "design" ? view("project", `${wiki.read()?.repo ?? ""}:${p.project}`) : undefined;
};
command({
  id: "wiki.forest",
  title: "Go to the forest this plan describes",
  scope: "wiki",
  budget: "local",
  available: () => !!planForest(),
  local: (_t, e) => {
    const p = planForest()!;
    navigate(forestPath(p.repo, p.name), e);
  },
});

command({
  id: "find.wiki",
  title: "Open a wiki page you found",
  scope: "global",
  budget: "local",
  quiet: true,
  local: (_t, e, slug) => go(slug as string, e),
});
