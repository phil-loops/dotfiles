// The review page's state: which branch, its diff (lazy, cached by tip), and the stops the cursor
// walks — every diff row, and under it the threads and pending comments anchored there — plus the
// folds, the composer and the overlays the review commands move. Views and commands both read it.
import { createEffect, createMemo, createRoot, createSignal, on } from "solid-js";
import { routeArg, surface } from "../router";
import { list, view, world } from "../store";
import { ask, getJSON } from "../sync";
import type { Conv, Draft, Item, Thread } from "../types";
import { parsePatch, rowAnchors, splitRows, unifiedRows, type FileDiff, type Row } from "./diff";

const store = {
  get: (k: string): string | null => {
    try {
      return localStorage.getItem(k);
    } catch {
      return null;
    }
  },
  set: (k: string, v: string | null) => {
    try {
      if (v == null) localStorage.removeItem(k);
      else localStorage.setItem(k, v);
    } catch {
      /* private window: the setting just doesn't stick */
    }
  },
};

export interface NodeFile {
  path: string;
  status: string;
  add: number;
  del: number;
  patch: string;
}
interface NodePayload {
  files: NodeFile[];
  baseSha?: string;
  worktree?: string;
}

export type Composer =
  | { kind: "line"; key: string; path: string; side: "RIGHT" | "LEFT"; line: number; startLine: number | null }
  | { kind: "reply"; key: string; threadId: string };

/** A ledger item GitHub doesn't show yet (drafts, waiting, sending, lost): the page draws these; a
 *  pending or submitted one is drawn from GitHub's own copy in the thread. */
export const local = (i: Item) => i.state !== "pending" && i.state !== "submitted";

export interface FileView {
  file: FileDiff;
  rows: Row[];
  threadsAt: Map<string, Thread[]>;
  pendingAt: Map<string, Item[]>;
  /** threads whose line isn't a row here (outdated, or moved out of the diff) */
  aside: Thread[];
  open: number;
  viewed: boolean;
}

export type Stop =
  | { key: string; kind: "file"; path: string }
  | { key: string; kind: "line"; path: string; row: Row }
  | { key: string; kind: "thread"; path: string; id: string }
  | { key: string; kind: "pending"; path: string; id: string };

const rowCache = new WeakMap<FileDiff, { u?: Row[]; s?: Row[] }>();
/** A file's rows, built once per parsed diff: a thread or draft patch never rebuilds the diff's DOM. */
export function rowsOf(f: FileDiff, split: boolean): Row[] {
  const c = rowCache.get(f) ?? {};
  rowCache.set(f, c);
  return split ? (c.s ??= splitRows(f)) : (c.u ??= unifiedRows(f));
}

const repos = (): string[] => (window as unknown as { __VIEWER_REPOS__?: string[] }).__VIEWER_REPOS__ ?? [];
export const atRepoPath = (repo: string, path: string) => (repos().includes(repo) ? `/${encodeURIComponent(repo)}${path}` : path);

