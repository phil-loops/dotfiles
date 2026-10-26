// Commands every surface has: the menu, the key sheet, navigation, the cursor, undo, and the places
// v2 doesn't have yet (v1's pages, reached through the menu until Phase 3 builds the palette).
import { model } from "../model";
import { command } from "../registry";
import { leave, navigate, SURFACES } from "../router";
import { undoLast } from "../runner";
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

command({ id: "menu.open", label: "menu", title: "Command menu", scope: "global", budget: "local", keys: ["space ?", ":"], quiet: true, local: () => setMenuOpen(true) });
command({ id: "help.keys", label: "keys", title: "Keys", scope: "global", budget: "local", keys: ["?"], local: () => setSheetOpen((v) => !v) });
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

// `g d` is Helix's go-to-definition on the review page, so the dashboard is `g D`
const NAV_KEY: Record<string, string> = { forests: "g f", dashboard: "g D", todo: "g o" };
for (const s of SURFACES.filter((x) => !x.arg)) {
  command({
    id: `nav.${s.id}`,
    title: `Go to ${s.title}`,
    scope: "global",
    budget: "local",
    keys: [NAV_KEY[s.id] ?? `g ${s.id[0]}`],
    local: (_t, e) => navigate(s.path, e),
  });
}

// v1's pages, until v2 has its own: the rail is gone, so the menu is how you reach them
const PLACES = [
  { id: "work", title: "Work", path: "/work", key: "g w" },
  { id: "wiki", title: "Wiki", path: "/wiki", key: "g i" },
  { id: "tutor", title: "Tutor", path: "/tutor", key: "g t" },
  { id: "machine", title: "Machine", path: "/machine", key: "g m" },
  { id: "v1", title: "the v1 home", path: "/forests", key: "g v" },
];
for (const p of PLACES) {
  command({ id: `place.${p.id}`, title: `Open ${p.title}`, scope: "global", budget: "local", keys: [p.key], local: () => leave(p.path) });
}

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
