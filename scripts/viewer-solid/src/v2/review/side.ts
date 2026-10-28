// The review page as a navigation surface: a place in the diff moves the diff cursor, as before; a
// place anywhere else opens beside the diff in the side code pane, at the commit it was found at.
import { createRoot, createSignal } from "solid-js";
import { nav, type Loc } from "../nav";
import { page as pg } from "./page";

export const side = createRoot(() => {
  const [loc, setLoc] = createSignal<Loc | null>(null);
  const [text, setText] = createSignal<string | undefined>();

  function show(l: Loc): void {
    const same = loc();
    setLoc(l);
    if (same && same.repo === l.repo && same.sha === l.sha && same.path === l.path) return;
    setText(undefined);
    void nav.linesOf(l).then((lines) => loc() === l && setText(lines.join("\n")));
  }

  const inDiff = (l: Loc) =>
    l.diffKey ?? (l.sha === pg.tip() ? pg.stops().find((s) => s.kind === "line" && s.path === l.path && s.row.right?.new === l.line)?.key : undefined);

  function open(l: Loc): void {
    const key = inDiff(l);
    if (key) {
      setLoc(null);
      pg.setCursor(key);
      return;
    }
    show(l);
  }

  function here(): Loc | null {
    const l = loc();
    if (l) return l;
    const h = pg.here();
    const t = pg.target();
    if (!h || h.kind !== "line" || !t) return null;
    return { repo: t.repo, sha: pg.tip(), path: h.path, line: h.row.right?.new ?? h.row.left?.old ?? 1, diffKey: h.key };
  }

  return { loc, text, open, here, close: () => setLoc(null) };
});