export const page = createRoot(() => {
  const target = createMemo(() => {
    if (surface().id !== "review") return null;
    const a = routeArg();
    const i = a.indexOf("/");
    return i < 0 ? null : { repo: a.slice(0, i), name: a.slice(i + 1), id: `${a.slice(0, i)}:${a.slice(i + 1)}` };
  });
  const id = () => target()?.id ?? "";
  const conv = () => world.entities.conv[id()] as Conv | undefined;
  const draft = () => view("draft", id()) as Draft | undefined;
  const branch = () => view("branch", id());
  const tip = createMemo(() => branch()?.tip ?? conv()?.tip ?? "");

  const [tab, setTab] = createSignal<"files" | "conversation">("files");
  const [split, setSplitSig] = createSignal(store.get("v2.review.split") === "1");
  const setSplit = (v: boolean) => {
    setSplitSig(v);
    store.set("v2.review.split", v ? "1" : null);
  };
  const [showOutdated, setShowOutdated] = createSignal(false);
  const [cursor, setCursor] = createSignal<string | undefined>();
  const [mark, setMark] = createSignal<string | undefined>();
  const [unfold, setUnfold] = createSignal<ReadonlyMap<string, boolean>>(new Map());
  const [composer, setComposer] = createSignal<Composer | null>(null);
  const [texts, setTexts] = createSignal<ReadonlyMap<string, string>>(new Map());
  const [overlay, setOverlay] = createSignal<"map" | "words" | null>(null);
  const [viewedOverride, setViewedOverride] = createSignal<ReadonlyMap<string, boolean>>(new Map());
  const [filter, setFilter] = createSignal("");
  const [filtering, setFiltering] = createSignal(false);

  const [payload, setPayload] = createSignal<{ key: string; data: NodePayload } | null>(null);
  const [loadErr, setLoadErr] = createSignal<string | null>(null);
  const cache = new Map<string, NodePayload>();
  const keyOf = createMemo(() => `${id()}@${tip()}`);

  async function load(key: string, repo: string, name: string): Promise<void> {
    const hit = cache.get(key);
    if (hit) return void setPayload({ key, data: hit });
    try {
      const data = await getJSON<NodePayload>(atRepoPath(repo, `/node?branch=${encodeURIComponent(name)}`));
      cache.set(key, data);
      if (keyOf() === key) {
        setPayload({ key, data });
        setLoadErr(null);
      }
    } catch (e) {
      setLoadErr(e instanceof Error ? e.message : String(e));
    }
  }

  createEffect(
    on([keyOf, target], ([key, t]) => {
      if (!t) return;
      // a new branch starts fresh; the same branch at a new tip keeps showing the old diff until the new one lands
      if (payload() && !payload()!.key.startsWith(`${t.id}@`)) {
        setPayload(null);
        setCursor(undefined);
        setMark(undefined);
        setComposer(null);
        setViewedOverride(new Map());
        setTab("files");
      }
      void load(key, t.repo, t.name);
    }),
  );
  // move the type trees to this tip (and the diff's base) while it's read, so the first K is warm
  createEffect(
    on([tip, createMemo(() => payload()?.data.baseSha)], ([at, b]) => {
      const t = target();
      if (t && at) void ask(atRepoPath(t.repo, "/lsp/prepare"), { branch: t.name, ...(b ? { base: b } : {}) });
    }),
  );

  /** Prefetch a branch's diff (hover on Forests, the map overlay) so opening it paints at once. */
  const warm = (repo: string, name: string, at: string) => {
    const key = `${repo}:${name}@${at}`;
    if (!cache.has(key)) void getJSON<NodePayload>(atRepoPath(repo, `/node?branch=${encodeURIComponent(name)}`)).then((d) => cache.set(key, d)).catch(() => {});
  };

  const files = createMemo<FileDiff[]>(() => (payload()?.data.files ?? []).map((f) => ({ ...parsePatch(f.path, f.patch || ""), add: f.add, del: f.del })));
  const statusOf = createMemo(() => new Map((payload()?.data.files ?? []).map((f) => [f.path, f.status])));
  const base = () => payload()?.data.baseSha ?? "";

  const threads = createMemo(() => list("thread").filter((t) => t.branch === target()?.name && t.repo === target()?.repo));
  const items = createMemo(() => (draft()?.items ?? []).filter(local));
  /** replies not on GitHub yet, by thread id */
  const repliesTo = (threadId: string) => items().filter((i) => i.kind === "reply" && i.threadId === threadId);

  const isViewed = (path: string) => viewedOverride().get(path) ?? statusOf().get(path) === "blessed";

  const views = createMemo<FileView[]>(() => {
    const sp = split();
    const byPath = new Map<string, Thread[]>();
    for (const t of threads()) (byPath.get(t.path) ?? byPath.set(t.path, []).get(t.path)!).push(t);
    const pend = new Map<string, Item[]>();
    for (const c of items()) if (c.kind === "comment" && c.path) (pend.get(c.path) ?? pend.set(c.path, []).get(c.path)!).push(c);
    return files().map((file) => {
      const rows = rowsOf(file, sp);
      const anchors = new Set(rows.flatMap(rowAnchors));
      const threadsAt = new Map<string, Thread[]>();
      const aside: Thread[] = [];
      for (const t of byPath.get(file.path) ?? []) {
        const a = t.local ? `${t.side === "LEFT" ? "L" : "R"}:${t.local.line}` : "";
        if (a && anchors.has(a)) (threadsAt.get(a) ?? threadsAt.set(a, []).get(a)!).push(t);
        else aside.push(t);
      }
      const pendingAt = new Map<string, Item[]>();
      for (const c of pend.get(file.path) ?? []) {
        const a = `${c.side === "LEFT" ? "L" : "R"}:${c.line}`;
        (pendingAt.get(a) ?? pendingAt.set(a, []).get(a)!).push(c);
      }
      const open = (byPath.get(file.path) ?? []).filter((t) => !t.resolved && !t.outdated).length;
      return { file, rows, threadsAt, pendingAt, aside, open, viewed: isViewed(file.path) };
    });
  });

  /** Threads not on any file of this diff (a file the branch no longer changes). */
  const elsewhere = createMemo(() => {
    const paths = new Set(files().map((f) => f.path));
    return threads().filter((t) => !paths.has(t.path) && (!t.outdated || showOutdated()));
  });

  const isOpen = (t: Thread) => unfold().get(t.id) ?? (!t.resolved && !t.outdated);

  /** Where the row's threads/pending comments render: the row's last anchor that has any. */
  const atRow = (fv: FileView, r: Row) => {
    const as = rowAnchors(r);
    return { threads: as.flatMap((a) => fv.threadsAt.get(a) ?? []), pending: as.flatMap((a) => fv.pendingAt.get(a) ?? []) };
  };

  const stops = createMemo<Stop[]>(() => {
    const out: Stop[] = [];
    for (const fv of views()) {
      const path = fv.file.path;
      out.push({ key: `f|${path}`, kind: "file", path });
      if (fv.viewed) continue;
      const thread = (t: Thread) => {
        out.push({ key: `t|${t.id}`, kind: "thread", path, id: t.id });
        if (isOpen(t)) for (const r of repliesTo(t.id)) out.push({ key: `p|${r.key}`, kind: "pending", path, id: r.key });
      };
      for (const t of fv.aside) if (!t.outdated || showOutdated()) thread(t);
      for (const r of fv.rows) {
        out.push({ key: `l|${path}|${r.key}`, kind: "line", path, row: r });
        const at = atRow(fv, r);
        for (const t of at.threads) thread(t);
        for (const c of at.pending) out.push({ key: `p|${c.key}`, kind: "pending", path, id: c.key });
      }
    }
    return out;
  });
  const stopIndex = createMemo(() => new Map(stops().map((s, i) => [s.key, i])));

  /** The stop under the cursor: the cursor's own while it exists, else the first line. */
  const here = createMemo<Stop | undefined>(() => {
    const k = cursor();
    const i = k ? stopIndex().get(k) : undefined;
    if (i !== undefined) return stops()[i];
    return stops().find((s) => s.kind === "line") ?? stops()[0];
  });

  const fileOf = (path: string) => views().find((v) => v.file.path === path);

  /** The commentable line range under the cursor (and the mark, when `x` extended it). */
  const range = createMemo(() => {
    const h = here();
    if (!h || h.kind !== "line") return null;
    const end = sideLine(h.row);
    const m = mark() ? stops()[stopIndex().get(mark()!) ?? -1] : undefined;
    if (!m || m.kind !== "line" || m.path !== h.path) return { path: h.path, ...end, startLine: null as number | null };
    const start = sideLine(m.row);
    if (start.side !== end.side) return { path: h.path, ...end, startLine: null as number | null };
    const [a, b] = start.line <= end.line ? [start.line, end.line] : [end.line, start.line];
    return { path: h.path, side: end.side, line: b, startLine: a === b ? null : a };
  });

  const text = (key: string) => texts().get(key) ?? store.get(`v2.review.text.${key}`) ?? "";
  const setText = (key: string, v: string) => {
    setTexts((m) => new Map(m).set(key, v));
    store.set(`v2.review.text.${key}`, v || null);
  };

  return {
    target, id, conv, draft, branch, tip, base, files, views, threads, items, repliesTo, elsewhere, stops, stopIndex, here, range,
    fileOf, isOpen, atRow, isViewed, payload, loadErr, warm,
    tab, setTab, split, setSplit, showOutdated, setShowOutdated, cursor, setCursor, mark, setMark,
    unfold, setUnfold, composer, setComposer, text, setText,
    overlay, setOverlay, viewedOverride, setViewedOverride, filter, setFilter, filtering, setFiltering,
  };
});

/** The side and line number a row is commented on: its new line when it has one. */
export function sideLine(r: Row): { side: "RIGHT" | "LEFT"; line: number } {
  return r.right ? { side: "RIGHT", line: r.right.new! } : { side: "LEFT", line: r.left!.old! };
}

/** A short sha. */
export const short = (sha: string) => sha.slice(0, 7);
