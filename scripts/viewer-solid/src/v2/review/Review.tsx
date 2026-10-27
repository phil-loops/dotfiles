// The review page: GitHub's pull-request review, local. Files changed — a file tree with viewed
// boxes, the diff (unified or split) with conversations folded in at their lines — and the
// Conversation. Everything it does is a registered command (commands/review.ts); this file draws.
import { createEffect, createMemo, createSelector, For, Match, on, onCleanup, Show, Switch } from "solid-js";
import Key from "../Key";
import { keyOf } from "../registry";
import { bind } from "../runner";
import { view, world } from "../store";
import type { Thread } from "../types";
import { rowAnchors, type FileDiff, type Gap, type Line, type Row } from "./diff";
import { highlight, langOf } from "./highlight";
import { BASES, page as pg, rowsOf, short, type FileView } from "./page";
import { ThreadView, PendingView, ComposerView } from "./Thread";
import Conversation from "./Conversation";
import { CommitWords } from "../Commits";
import Commits from "../Commits";
import { prValue } from "../words";
import { AddressSheet, MapOverlay } from "./Overlays";
import ShipLine from "./Ship";
import TypesPop from "./TypesPop";
import { notePointer } from "./types";

export default function Review() {
  const selected = createSelector(() => pg.here()?.key);
  createEffect(
    on(
      () => pg.here()?.key,
      (k) => {
        if (!k) return;
        requestAnimationFrame(() => document.querySelector(`[data-stop="${CSS.escape(k)}"]`)?.scrollIntoView({ block: "nearest" }));
      },
    ),
  );
  // meaningful = the diff AND its conversations: the store's first snapshot has landed too
  const loaded = () => !!pg.payload() && world.ready;
  return (
    <div class="rv">
      <Header />
      <Show when={pg.target()} fallback={<p class="px-4 text-ink-faint">no branch in the address</p>}>
        <Switch>
          <Match when={pg.tab() === "conversation"}>
            <Conversation />
          </Match>
          <Match when={pg.tab() === "commits"}>
            <div class="rv-body rv-body-commits">
              <aside class="rv-tree">
                <History />
              </aside>
              <div class="rv-files" data-paint="commits">
                <Show when={pg.scoped()} fallback={<LandsAs />}>
                  <CommitHead />
                  <Show when={pg.files().length} fallback={<p class="rv-quiet">reading the commit…</p>}>
                    <For each={pg.files()}>{(f) => <FileBlock file={f} selected={selected} />}</For>
                  </Show>
                </Show>
              </div>
            </div>
          </Match>
          <Match when={pg.tab() === "files"}>
            <div class="rv-body">
              <FileTree />
              <div class="rv-files" data-paint={loaded() ? "review" : undefined} onPointerMove={notePointer}>
                <Show when={loaded()} fallback={<p class="rv-quiet">{pg.loadErr() ? `couldn't read the diff — ${pg.loadErr()}` : "reading the diff…"}</p>}>
                  <Show when={pg.files().length} fallback={<p class="rv-quiet">{pg.base() === "outgoing" ? "nothing to push" : "no changes"}</p>}>
                    <For each={pg.files()}>{(f) => <FileBlock file={f} selected={selected} />}</For>
                    <Elsewhere selected={selected} />
                  </Show>
                </Show>
              </div>
            </div>
          </Match>
        </Switch>
      </Show>
      <Show when={pg.overlay() === "map"}>
        <MapOverlay />
      </Show>
      <Show when={pg.overlay() === "address"}>
        <AddressSheet />
      </Show>
      <TypesPop />
    </div>
  );
}

