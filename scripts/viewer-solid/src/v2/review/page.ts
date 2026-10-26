// The review page's state: which branch, its diff (lazy, cached by tip), and the stops the cursor
// walks — every diff row, and under it the threads and pending comments anchored there — plus the
// folds, the composer and the overlays the review commands move. Views and commands both read it.
import { createEffect, createMemo, createRoot, createSignal, on } from "solid-js";
import { routeArg, surface } from "../router";
import { list, view, world } from "../store";
import { ask, getJSON, getText } from "../sync";
import type { Conv, Draft, Item, Thread } from "../types";
import { blocksOf, expand, parsePatch, rowAnchors, splitRows, unifiedRows, type Block, type FileDiff, type Gap, type Row } from "./diff";

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

/** One of the branch's commits in the history list (GET /commits). */
export interface HistoryCommit {
  sha: string;
  subject: string;
  body: string;
  author: string;
  date: string;
  own: boolean;
  pushed?: boolean;
}

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
  /** every change block viewed (wiki canopy-v2-viewed) */
  viewed: boolean;
  blocks: Block[];
  /** how many of its blocks are viewed, and the hunks whose blocks all are */
  seen: number;
  seenHunks: ReadonlySet<number>;
  /** unchanged lines the diff still hides (each is a cursor stop; ↵ shows more) */
  gaps: Gap[];
}

