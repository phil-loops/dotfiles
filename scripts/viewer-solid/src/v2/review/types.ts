// Code navigation the Helix way, on any pane that shows code: space k shows the type under the
// pointer (or the first name on the cursor's line), g d / g y / g I / g r go to the definition, the
// type's definition, the implementations, the references; space S lists the file's symbols. One
// place goes straight there through nav.go (the diff when it's in it, else the side code pane); more
// than one opens the picker. A code cell carries its file, line and commit (data-sha) — a diff cell
// without one asks at the branch tip, or its base for the old half. Answers come from srv/lsp.py's
// one tsgo; a "loading" answer is asked again until it settles.
import { createSignal } from "solid-js";
import { ask } from "../sync";
import { nav, type Loc, type PickItem } from "../nav";
import { atRepoPath, page } from "./page";

export interface Pos {
  path: string;
  line: number;
  character: number;
  side: "new" | "old";
  x: number;
  y: number;
  /** the commit the cell's code is at, when it isn't the review page's branch */
  sha?: string;
  repo?: string;
  /** where `.member` starts when the name is followed by one — a namespace's member is what g d wants */
  member?: number;
}

/** Code outside the review page's diff: the repo it's in ("" for the server's own) and its commit. */
export interface Source {
  repo: string;
  sha: string;
}

type Pop = { kind: "wait"; x: number; y: number; text: string } | { kind: "hover"; x: number; y: number; md: string } | { kind: "note"; x: number; y: number; text: string };

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
export function position(src?: Source): Pos | null {
  if (pointer) {
    const hit = cellAt(pointer.x, pointer.y);
    if (hit) {
      const w = wordAt(hit.el.textContent ?? "", hit.offset);
      if (w) {
        const b = hit.el.getBoundingClientRect();
        const d = hit.el.dataset;
        return { path: d.path!, line: +d.line!, side: d.side as "new" | "old", sha: d.sha, repo: d.repo, character: w.start, member: memberAt(hit.el.textContent ?? "", w.end), x: pointer.x, y: b.bottom };
      }
    }
  }
  if (src) return null;
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
  return { path: el.dataset.path!, line: +el.dataset.line!, side: el.dataset.side as "new" | "old", character: m.index, member: memberAt(text, m.index + m[0].length), x: b.left + 40, y: b.bottom };
}

const memberAt = (text: string, end: number): number | undefined => (text[end] === "." && isWord(text[end + 1]) ? end + 1 : undefined);

/** the server's sentences are markdown-ish ("_Refused: …_") */
const plainNote = (m?: string) => (m ?? "").replace(/^_+|_+$/g, "").replace(/^Refused:\s*/, "");

/** The repo and the addressing a position asks under: its own commit, the pane's, or the branch's. */
function where(p: { sha?: string; repo?: string; side: "new" | "old" }, src?: Source): { repo: string; at: Record<string, string> } | null {
  if (p.sha) return { repo: p.repo ?? src?.repo ?? page.target()?.repo ?? "", at: { sha: p.sha } };
  if (src) return { repo: src.repo, at: { sha: src.sha } };
  const t = page.target();
  if (!t) return null;
  return { repo: t.repo, at: { branch: t.name, ...(p.side === "old" && page.baseSha() ? { base: page.baseSha() } : {}) } };
}

let seq = 0;

async function asking<T extends { ok: boolean; state?: string; message?: string }>(route: string, w: { repo: string; at: Record<string, string> }, body: Record<string, unknown>, x: number, y: number): Promise<T | null> {
  const mine = ++seq;
  const t0 = Date.now();
  for (;;) {
    const r = await ask<T>(atRepoPath(w.repo, route), { ...w.at, ...body });
    if (mine !== seq) return null;
    if (!r || r.ok || r.state !== "loading" || Date.now() - t0 > 90_000) return r;
    setPop({ kind: "wait", x, y, text: `types are loading — ${r.message || "starting tsgo"}` });
    await new Promise((res) => setTimeout(res, 500));
    if (mine !== seq) return null;
  }
}

const at = (p: Pos) => ({ path: p.path, line: p.line, character: p.character, side: p.side });