function Header() {
  const c = () => pg.conv();
  /** what the header says with no conversation yet: a known PR still loading, GitHub not read yet, or none */
  const noPr = () => {
    const pr = view("pr", pg.id());
    if (pr) return `#${pr.number} · loading its conversation…`;
    return world.entities.warm[pg.target()?.repo ?? ""]?.prs ? "no PR" : "reading GitHub…";
  };
  const t = () => pg.target();
  const pending = () => c()?.pending?.count ?? 0;
  const drafts = () => pg.items().filter((i) => i.state === "draft").length;
  const waiting = () => pg.items().filter((i) => i.state === "waiting").length;
  const latest = createMemo(() => {
    const by = new Map<string, string>();
    for (const r of c()?.reviews ?? []) if (r.state !== "COMMENTED") by.set(r.author, r.state);
    return [...by.entries()];
  });
  // The file headers and the tree stick just under this header, so they read its real height —
  // a fixed offset left a strip of diff showing through whenever the header's content changed.
  const trackHeight = (el: HTMLElement) => {
    const ro = new ResizeObserver(() => el.closest<HTMLElement>(".rv")?.style.setProperty("--rv-head-h", `${el.offsetHeight}px`));
    ro.observe(el);
    onCleanup(() => ro.disconnect());
  };
  const openThreads = () => pg.threads().filter((x) => !x.resolved && !x.outdated).length;
  return (
    <header class="rv-head" ref={trackHeight}>
      <div class="rv-title">
        <Show when={c()} fallback={<span class="font-display text-[20px] text-ink">{pg.integration() ? `✦ ${view("project", pg.integration()!)?.name} — every branch merged onto main` : view("branch", pg.id())?.description || t()?.name}</span>}>
          <span class="font-display text-[20px] text-ink">{c()!.title}</span>
          <a class="ml-2 text-ink-faint no-underline hover:text-ink hover:underline" href={c()!.url} target="_blank" rel="noopener" title="open on GitHub">#{c()!.number}</a>
        </Show>
        <span class="flex-1" />
        <button class="rv-quietbtn mr-3" onClick={bind("review.preview", pg.id())} title="spin up a dev server for this branch on a side port and open it once it answers — leaves :3000 and your checkout alone">
          <Key id="review.preview" class="rv-tabkey" /> ▷ preview
        </button>
        <Show when={c()}>
          <Show when={drafts()}>
            <button class="rv-quietbtn mr-3" onClick={bind("review.send.all")} title="send every draft to your pending review">
              {drafts()} draft{drafts() === 1 ? "" : "s"}
            </button>
          </Show>
          <Show when={pending()}>
            <button class="rv-finish rv-finish-on" onClick={bind("review.finish")} title="your pending review is private until you submit it on GitHub">
              {pending()} pending · submit
            </button>
          </Show>
        </Show>
      </div>
      <div class="rv-sub">
        <ShipLine />
        <Show when={c()}>
          <span>→ {c()!.base}</span>
          <span>@{c()!.author}</span>
          <For each={latest()}>{([who, st]) => <span class={st === "APPROVED" ? "text-patina" : "text-ember"}>{who} {st === "APPROVED" ? "approved" : "requested changes"}</span>}</For>
          <Show when={c()!.mapping === "behind"}>
            <span class="text-ember" title="threads sit at their lines on the local tip; ones whose lines it doesn't have yet show beside their file">
              {c()!.behind} commit{c()!.behind === 1 ? "" : "s"} on GitHub not here — pull to review what's there
            </span>
          </Show>
          <Show when={waiting()}>
            <span class="text-gold-leaf">{waiting()} draft{waiting() === 1 ? " waits" : "s wait"} for a push</span>
          </Show>
        </Show>
        <Show when={!c() && world.ready && view("branch", pg.id())?.pushed !== "local"}>
          <span class="text-ink-faint">{noPr()}</span>
        </Show>
      </div>
      <nav class="rv-tabs">
        <button classList={{ "rv-tab-on": pg.tab() === "conversation" }} onClick={bind("review.tab.conversation")}>
          <Key id="review.tab.conversation" class="rv-tabkey" /> conversation <span class="rv-count">{(c()?.comments.length ?? 0) + (c()?.reviews.filter((r) => r.body).length ?? 0) + pg.threads().length}</span>
        </button>
        <button classList={{ "rv-tab-on": pg.tab() === "commits" }} onClick={bind("review.tab.commits")}>
          <Key id="review.tab.commits" class="rv-tabkey" /> commits <span class="rv-count">{view("branch", pg.id())?.commits ?? ""}</span>
          <Show when={(view("branch", pg.id())?.ahead ?? 0) > 0 || view("branch", pg.id())?.pushed === "local"}>
            <span class="rv-count rv-count-gold">{view("branch", pg.id())?.pushed === "local" ? "local" : `${view("branch", pg.id())!.ahead} to push`}</span>
          </Show>
        </button>
        <button classList={{ "rv-tab-on": pg.tab() === "files" }} onClick={bind("review.tab.files")}>
          <Key id="review.tab.files" class="rv-tabkey" /> files <span class="rv-count">{pg.branchFiles().length}</span>
        </button>
        <span class="flex-1" />
        <span class="rv-meta">
          <Show when={pg.tab() === "files" && !pg.integration()}>
            vs{" "}
            <button class="rv-quietbtn text-gold-leaf" onClick={bind("review.base.next")} title={`the diff's base — ${keyOf("review.base.parent").replace(/ \S+$/, "")} picks`}>
              {BASES.find((x) => x.base === pg.base())!.word}
            </button>
            {" · "}
          </Show>
          {openThreads()} open · viewed {pg.branchViewed()}/{pg.branchFiles().length}
        </span>
      </nav>
    </header>
  );
}

