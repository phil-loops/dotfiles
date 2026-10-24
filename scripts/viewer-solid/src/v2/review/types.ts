// Types on the review page, the Helix way: K shows the type under the pointer (or the first name on
// the cursor's line), g d goes to its definition — in the diff when it's there, else a snippet.
// Both halves: a removed line, or the old half of split view, asks at the diff's base commit.
// Answers come from srv/lsp.py's one tsgo; a "loading" answer is asked again until it settles.
import { createSignal } from "solid-js";
import { ask, getText } from "../sync";
import { atRepoPath, page } from "./page";

export interface Pos {
  path: string;
  line: number;
  character: number;
  side: "new" | "old";
  x: number;
  y: number;
}

type Pop =
  | { kind: "wait"; x: number; y: number; text: string }
  | { kind: "hover"; x: number; y: number; md: string }
  | { kind: "note"; x: number; y: number; text: string }
  | { kind: "defs"; x: number; y: number; locs: { path: string; line: number; text: string }[] };

const [pop, setPop] = createSignal<Pop | null>(null);
export { pop, setPop };

let pointer: { x: number; y: number } | null = null;
export const notePointer = (e: PointerEvent) => {
  pointer = { x: e.clientX, y: e.clientY };
};

/** keywords K skips on the cursor's line, looking for the first name worth a type */
const SKIP = new Set("import export from const let var function return type interface async await new if else for while of in as default class extends implements".split(" "));
const isWord = (c: string | undefined) => !!c && /[\w$]/.test(c);

/** The identifier around a caret offset, as v1's lspKeys.wordAt. */
export function wordAt(text: string, at: number): { start: number; end: number } | null {
  let i = at;
  if (!isWord(text[i])) {
    if (!isWord(text[i - 1])) return null;
    i--;
  }
  let s = i;
  let e = i + 1;
  while (isWord(text[s - 1])) s--;
  while (isWord(text[e])) e++;
  return { start: s, end: e };
}

function cellAt(x: number, y: number): { el: HTMLElement; offset: number } | null {
  const d = document as Document & {
    caretPositionFromPoint?: (x: number, y: number) => { offsetNode: Node; offset: number } | null;
    caretRangeFromPoint?: (x: number, y: number) => Range | null;
  };
  const p = d.caretPositionFromPoint?.(x, y);
  const node = p ? p.offsetNode : d.caretRangeFromPoint?.(x, y)?.startContainer;
  const off = p ? p.offset : d.caretRangeFromPoint?.(x, y)?.startOffset ?? 0;
  const el = (node instanceof Element ? node : node?.parentElement)?.closest<HTMLElement>("[data-code]");
  if (!el || !node) return null;
  const r = document.createRange();
  r.setStart(el, 0);
  r.setEnd(node, off);
  return { el, offset: r.toString().length };
}

/** Where K points: the word under the pointer when it's over code, else the cursor line's first name. */
export function position(): Pos | null {
  if (pointer) {
    const hit = cellAt(pointer.x, pointer.y);
    if (hit) {
      const w = wordAt(hit.el.textContent ?? "", hit.offset);
      if (w) {
        const b = hit.el.getBoundingClientRect();
        return { path: hit.el.dataset.path!, line: +hit.el.dataset.line!, side: hit.el.dataset.side as "new" | "old", character: w.start, x: pointer.x, y: b.bottom };
      }
    }
  }
  const h = page.here();
  if (!h || h.kind !== "line") return null;
  const el = document.querySelector<HTMLElement>(`[data-stop="${CSS.escape(h.key)}"] [data-code]`);
  if (!el) return null;
  const text = el.textContent ?? "";
  const NAME = /[A-Za-z_$][\w$]*/g;
  let m: RegExpExecArray | null;
  while ((m = NAME.exec(text)) && SKIP.has(m[0]));
  if (!m) return null;
  const b = el.getBoundingClientRect();
  return { path: el.dataset.path!, line: +el.dataset.line!, side: el.dataset.side as "new" | "old", character: m.index, x: b.left + 40, y: b.bottom };
}

/** the server's sentences are markdown-ish ("_Refused: …_") */
const plainNote = (m?: string) => (m ?? "").replace(/^_+|_+$/g, "").replace(/^Refused:\s*/, "");

let seq = 0;

async function asking<T extends { ok: boolean; state?: string; message?: string }>(route: string, p: Pos): Promise<T | null> {
  const t = page.target();
  if (!t) return null;
  const mine = ++seq;
  const body = { branch: t.name, path: p.path, line: p.line, character: p.character, side: p.side, ...(p.side === "old" && page.base() ? { base: page.base() } : {}) };
  const t0 = Date.now();
  for (;;) {
    const r = await ask<T>(atRepoPath(t.repo, route), body);
    if (mine !== seq) return null;
    if (!r || r.ok || r.state !== "loading" || Date.now() - t0 > 90_000) return r;
    setPop({ kind: "wait", x: p.x, y: p.y, text: `types are loading — ${r.message || "starting tsgo"}` });
    await new Promise((res) => setTimeout(res, 500));
    if (mine !== seq) return null;
  }
}

export function hover(): void {
  const p = position();
  if (!p) return void setPop({ kind: "note", x: innerWidth / 2, y: 120, text: "nothing to type here" });
  setPop({ kind: "wait", x: p.x, y: p.y, text: "asking tsgo…" });
  void asking<{ ok: boolean; contents?: string; state?: string; message?: string }>("/lsp/hover", p).then((r) => {
    if (!r) return;
    if (r.ok && r.contents) setPop({ kind: "hover", x: p.x, y: p.y, md: r.contents });
    else setPop({ kind: "note", x: p.x, y: p.y, text: r.ok ? "no type here" : plainNote(r.message) || "types aren't available" });
  });
}

export function definition(jump: (path: string, line: number) => boolean): void {
  const p = position();
  if (!p) return void setPop({ kind: "note", x: innerWidth / 2, y: 120, text: "nothing to look up here" });
  setPop({ kind: "wait", x: p.x, y: p.y, text: "finding the definition…" });
  type Def = { ok: boolean; sha?: string; locations?: { path: string; line: number }[]; state?: string; message?: string };
  void asking<Def>("/lsp/definition", p).then(async (r) => {
    if (!r) return;
    const locs = r.ok ? r.locations ?? [] : [];
    if (!locs.length) return void setPop({ kind: "note", x: p.x, y: p.y, text: r.ok ? "no definition found" : plainNote(r.message) || "types aren't available" });
    if (locs.length === 1 && jump(locs[0].path, locs[0].line)) return void setPop(null);
    const t = page.target()!;
    const rows = await Promise.all(
      locs.slice(0, 6).map(async (l) => {
        const src = await getText(atRepoPath(t.repo, `/lsp/src?path=${encodeURIComponent(l.path)}&sha=${encodeURIComponent(r.sha ?? "")}`));
        let text = "";
        try {
          text = ((JSON.parse(src ?? "{}") as { text?: string }).text ?? "").split("\n").slice(Math.max(0, l.line - 2), l.line + 3).join("\n");
        } catch {
          text = "";
        }
        return { path: l.path, line: l.line, text };
      }),
    );
    setPop({ kind: "defs", x: p.x, y: p.y, locs: rows });
  });
}

export const dismiss = () => {
  seq++;
  setPop(null);
};