export function hover(src?: Source): void {
  const p = position(src);
  const w = p && where(p, src);
  if (!p || !w) return void setPop({ kind: "note", x: innerWidth / 2, y: 120, text: "nothing to type here" });
  setPop({ kind: "wait", x: p.x, y: p.y, text: "asking tsgo…" });
  void asking<{ ok: boolean; contents?: string; state?: string; message?: string }>("/lsp/hover", w, at(p), p.x, p.y).then((r) => {
    if (!r) return;
    if (r.ok && r.contents) setPop({ kind: "hover", x: p.x, y: p.y, md: r.contents });
    else setPop({ kind: "note", x: p.x, y: p.y, text: r.ok ? "no type here" : plainNote(r.message) || "types aren't available" });
  });
}

export type Goto = "definition" | "type-definition" | "implementation" | "references";
const GOTO: Record<Goto, { asking: string; none: string; title: string }> = {
  definition: { asking: "finding the definition…", none: "no definition found", title: "definitions" },
  "type-definition": { asking: "finding the type's definition…", none: "no type definition here", title: "type definitions" },
  implementation: { asking: "finding the implementations…", none: "no implementations found", title: "implementations" },
  references: { asking: "finding the references…", none: "no references found", title: "references" },
};

type Found = { path: string; line: number; character?: number; endLine?: number; span?: [number, number] };
type Answer = { ok: boolean; sha?: string; locations?: Found[]; state?: string; message?: string };

/** a namespace import answers with its whole module (line 1 to the end) — the member is what was meant */
const wholeModule = (r: Answer) => r.ok && r.locations?.length === 1 && r.locations[0].line === 1 && !r.locations[0].character && (r.locations[0].endLine ?? 1) > 1;

/** g d, g y, g I, g r: one place goes there, several open the picker. */
export function goto(kind: Goto, src?: Source): void {
  const p = position(src);
  const w = p && where(p, src);
  if (!p || !w) return void setPop({ kind: "note", x: innerWidth / 2, y: 120, text: "nothing to look up here" });
  setPop({ kind: "wait", x: p.x, y: p.y, text: GOTO[kind].asking });
  const route = `/lsp/${kind}`;
  void asking<Answer>(route, w, at(p), p.x, p.y).then(async (first) => {
    const member = first && wholeModule(first) && p.member != null ? await asking<Answer>(route, w, { ...at(p), character: p.member }, p.x, p.y) : null;
    const r = member?.ok && member.locations?.length ? member : first;
    if (!r) return;
    const locs = r.ok ? (r.locations ?? []) : [];
    if (!locs.length) return void setPop({ kind: "note", x: p.x, y: p.y, text: r.ok ? GOTO[kind].none : plainNote(r.message) || "types aren't available" });
    setPop(null);
    const places = locs.map((l): Loc => ({ repo: w.repo, sha: r.sha ?? "", path: l.path, line: l.line, end: l.span?.[1] }));
    if (places.length === 1) return nav.go(places[0]);
    nav.pick(`${GOTO[kind].title} · ${places.length}`, places.map((l): PickItem => ({ loc: l, label: `${l.path}:${l.line}` })));
  });
}

/** space S: the symbols of the file under the pointer (else `path`, else the cursor's file), in the picker. */
export function symbols(src?: Source, path?: string): void {
  const p = position(src);
  const h = page.here();
  const fallback = path ?? (!src ? h?.path : undefined);
  const file = p ?? (fallback ? { path: fallback, line: 1, character: 0, side: "new" as const, x: innerWidth / 2, y: 120 } : null);
  const w = file && where(file, src);
  if (!file || !w) return void setPop({ kind: "note", x: innerWidth / 2, y: 120, text: "no file to list" });
  setPop({ kind: "wait", x: file.x, y: file.y, text: "reading the file's symbols…" });
  type Symbols = { ok: boolean; sha?: string; symbols?: { name: string; kind: string; line: number; endLine: number; depth: number }[]; state?: string; message?: string };
  void asking<Symbols>("/lsp/symbols", w, { path: file.path, side: file.side }, file.x, file.y).then((r) => {
    if (!r) return;
    const syms = r.ok ? (r.symbols ?? []) : [];
    if (!syms.length) return void setPop({ kind: "note", x: file.x, y: file.y, text: r.ok ? "no symbols in this file" : plainNote(r.message) || "types aren't available" });
    setPop(null);
    nav.pick(
      `symbols · ${file.path}`,
      syms.map((s): PickItem => ({ loc: { repo: w.repo, sha: r.sha ?? "", path: file.path, line: s.line, end: s.endLine }, label: `${"  ".repeat(s.depth)}${s.name}`, text: `${s.kind} :${s.line}` })),
    );
  });
}

export const dismiss = () => {
  seq++;
  setPop(null);
};