/** The branch's commits down the side, newest first: j/k step through them, the diff shows only
 *  the selected one; "all changes" is the whole branch again. */
function History() {
  const rows = () => pg.history()?.rows ?? [];
  const on = (sha: string | null) => pg.commitScope() === sha;
  const focused = () => pg.historyFocus() === "list";
  /** the commit that lands on main is the PR's: its title once it's open, the drafted one before */
  const landing = () => pg.conv()?.title ?? (prValue(pg.id()).subject || view("branch", pg.id())?.description);
  return (
    <div class="rv-history" classList={{ "rv-history-focus": focused() }}>
      <button class="rv-hrow" classList={{ "rv-hrow-on": on(null) }} onClick={bind("history.select", "")}>
        <span class="rv-hsub">{landing() || "—"}</span>
        <span class="rv-hmeta">lands on main{pg.conv() ? ` · #${pg.conv()!.number}` : ""}</span>
      </button>
      <For each={rows()} fallback={<p class="rv-quiet">{pg.history() ? "no commits of its own" : "reading the commits…"}</p>}>
        {(c) => (
          <button class="rv-hrow" classList={{ "rv-hrow-on": on(c.sha) }} onClick={bind("history.select", c.sha)} title={c.body || c.subject}>
            <span class="rv-hsub">{c.subject}</span>
            <span class="rv-hmeta">
              <code classList={{ "text-gold-leaf": c.pushed === false }}>{c.sha.slice(0, 7)}</code> · {c.date.replace(/^\d{4}-/, "")}
              {c.pushed === false ? " · local" : ""}
            </span>
            <For each={addresses(c.sha)}>{(a) => <span class="rv-hmeta text-gold-leaf">→ {a}</span>}</For>
          </button>
        )}
      </For>
    </div>
  );
}

/** The landing commit selected: its title and why, edited here until the PR owns them. */
function LandsAs() {
  return (
    <div class="rv-outgoing" data-paint="commits">
      <Commits branchId={pg.id()} landing landingOnly />
      <p class="rv-quiet">its diff is the whole branch: the files tab</p>
    </div>
  );
}

/** The threads a commit declares it addresses, as "author on file:line". */
const addresses = (sha: string) =>
  pg.threads().filter((t) => t.fixedBy?.some((f) => f.sha.startsWith(sha))).map((t) => `${t.comments[0]?.author} on ${t.path.split("/").pop()}:${t.local?.line ?? t.line}`);

/** Above a single commit's diff: which commit, its why, and the threads it addresses (not their raw trailer URLs). */
function CommitHead() {
  const c = () => pg.history()?.rows.find((r) => r.sha === pg.commitScope());
  const why = () => (c()?.body ?? "").replace(/^Addresses:.*$/gm, "").trim();
  return (
    <div class="rv-commit-head">
      <div class="text-[11px] text-ink-faint">
        <code class="text-gold-leaf">{pg.commitScope()?.slice(0, 7)}</code> · {c()?.date}
        {c()?.pushed === false ? " · local" : ""} · this commit's {pg.files().length} file{pg.files().length === 1 ? "" : "s"}
      </div>
      <CommitWords
        branchId={pg.id()}
        sha={pg.commitScope() ?? ""}
        fallback={
          <>
            <div class="text-ink">{c()?.subject}</div>
            <Show when={why()}>
              <pre class="m-0 mt-1 whitespace-pre-wrap font-mono text-[12px] text-ink-dim">{why()}</pre>
            </Show>
          </>
        }
      />
      <For each={addresses(pg.commitScope() ?? "")}>{(a) => <div class="mt-0.5 text-[12px] text-gold-leaf">→ {a}</div>}</For>
    </div>
  );
}