export type Stop =
  | { key: string; kind: "file"; path: string }
  | { key: string; kind: "line"; path: string; row: Row }
  | { key: string; kind: "thread"; path: string; id: string }
  | { key: string; kind: "pending"; path: string; id: string }
  | { key: string; kind: "gap"; path: string; at: number };

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

  const [tab, setTab] = createSignal<"conversation" | "commits" | "files">("files");
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
  const [overlay, setOverlay] = createSignal<"map" | "words" | "address" | null>(null);
  /** the thread E is addressing, while its chooser is open */
  const [addressing, setAddressing] = createSignal<string | null>(null);
  /** its chooser is showing the commits to pick from */
  const [addressPicking, setAddressPicking] = createSignal(false);
  /** block key → viewed, ahead of the server's copy while a write is in flight */
  const [viewedOverride, setViewedOverride] = createSignal<ReadonlyMap<string, boolean>>(new Map());
  const [filter, setFilter] = createSignal("");
  const [filtering, setFiltering] = createSignal(false);

  // ── history: the branch's commits, one at a time (GitHub Desktop's view) ──
  /** the Commits tab: the branch's history down the side (GitHub's Commits tab, Desktop's list) */
  const historyOpen = () => tab() === "commits";
  /** j/k move through the commit list ("list") or the selected commit's diff ("diff") */
  const [historyFocus, setHistoryFocus] = createSignal<"list" | "diff">("list");
  /** the commit whose diff the page shows instead of the whole branch's; null = all changes */
  const [commitScope, setCommitScope] = createSignal<string | null>(null);
  const [commitFiles, setCommitFiles] = createSignal<{ sha: string; files: NodeFile[] } | null>(null);
  const [history, setHistory] = createSignal<{ key: string; rows: HistoryCommit[] } | null>(null);

  const [payload, setPayload] = createSignal<{ key: string; data: NodePayload } | null>(null);
  const [loadErr, setLoadErr] = createSignal<string | null>(null);
  const cache = new Map<string, NodePayload>();
  const keyOf = createMemo(() => `${id()}@${tip()}`);

  // Unchanged lines revealed around the hunks, per file: the new file read once at the tip (the
  // tip's sha, so it's exactly the file the diff's new side shows) and how many lines each gap shows.
  type Context = { lines?: string[]; reveal: ReadonlyMap<number, number> };
  const [context, setContext] = createSignal<{ key: string; files: ReadonlyMap<string, Context> }>({ key: "", files: new Map() });
  const contextKey = () => `${keyOf()}|${commitScope() ?? ""}`;
  const contextOf = (path: string): Context | undefined => (context().key === contextKey() ? context().files.get(path) : undefined);
  const putContext = (key: string, path: string, c: Context) =>
    setContext((cur) => ({ key, files: new Map(cur.key === key ? cur.files : []).set(path, c) }));
  /** Show `n` more hidden lines at a gap; returns once the file's text is here. */
  async function reveal(path: string, at: number, n = 20): Promise<void> {
    const key = contextKey();
    const t = target();
    const was: Context = contextOf(path) ?? { reveal: new Map() };
    putContext(key, path, { ...was, reveal: new Map(was.reveal).set(at, (was.reveal.get(at) ?? 0) + n) });
    if (was.lines || !t || !tip()) return;
    const text = await getText(atRepoPath(t.repo, `/file?branch=${commitScope() ?? tip()}&path=${encodeURIComponent(path)}`));
    if (text == null || contextKey() !== key) return;
    putContext(key, path, { ...(contextOf(path) ?? was), lines: text.split("\n") });
  }

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
        setCommitScope(null);
        setHistory(null);
      }
      void load(key, t.repo, t.name);
    }),
  );
  createEffect(
    on(tab, (t) => {
      if (t === "commits") void loadHistory();
      else if (commitScope() != null) void showCommit(null);
      setHistoryFocus("list");
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

  const scoped = () => commitScope() != null;
  const files = createMemo<FileDiff[]>(() => {
    const src = scoped() ? (commitFiles()?.sha === commitScope() ? commitFiles()!.files : []) : (payload()?.data.files ?? []);
    return src.map((f) => ({ ...parsePatch(f.path, f.patch || ""), add: f.add, del: f.del }));
  });

  /** The branch's own commits, newest first (GET /commits): the history list. */
  /** the history's freshness: the tip, and what origin has — a push changes the second, not the first */
  const historyKey = () => `${keyOf()}|${branch()?.pushed ?? ""}|${branch()?.ahead ?? ""}`;
  async function loadHistory(): Promise<void> {
    const t = target();
    const key = historyKey();
    if (!t || history()?.key === key) return;
    const rows = await getJSON<HistoryCommit[]>(atRepoPath(t.repo, `/commits?branch=${encodeURIComponent(t.name)}`)).catch(() => null);
    if (rows && historyKey() === key) setHistory({ key, rows: rows.filter((r) => r.own) });
  }
  // a push (or a fetch) changes what origin has without moving the tip: the list's pushed marks follow
  createEffect(on(historyKey, () => tab() === "commits" && void loadHistory(), { defer: true }));

  /** Show one commit's diff (GET /commit-diff), or the whole branch again with null. */
  async function showCommit(sha: string | null): Promise<void> {
    setCommitScope(sha);
    setCursor(undefined);
    setMark(undefined);
    if (!sha || commitFiles()?.sha === sha) return;
    const t = target();
    if (!t) return;
    const got = await getJSON<{ sha: string; files: NodeFile[] }>(atRepoPath(t.repo, `/commit-diff?sha=${encodeURIComponent(sha)}`)).catch(() => null);
    if (got && commitScope() === sha) setCommitFiles({ sha, files: got.files });
  }
  const base = () => payload()?.data.baseSha ?? "";

  const threads = createMemo(() => list("thread").filter((t) => t.branch === target()?.name && t.repo === target()?.repo));
  const items = createMemo(() => (draft()?.items ?? []).filter(local));
  /** replies not on GitHub yet, by thread id */
  const repliesTo = (threadId: string) => items().filter((i) => i.kind === "reply" && i.threadId === threadId);

  const serverViewed = createMemo(() => new Set(view("viewed", id())?.keys ?? []));
  const isSeen = (key: string) => viewedOverride().get(key) ?? serverViewed().has(key);
  // an override the server now agrees with has done its job; dropping it lets later changes through
  createEffect(
    on(serverViewed, (srv) => {
      const o = viewedOverride();
      if ([...o].some(([k, v]) => srv.has(k) === v)) setViewedOverride(new Map([...o].filter(([k, v]) => srv.has(k) !== v)));
    }),
  );

  const views = createMemo<FileView[]>(() => {
    const sp = split();
    const byPath = new Map<string, Thread[]>();
    for (const t of threads()) (byPath.get(t.path) ?? byPath.set(t.path, []).get(t.path)!).push(t);
    const pend = new Map<string, Item[]>();
    for (const c of items()) if (c.kind === "comment" && c.path) (pend.get(c.path) ?? pend.set(c.path, []).get(c.path)!).push(c);
    return files().map((raw) => {
      const c = contextOf(raw.path);
      if (scoped()) {
        // one commit, read-only: its lines are that commit's, so no threads, drafts or viewed marks
        const { file, gaps } = expand(raw, c?.lines, c?.reveal ?? new Map());
        return { file, rows: rowsOf(file, sp), threadsAt: new Map(), pendingAt: new Map(), aside: [], open: 0, viewed: false, blocks: [], seen: 0, seenHunks: new Set<number>(), gaps };
      }
      const { file, gaps } = expand(raw, c?.lines, c?.reveal ?? new Map());
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
      const blocks = blocksOf(raw);
      const seenKeys = blocks.filter((b) => isSeen(b.key));
      const seenHunks = new Set<number>(raw.hunks.map((_, i) => i).filter((i) => blocks.some((b) => b.hunk === i) && blocks.every((b) => b.hunk !== i || isSeen(b.key))));
      const viewed = blocks.length > 0 && seenKeys.length === blocks.length;
      return { file, rows, threadsAt, pendingAt, aside, open, viewed, blocks, seen: seenKeys.length, seenHunks, gaps };
    });
  });

  /** Threads not on any file of this diff (a file the branch no longer changes). */
  const elsewhere = createMemo(() => {
    if (scoped()) return [];   // one commit's view is its diff alone
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
      const gapAt = new Map(fv.gaps.map((g) => [g.at, g]));
      const gap = (at: number) => gapAt.has(at) && out.push({ key: `g|${path}|${at}`, kind: "gap", path, at });
      fv.rows.forEach((r, i) => {
        if (i === 0 || fv.rows[i - 1].hunk !== r.hunk) gap(r.hunk);
        out.push({ key: `l|${path}|${r.key}`, kind: "line", path, row: r });
        const at = atRow(fv, r);
        for (const t of at.threads) thread(t);
        for (const c of at.pending) out.push({ key: `p|${c.key}`, kind: "pending", path, id: c.key });
      });
      gap(fv.file.hunks.length);
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
    target, id, conv, draft, branch, tip, base, files, views, reveal, threads, items, repliesTo, elsewhere, stops, stopIndex, here, range,
    fileOf, isOpen, atRow, isSeen, serverViewed, payload, loadErr, warm,
    tab, setTab, split, setSplit, showOutdated, setShowOutdated, cursor, setCursor, mark, setMark,
    unfold, setUnfold, composer, setComposer, text, setText,
    historyOpen, historyFocus, setHistoryFocus, commitScope, history, loadHistory, showCommit, scoped,
    overlay, setOverlay, addressing, setAddressing, addressPicking, setAddressPicking, viewedOverride, setViewedOverride, filter, setFilter, filtering, setFiltering,
  };
});

/** The side and line number a row is commented on: its new line when it has one. */
export function sideLine(r: Row): { side: "RIGHT" | "LEFT"; line: number } {
  return r.right ? { side: "RIGHT", line: r.right.new! } : { side: "LEFT", line: r.left!.old! };
}

/** A short sha. */
export const short = (sha: string) => sha.slice(0, 7);
