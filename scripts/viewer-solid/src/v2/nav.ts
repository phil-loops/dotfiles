// Code navigation the Helix way, shared by every surface that shows code: a jumplist (C-o back,
// C-i forward) and a picker for answers with more than one place in them (references, symbols,
// several definitions). A surface registers how it opens a place and where it is now; the picker
// and the jumplist only ever go through that.
import { createRoot, createSignal } from "solid-js";
import { ranked } from "./pick";
import { getText } from "./sync";
import { atRepoPath } from "./review/page";

/** A place in code: a file at a commit, a line, and the span to light (a whole function when known). */
export interface Loc {
  repo: string;
  sha: string;
  path: string;
  line: number;
  end?: number;
  /** a review-page diff stop, when the place is a line of the diff itself */
  diffKey?: string;
}

export interface Surface {
  open: (l: Loc) => void;
  here: () => Loc | null;
}

export interface PickItem {
  loc: Loc;
  label: string;
  /** what the row shows beside its label: the source line, read when the picker opens */
  text?: string;
}

export const nav = createRoot(() => {
  let surface: Surface | null = null;
  const [back, setBack] = createSignal<Loc[]>([]);
  const [fwd, setFwd] = createSignal<Loc[]>([]);
  const [picker, setPicker] = createSignal<{ title: string; items: PickItem[] } | null>(null);
  const [filter, setFilter] = createSignal("");
  const [index, setIndex] = createSignal(0);

  /** The surface on screen says how to open a place and where it is; the returned detach only
   *  ever removes that surface, so a page mounting over its own old copy keeps the new one. */
  function attach(s: Surface): () => void {
    surface = s;
    return () => {
      if (surface === s) surface = null;
    };
  }

  /** Go somewhere, remembering where from. */
  function go(l: Loc): void {
    const from = surface?.here();
    if (from) setBack((b) => [...b.slice(-99), from]);
    setFwd([]);
    surface?.open(l);
  }

  function step(from: () => Loc[], setFrom: (f: (x: Loc[]) => Loc[]) => void, setTo: (f: (x: Loc[]) => Loc[]) => void): boolean {
    const list = from();
    if (!list.length || !surface) return false;
    const to = list[list.length - 1];
    setFrom((x) => x.slice(0, -1));
    const now = surface.here();
    if (now) setTo((x) => [...x, now]);
    surface.open(to);
    return true;
  }
  const goBack = () => step(back, setBack, setFwd);
  const goForward = () => step(fwd, setFwd, setBack);

  const texts = new Map<string, Promise<string[]>>();
  const linesOf = (l: Loc) => {
    const k = `${l.repo}|${l.sha}|${l.path}`;
    if (!texts.has(k))
      texts.set(
        k,
        getText(atRepoPath(l.repo, `/lsp/src?path=${encodeURIComponent(l.path)}&sha=${encodeURIComponent(l.sha)}`)).then((t) => {
          try {
            return ((JSON.parse(t ?? "{}") as { text?: string }).text ?? "").split("\n");
          } catch {
            return [];
          }
        }),
      );
    return texts.get(k)!;
  };

  /** Open the picker on `items`; each row's source line fills in as its file arrives. */
  function pick(title: string, items: PickItem[]): void {
    setFilter("");
    setIndex(0);
    setPicker({ title, items });
    items.forEach((it, i) => {
      if (it.text != null) return;
      void linesOf(it.loc).then((lines) => {
        const p = picker();
        if (p?.items !== items) return;
        const next = [...p.items];
        next[i] = { ...it, text: (lines[it.loc.line - 1] ?? "").trim() };
        items = next;
        setPicker({ ...p, items: next });
      });
    });
  }

  const shown = () => {
    const p = picker();
    if (!p) return [];
    return ranked(p.items, filter(), (it) => `${it.label} ${it.text ?? ""}`);
  };
  const move = (d: number) => setIndex((i) => Math.max(0, Math.min(shown().length - 1, i + d)));
  function choose(i = index()): boolean {
    const it = shown()[i];
    if (!it) return false;
    setPicker(null);
    go(it.loc);
    return true;
  }
  const close = () => setPicker(null);
  const typed = (f: string) => {
    setFilter(f);
    setIndex(0);
  };

  return { attach, go, goBack, goForward, back, fwd, picker, pick, shown, filter, typed, index, move, choose, close, linesOf };
});