function FileTree() {
  const groups = createMemo(() => {
    const q = pg.filter().toLowerCase();
    const out: { dir: string; files: FileView[] }[] = [];
    for (const v of pg.views()) {
      if (q && !v.file.path.toLowerCase().includes(q)) continue;
      const i = v.file.path.lastIndexOf("/");
      const dir = i < 0 ? "" : v.file.path.slice(0, i);
      const g = out[out.length - 1];
      if (g && g.dir === dir) g.files.push(v);
      else out.push({ dir, files: [v] });
    }
    return out;
  });
  const current = () => pg.here()?.path;
  let input!: HTMLInputElement;
  createEffect(() => {
    if (pg.filtering()) queueMicrotask(() => input?.focus());
  });
  return (
    <aside class="rv-tree">
      <Show when={pg.filtering() || pg.filter()}>
        <input
          ref={input}
          class="rv-filter"
          placeholder="filter files…"
          value={pg.filter()}
          onInput={(e) => pg.setFilter(e.currentTarget.value)}
          onKeyDown={(e) => {
            if (e.key === "Escape" || e.key === "Enter") {
              e.preventDefault();
              const first = groups()[0]?.files[0]?.file.path;
              if (e.key === "Escape") pg.setFilter("");
              pg.setFiltering(false);
              input.blur();
              if (e.key === "Enter" && first) pg.setCursor(`f|${first}`);
            }
          }}
        />
      </Show>
      <For each={groups()}>
        {(g) => (
          <div>
            <Show when={g.dir}>
              <div class="rv-dir">{g.dir}/</div>
            </Show>
            <For each={g.files}>
              {(v) => (
                <div class="rv-tfile" classList={{ "rv-tfile-on": current() === v.file.path, "rv-tfile-done": v.viewed }}>
                  <button class="rv-check" title={v.viewed ? `viewed — ${keyOf("review.viewed")} unmarks it` : `mark viewed (${keyOf("review.viewed")})`} onClick={bind("review.viewed.file", v.file.path)}>
                    {v.viewed ? "☑" : v.seen ? "◪" : "☐"}
                  </button>
                  <button class="rv-tname" onClick={bind("review.file.go", v.file.path)} title={v.file.path}>
                    <span class="rv-thead">{baseName(v.file.path).slice(0, -TAIL)}</span>
                    <span class="shrink-0">{baseName(v.file.path).slice(-TAIL)}</span>
                  </button>
                  <Show when={v.open}>
                    <span class="rv-dot" title={`${v.open} open conversation${v.open === 1 ? "" : "s"}`}>{v.open}</span>
                  </Show>
                  <span class="rv-pm">
                    <span class="text-add">+{v.file.add}</span> <span class="text-del">−{v.file.del}</span>
                  </span>
                </div>
              )}
            </For>
          </div>
        )}
      </For>
    </aside>
  );
}

/** A file name cut in the middle when it doesn't fit, so its end — what tells two files apart — always shows. */
const TAIL = 14;
const baseName = (path: string) => path.slice(path.lastIndexOf("/") + 1);

