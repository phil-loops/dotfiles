// Commands every surface has: the menu, the key sheet, navigation, the cursor, undo.
import { model } from "../model";
import { command } from "../registry";
import { navigate, surface, SURFACES } from "../router";
import { undoLast } from "../runner";
import { menuOpen, setCursor, setCursorIdx, setDashDays, setMenuOpen, setSheetOpen, setShowArchive, sheetOpen } from "../ui";

command({ id: "menu.open", title: "Command menu", scope: "global", budget: "local", keys: ["space"], quiet: true, local: () => setMenuOpen(true) });
command({ id: "help.keys", title: "Keys", scope: "global", budget: "local", keys: ["?"], local: () => setSheetOpen((v) => !v) });
command({
  id: "overlay.close",
  title: "Close",
  scope: "global",
  budget: "local",
  keys: ["esc"],
  quiet: true,
  available: () => menuOpen() || sheetOpen(),
  local: () => {
    setMenuOpen(false);
    setSheetOpen(false);
  },
});

for (const s of SURFACES) {
  command({
    id: `nav.${s.id}`,
    title: `Go to ${s.title}`,
    scope: "global",
    budget: "local",
    keys: [`g ${s.id[0]}`],
    local: (_t, e) => navigate(s.path, e),
  });
}

const move = (by: number) => () => {
  const rows = model.rows();
  if (!rows.length) return;
  const i = Math.max(0, Math.min(rows.length - 1, rows.indexOf(model.selected() ?? rows[0]) + by));
  setCursor(rows[i]);
  setCursorIdx(i);
};
command({ id: "cursor.down", title: "Next row", scope: "global", budget: "local", keys: ["j", "down"], quiet: true, local: move(1) });
command({ id: "cursor.up", title: "Previous row", scope: "global", budget: "local", keys: ["k", "up"], quiet: true, local: move(-1) });
command({
  id: "cursor.set",
  title: "Select row",
  scope: "global",
  budget: "local",
  quiet: true,
  local: (id) => {
    setCursor(id);
    setCursorIdx(Math.max(0, model.rows().indexOf(id ?? "")));
  },
});

command({ id: "archive.toggle", title: "Show or hide the archive", scope: "global", budget: "local", keys: ["a"], local: () => setShowArchive((v) => !v) });
command({
  id: "undo",
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
  title: "Change the dashboard's window",
  scope: "global",
  budget: "local",
  keys: ["r"],
  available: () => surface().id === "dashboard",
  local: () => setDashDays((d) => RANGES[(RANGES.indexOf(d) + 1) % RANGES.length]),
});
