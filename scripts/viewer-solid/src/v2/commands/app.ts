// Commands every surface has: the menu, the key sheet, navigation, the cursor, undo, and the places
// v2 doesn't have yet (v1's pages, reached through the menu until Phase 3 builds the palette).
import { model } from "../model";
import { command } from "../registry";
import { forestPath, leave, navigate, reviewPath, SURFACES } from "../router";
import { undoLast } from "../runner";
import { view } from "../store";
import {
  armed,
  launching,
  menuOpen,
  setArmed,
  setCursor,
  setCursorIdx,
  setDashDays,
  setLaunching,
  setMenuOpen,
  setSheetOpen,
  sheetOpen,
} from "../ui";

command({ id: "menu.open", label: "menu", title: "Open the command menu", scope: "global", budget: "local", keys: ["space ?", ":"], quiet: true, local: () => setMenuOpen(true) });
command({ id: "help.keys", label: "keys", title: "Show every key", scope: "global", budget: "local", keys: ["?"], local: () => setSheetOpen((v) => !v) });
command({
  id: "overlay.close",
  label: "back",
  title: "Back out",
  scope: "global",
  budget: "local",
  keys: ["esc"],
  quiet: true,
  available: () => menuOpen() || sheetOpen() || !!armed() || !!launching(),
  local: () => {
    if (menuOpen() || sheetOpen()) {
      setMenuOpen(false);
      setSheetOpen(false);
    } else if (armed()) setArmed(undefined);
    else setLaunching(undefined);
  },
});

// `g d` is Helix's go-to-definition on the review page, so the dashboard is `g s` (its stats)
const NAV_KEY: Record<string, string> = { forests: "g f", dashboard: "g s", todo: "g o", machine: "g m", wiki: "g i", tutor: "g t" };
const NAV_V1: Record<string, string[]> = { wiki: ["nav.wiki"], tutor: ["nav.tutor"] };
for (const s of SURFACES.filter((x) => !x.arg || x.bare)) {
  command({
    id: `nav.${s.id}`,
    title: `Go to ${s.title}`,
    scope: "global",
    budget: "local",
    keys: [NAV_KEY[s.id] ?? `g ${s.id[0]}`],
    ...(NAV_V1[s.id] ? { v1: NAV_V1[s.id] } : {}),
    local: (_t, e) => navigate(s.path, e),
  });
}

// v1's pages, until v2 has its own: the rail is gone, so the menu is how you reach them
const PLACES = [
  { id: "work", title: "Work", path: "/work", key: "g w" },
  { id: "tutor", title: "Tutor", path: "/tutor", key: "g t" },
  { id: "v1", title: "the v1 home", path: "/forests?v1", key: "" },
];
for (const p of PLACES) {
  command({ id: `place.${p.id}`, title: `Go to ${p.title}`, scope: "global", budget: "local", keys: p.key ? [p.key] : [], local: () => leave(p.path) });
}

// what the space menu finds by name: a result is one of these plus the branch or forest id ("<repo>:<name>")
command({
  id: "find.branch",
  title: "Open a branch you found",
  scope: "global",
  budget: "local",
  quiet: true,
  local: (_t, e, id) => {
    const [repo, name] = (id as string).split(/:(.*)/);
    navigate(reviewPath(repo, name), e);
  },
});
command({
  id: "find.forest",
  title: "Open a forest you found",
  scope: "global",
  budget: "local",
  quiet: true,
  local: (_t, e, id) => {
    const p = view("project", id as string);
    if (!p) throw new Error("that forest is gone");
    setCursor(undefined);
    setCursorIdx(0);
    navigate(forestPath(p.repo, p.name), e);
  },
});

const move = (by: number) => () => {
  const rows = model.rows();
  if (!rows.length) return;
  const i = Math.max(0, Math.min(rows.length - 1, rows.indexOf(model.selected() ?? rows[0]) + by));
  setArmed(undefined);
  setCursor(rows[i]);
  setCursorIdx(i);
};
command({ id: "cursor.down", label: "row", pair: "cursor.up", title: "Next row", scope: "global", budget: "local", keys: ["j", "down"], quiet: true, local: move(1) });
command({ id: "cursor.up", label: "row", title: "Previous row", scope: "global", budget: "local", keys: ["k", "up"], quiet: true, local: move(-1) });
command({
  id: "cursor.set",
  title: "Select row",
  scope: "global",
  budget: "local",
  quiet: true,
  local: (key) => {
    if (key !== model.selected()) setArmed(undefined);
    setCursor(key);
    setCursorIdx(Math.max(0, model.rows().indexOf(key ?? "")));
  },
});

command({
  id: "undo",
  label: "undo",
  title: "Undo the last change",
  scope: "global",
  budget: "local",
  keys: ["u"],
  local: () => {
    if (!undoLast()) throw new Error("nothing to undo");
  },
});

const RANGES = [7, 30, 90];
command({
  id: "dashboard.range",
  label: "range",
  title: "Change the dashboard's window",
  scope: "dashboard",
  budget: "local",
  keys: ["space t"],
  local: () => setDashDays((d) => RANGES[(RANGES.indexOf(d) + 1) % RANGES.length]),
});