function FileBlock(props: { file: FileDiff; selected: (k: string | undefined) => boolean }) {
  const fv = createMemo(() => pg.fileOf(props.file.path));
  const lang = langOf(props.file.path);
  // the file as shown: with whatever unchanged lines have been revealed around its hunks
  const file = () => fv()?.file ?? props.file;
  const rows = createMemo(() => fv()?.rows ?? rowsOf(props.file, pg.split()));
  const gapAt = (at: number) => fv()?.gaps.find((g) => g.at === at);
  const key = `f|${props.file.path}`;
  const aside = createMemo(() => (fv()?.aside ?? []).filter((t) => !t.outdated || pg.showOutdated()));
  const hiddenOutdated = createMemo(() => (fv()?.aside ?? []).filter((t) => t.outdated).length);
  return (
    <section class="rv-file">
      <div class="rv-fhead" data-stop={key} classList={{ "rv-on": props.selected(key) }} onClick={bind("review.cursor.set", key)}>
        <button class="rv-check" onClick={bind("review.viewed.file", props.file.path)}>{fv()?.viewed ? "☑" : "☐"}</button>
        <span class="rv-fpath">{props.file.path}</span>
        <Show when={props.file.status !== "modified"}>
          <span class="rv-fstat">{props.file.status}</span>
        </Show>
        <span class="text-add">+{props.file.add}</span>
        <span class="text-del">−{props.file.del}</span>
        <span class="flex-1" />
        <Show when={hiddenOutdated() && !pg.showOutdated()}>
          <button class="rv-quietbtn" onClick={bind("review.outdated")}>{hiddenOutdated()} outdated</button>
        </Show>
        <span class="rv-viewed">
          {fv()?.viewed ? "viewed" : fv()?.seen ? `${fv()!.seen}/${fv()!.blocks.length} viewed` : ""}
        </span>
      </div>
      <Show when={!fv()?.viewed}>
        <For each={aside()}>{(t) => <ThreadView id={t.id} selected={props.selected} aside />}</For>
        <div class="rv-diff" classList={{ "rv-split": pg.split() }}>
          <For each={rows()}>
            {(r, i) => (
              <>
                <Show when={(i() === 0 || rows()[i() - 1].hunk !== r.hunk) && gapAt(r.hunk)} keyed>
                  {(g) => <GapRow path={props.file.path} gap={g} selected={props.selected} />}
                </Show>
                <RowView file={file()} row={r} lang={lang} selected={props.selected} />
                <RowExtras file={file()} row={r} selected={props.selected} />
              </>
            )}
          </For>
          <Show when={gapAt(file().hunks.length)} keyed>
            {(g) => <GapRow path={props.file.path} gap={g} selected={props.selected} />}
          </Show>
        </div>
      </Show>
    </section>
  );
}

/** Unchanged lines the diff leaves out: ↵ (or a click) shows 20 more, nearest the change first. */
function GapRow(props: { path: string; gap: Gap; selected: (k: string | undefined) => boolean }) {
  const key = `g|${props.path}|${props.gap.at}`;
  const n = () => (props.gap.last == null ? null : props.gap.last - props.gap.first + 1);
  const where = () => (props.gap.at === 0 ? "above" : props.gap.last == null || props.gap.label === "" ? "below" : "hidden");
  return (
    <div
      class="rv-hunk rv-gap"
      data-stop={key}
      classList={{ "rv-on": props.selected(key) }}
      onClick={bind("review.expand", key)}
      title="show 20 more lines"
    >
      <span class="rv-gap-mark">⋯</span> {n() == null ? "more lines" : `${n()} ${where() === "hidden" ? "hidden" : "unchanged"} line${n() === 1 ? "" : "s"}${where() === "hidden" ? "" : ` ${where()}`}`}
      <Show when={props.gap.label}>
        <span class="text-ink-faint"> · {props.gap.label}</span>
      </Show>
      <Show when={props.selected(key)}>
        <span class="text-ink-faint"> · {keyOf("review.expand")} 20 more</span>
      </Show>
    </div>
  );
}

function spanOf(id: string) {
  const t = view("thread", id) as Thread | undefined;
  return t?.local ? { path: t.path, side: t.side, line: t.local.line, startLine: t.local.startLine } : null;
}

function Code(props: { line: Line; path: string; lang: string; side: "new" | "old" }) {
  return (
    <span
      class="rv-code"
      data-code=""
      data-path={props.path}
      data-side={props.side}
      data-line={props.side === "new" ? props.line.new! : props.line.old!}
      innerHTML={highlight(props.line.text, props.lang) || " "}
    />
  );
}

function RowView(props: { file: FileDiff; row: Row; lang: string; selected: (k: string | undefined) => boolean }) {
  const key = `l|${props.file.path}|${props.row.key}`;
  const r = props.row;
  // the range x selected, or the lines the selected conversation covers
  const marked = createMemo(() => {
    const h = pg.here();
    const rg = h?.kind === "thread" ? spanOf(h.id) : pg.range();
    if (!rg || !rg.startLine || rg.path !== props.file.path) return false;
    const n = rg.side === "RIGHT" ? r.right?.new : r.left?.old;
    return n != null && n >= rg.startLine && n <= rg.line;
  });
  const threaded = createMemo(() => {
    const fv = pg.fileOf(props.file.path);
    return !!fv && rowAnchors(r).some((a) => fv.threadsAt.has(a));
  });
  // a hunk whose changes are all viewed dims, so what's left to read stands out
  const seen = createMemo(() => !!pg.fileOf(props.file.path)?.seenHunks.has(r.hunk));
  return (
    <div
      class="rv-row"
      data-stop={key}
      classList={{ "rv-on": props.selected(key), "rv-marked": marked(), "rv-threaded": threaded(), "rv-seen": seen() }}
      onClick={bind("review.cursor.set", key)}
    >
      <Show
        when={pg.split()}
        fallback={
          <>
            <button class="rv-plus" title="comment (c) · shift-click for a range" onClick={bind("review.gutter", key)}>+</button>
            <span class="rv-num">{r.left?.old ?? ""}</span>
            <span class="rv-num">{r.right?.new ?? ""}</span>
            <span class={`rv-sign rv-${(r.left ?? r.right)!.kind === "ctx" ? "ctx" : r.right ? "add" : "del"}`}>{r.right && r.left ? " " : r.right ? "+" : "−"}</span>
            <span class={`rv-line rv-${r.left && r.right ? "ctx" : r.right ? "add" : "del"}`}>
              <Code line={(r.right ?? r.left)!} path={props.file.path} lang={props.lang} side={r.right ? "new" : "old"} />
            </span>
          </>
        }
      >
        <button class="rv-plus" onClick={bind("review.gutter", key)}>+</button>
        <span class="rv-num">{r.left?.old ?? ""}</span>
        <span class={`rv-line rv-half rv-${!r.left ? "none" : r.left.kind === "ctx" ? "ctx" : "del"}`}>
          <Show when={r.left}>
            <Code line={r.left!} path={props.file.path} lang={props.lang} side="old" />
          </Show>
        </span>
        <span class="rv-num">{r.right?.new ?? ""}</span>
        <span class={`rv-line rv-half rv-${!r.right ? "none" : r.right.kind === "ctx" ? "ctx" : "add"}`}>
          <Show when={r.right}>
            <Code line={r.right!} path={props.file.path} lang={props.lang} side="new" />
          </Show>
        </span>
      </Show>
    </div>
  );
}

/** What hangs under a row: its conversations, pending comments, and the comment box when it's open here. */
function RowExtras(props: { file: FileDiff; row: Row; selected: (k: string | undefined) => boolean }) {
  const at = createMemo(() => {
    const fv = pg.fileOf(props.file.path);
    return fv ? pg.atRow(fv, props.row) : { threads: [] as Thread[], pending: [] };
  });
  // the comment box opens under the first row showing its line
  const composing = createMemo(() => {
    const c = pg.composer();
    if (c?.kind !== "line" || c.path !== props.file.path) return false;
    const want = `${c.side === "LEFT" ? "L" : "R"}:${c.line}`;
    return rowsOf(props.file, pg.split()).find((r) => rowAnchors(r).includes(want)) === props.row;
  });
  return (
    <Show when={at().threads.length || at().pending.length || composing()}>
      <div class="rv-extras">
        <For each={at().threads}>{(t) => <ThreadView id={t.id} selected={props.selected} />}</For>
        <For each={at().pending}>{(c) => <PendingView item={c} selected={props.selected} />}</For>
        <Show when={composing()}>
          <ComposerView />
        </Show>
      </div>
    </Show>
  );
}

function Elsewhere(props: { selected: (k: string | undefined) => boolean }) {
  return (
    <Show when={pg.elsewhere().length}>
      <section class="rv-file">
        <div class="rv-fhead">
          <span class="rv-fpath text-ink-dim">threads on files it no longer changes</span>
        </div>
        <For each={pg.elsewhere()}>{(t) => <ThreadView id={t.id} selected={props.selected} aside />}</For>
      </section>
    </Show>
  );
}

export { short };
