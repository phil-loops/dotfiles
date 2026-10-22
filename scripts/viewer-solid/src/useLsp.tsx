import { createSignal, onCleanup, Show, For, type JSX } from "solid-js";
import { Portal } from "solid-js/web";
import { withRepo } from "./provider";
import { renderMarkdown } from "./markdown";
import { chord, sideOf, wordAt, type Leader, type LspAction } from "./lspKeys";
import { mapOpen } from "./mapState";
import { storySheetOpen } from "./StorySheet";

// Types on demand, the Helix way: K (or space·k) shows the type under the pointer, g·d jumps to
// its definition when the diff shows it. The
// server's one tsgo (srv/lsp.py) starts on the first ask, never before. Only the NEW side of a
// diff exists at the branch tip, so a removed line answers with a note instead of a request.

type At = { top: number; bottom: number; left: number }; // document coordinates
type Target = { path: string; line: number; character: number; at: At };
type Loc = { path: string; line: number; character: number; endLine: number };
type Status = { state: string; message?: string; progress?: { title?: string; message?: string; percentage?: number } | null };
type Pop =
  | { kind: "wait"; at: At; since: number }
  | { kind: "hover"; at: At; md: string }
  | { kind: "note"; at: At | null; text: string; warn?: boolean }
  | { kind: "picks"; at: At; locs: Loc[]; sel: number };

const CHORD_MS = 600;
const NOTE_MS = 1800;

const ctnOf = (n: Node | null | undefined) =>
  (n instanceof Element ? n : n?.parentElement)?.closest<HTMLElement>(".d2h-code-line-ctn") ?? null;

function caretAt(x: number, y: number): { node: Node; offset: number } | null {
  const d = document as Document & {
    caretPositionFromPoint?: (x: number, y: number) => { offsetNode: Node; offset: number } | null;
    caretRangeFromPoint?: (x: number, y: number) => Range | null;
  };
  const p = d.caretPositionFromPoint?.(x, y);
  if (p) return { node: p.offsetNode, offset: p.offset };
  const r = d.caretRangeFromPoint?.(x, y);
  return r ? { node: r.startContainer, offset: r.startOffset } : null;
}

// a [start, end) span of a line's text → a Range over diff2html's text nodes (its <ins>/<del> split them)
function spanRange(ctn: HTMLElement, start: number, end: number): Range {
  const r = document.createRange();
  const walk = document.createTreeWalker(ctn, NodeFilter.SHOW_TEXT);
  let pos = 0, started = false;
  for (let n = walk.nextNode(); n; n = walk.nextNode()) {
    const len = n.textContent?.length ?? 0;
    if (!started && start <= pos + len) { r.setStart(n, start - pos); started = true; }
    if (started && end <= pos + len) { r.setEnd(n, end - pos); return r; }
    pos += len;
  }
  r.selectNodeContents(ctn);
  return r;
}

function docRect(r: Range | Element): At {
  const b = r.getBoundingClientRect();
  return { top: b.top + window.scrollY, bottom: b.bottom + window.scrollY, left: b.left + window.scrollX };
}

type Resolved = { kind: "new"; t: Target } | { kind: "old" | "skip"; at: At; why: string } | null;

// a caret in a diff → the tip file position it names, or why there isn't one
function resolve(node: Node, offset: number): Resolved {
  const ctn = ctnOf(node);
  const td = ctn?.closest("td");
  const tr = td?.closest("tr");
  const entry = ctn?.closest<HTMLElement>(".entry");
  if (!ctn || !td || !tr || !entry) return null;
  const upTo = document.createRange();
  upTo.setStart(ctn, 0);
  upTo.setEnd(node, offset);
  const caret = upTo.toString().length; // UTF-16 units — LSP's default position encoding
  const word = wordAt(ctn.textContent ?? "", caret);
  const at = docRect(spanRange(ctn, word?.start ?? caret, word?.end ?? caret));
  if (entry.closest(".uncommitted-rail")) return { kind: "skip", at, why: "uncommitted — types follow the committed tip" };
  const half = tr.closest(".d2h-file-side-diff");
  const halves = half ? [...half.parentElement!.children].filter((c) => c.classList.contains("d2h-file-side-diff")) : [];
  const side = sideOf([...td.classList], half ? halves.indexOf(half) : null);
  if (side === "none") return null;
  if (side === "old") return { kind: "old", at, why: "removed code — no types" };
  let numbered: Element | undefined = tr;
  if (side === "twin") {
    const i = [...half!.querySelectorAll("tbody > tr")].indexOf(tr);
    numbered = halves[1]?.querySelectorAll("tbody > tr")[i];
  }
  const ln = numbered?.querySelector(".line-num2") ?? numbered?.querySelector(".d2h-code-side-linenumber");
  const line = parseInt(ln?.textContent?.trim() ?? "", 10);
  if (!Number.isFinite(line)) return null;
  return { kind: "new", t: { path: entry.dataset.path ?? "", line, character: word?.start ?? caret, at } };
}

// the diff row showing <path>:<line> on its new side, if this page renders it
function rowFor(path: string, line: number): HTMLElement | null {
  const entry = [...document.querySelectorAll<HTMLElement>(`.entry[data-path="${CSS.escape(path)}"]`)]
    .find((e) => !e.closest(".uncommitted-rail"));
  if (!entry) return null;
  const halves = entry.querySelectorAll(".d2h-file-side-diff");
  const cells = halves.length
    ? halves[1].querySelectorAll(".d2h-code-side-linenumber")
    : entry.querySelectorAll(".line-num2");
  const hit = [...cells].find((c) => c.textContent?.trim() === String(line));
  return hit?.closest("tr") ?? null;
}

const leafOf = (p: string) => p.slice(p.lastIndexOf("/") + 1);
const dirOf = (p: string) => p.slice(0, p.lastIndexOf("/") + 1);

/** The K / space·k / g·d keys and their popover. Mount once on the branch page. */
export function useLsp(deps: {
  branch: () => string;
  /** why types can't be asked for right now (commits view, the integration ghost), else null */
  unavailable: () => string | null;
  pointing: () => boolean;
  blocked: () => boolean;
}) {
  const [pop, setPop] = createSignal<Pop | null>(null);
  const [status, setStatus] = createSignal<Status | null>(null);
  const [now, setNow] = createSignal(Date.now());
  let pointer: { x: number; y: number } | null = null;
  let leader: Leader = "";
  let leaderShift = false;
  let leaderT: ReturnType<typeof setTimeout> | undefined;
  let noteT: ReturnType<typeof setTimeout> | undefined;
  let inflight: AbortController | null = null;

  const note = (text: string, at: At | null, ms = NOTE_MS, warn = false) => {
    setPop({ kind: "note", at, text, warn });
    clearTimeout(noteT);
    noteT = setTimeout(() => setPop((p) => (p?.kind === "note" ? null : p)), ms);
  };
  const cancel = () => {
    inflight?.abort();
    inflight = null;
  };

  const target = (): Resolved => {
    if (pointer) {
      const c = caretAt(pointer.x, pointer.y);
      const el = document.elementFromPoint(pointer.x, pointer.y);
      if (c && el?.closest("td") && ctnOf(c.node)) return resolve(c.node, c.offset);
    }
    const sel = getSelection();
    if (sel && sel.rangeCount && !sel.isCollapsed && ctnOf(sel.anchorNode)) {
      const r = sel.getRangeAt(0);
      return resolve(r.startContainer, r.startOffset);
    }
    return null;
  };

  const jump = (loc: Loc) => {
    const row = rowFor(loc.path, loc.line);
    if (row) {
      setPop(null);
      row.scrollIntoView({ block: "center", behavior: "smooth" });
      row.classList.remove("lsp-flash");
      void row.offsetWidth; // restart the animation on a repeat jump to the same row
      row.classList.add("lsp-flash");
      setTimeout(() => row.classList.remove("lsp-flash"), 1700);
      return;
    }
    note(`${loc.path}:${loc.line} — outside this diff`, null, 3200);
  };

  const ask = async (action: LspAction, t: Target) => {
    cancel();
    const ctrl = new AbortController();
    inflight = ctrl;
    const since = Date.now();
    setStatus(null);
    const refresh = () => {
      setNow(Date.now());
      fetch(withRepo("/lsp/status")).then((r) => r.json()).then((s: Status) => !ctrl.signal.aborted && setStatus(s)).catch(() => {});
    };
    // a warm answer lands in ~30ms: only a slow one earns the waiting chip
    const showWait = setTimeout(() => { if (!ctrl.signal.aborted) { refresh(); setPop({ kind: "wait", at: t.at, since }); } }, 250);
    const poll = setInterval(refresh, 1000);
    try {
      for (;;) {
        const r = await fetch(withRepo(`/lsp/${action}`), {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ branch: deps.branch(), path: t.path, line: t.line, character: t.character }),
          signal: ctrl.signal,
        }).then((x) => x.json());
        if (ctrl.signal.aborted) return;
        if (r.state === "loading") continue; // the server held it ~20s; the same position re-attaches
        clearTimeout(showWait);
        if (!r.ok) { note(r.message ?? "no answer", t.at, r.state === "refused" ? 6000 : 4000, true); return; }
        if (action === "hover") {
          if (r.contents) setPop({ kind: "hover", at: t.at, md: r.contents });
          else note("no type information here", t.at);
          return;
        }
        const locs: Loc[] = r.locations ?? [];
        if (!locs.length) note("no definition found", t.at);
        else if (locs.length === 1) jump(locs[0]);
        else setPop({ kind: "picks", at: t.at, locs, sel: 0 });
        return;
      }
    } catch {
      if (!ctrl.signal.aborted) note("types unavailable — server unreachable", t.at, 4000, true);
    } finally {
      clearTimeout(showWait);
      clearInterval(poll);
      if (inflight === ctrl) inflight = null;
    }
  };

  const act = (action: LspAction) => {
    const why = deps.unavailable();
    if (why) { note(why, null, 3200); return; }
    const r = target();
    if (!r) { note("point at a symbol in the diff first", null); return; }
    if (r.kind !== "new") { note(r.why, r.at); return; }
    void ask(action, r.t);
  };

  const scrollPage = (up: boolean) => window.scrollBy({ top: (up ? -1 : 1) * window.innerHeight * 0.85 });
  const swallow = (e: KeyboardEvent) => { e.preventDefault(); e.stopImmediatePropagation(); };

  const onKey = (e: KeyboardEvent) => {
    if ((e.target as Element).matches?.("input, textarea, select, [contenteditable]")) return;
    if (storySheetOpen() || mapOpen() || deps.blocked()) return;
    if (e.metaKey || e.ctrlKey || e.altKey) { leader = ""; return; }
    const p = pop();
    if (e.key === "Escape" && (inflight || p)) {
      swallow(e);
      cancel();
      setPop(null);
      return;
    }
    if (p?.kind === "picks") {
      const n = p.locs.length;
      const move = (d: number) => setPop({ ...p, sel: (p.sel + d + n) % n });
      if (e.key === "j" || e.key === "ArrowDown") { swallow(e); move(1); return; }
      if (e.key === "k" || e.key === "ArrowUp") { swallow(e); move(-1); return; }
      if (e.key === "Enter") { swallow(e); jump(p.locs[p.sel]); return; }
      const digit = Number(e.key);
      if (digit >= 1 && digit <= n) { swallow(e); jump(p.locs[digit - 1]); return; }
    }
    // space is the page's scroll key until the pointer rests on code
    if (e.key === " " && !leader && !deps.pointing()) return;
    const was = leader;
    const c = chord(leader, e.key);
    clearTimeout(leaderT);
    leader = c.leader;
    if (c.consumed) swallow(e);
    if (c.leader) {
      leaderShift = e.shiftKey;
      leaderT = setTimeout(() => { if (leader === "space") scrollPage(leaderShift); leader = ""; }, CHORD_MS);
      return;
    }
    if (was === "space" && !c.action) scrollPage(leaderShift); // a broken space chord still scrolls
    if (c.action) act(c.action);
    else if (p && p.kind !== "wait") setPop(null);
  };
  const onMove = (e: MouseEvent) => { pointer = { x: e.clientX, y: e.clientY }; };
  const onDown = (e: MouseEvent) => {
    const p = pop();
    if (p && p.kind !== "wait" && !(e.target as Element).closest?.(".lsp-pop")) setPop(null);
  };
  document.addEventListener("keydown", onKey, { capture: true });
  window.addEventListener("mousemove", onMove, { passive: true });
  document.addEventListener("mousedown", onDown);
  onCleanup(() => {
    cancel();
    clearTimeout(leaderT);
    clearTimeout(noteT);
    document.removeEventListener("keydown", onKey, { capture: true });
    window.removeEventListener("mousemove", onMove);
    document.removeEventListener("mousedown", onDown);
  });

  const waitLabel = (since: number) => {
    const s = status();
    const secs = Math.max(0, Math.round((now() - since) / 1000));
    const what = s?.state === "preparing" ? `preparing ${deps.branch()}’s worktree`
      : s?.state === "starting" ? "starting tsgo"
      : `loading types for ${deps.branch()}`;
    const pr = s?.progress;
    const detail = pr ? ` · ${[pr.title, pr.message, pr.percentage != null ? `${pr.percentage}%` : ""].filter(Boolean).join(" ")}` : "";
    return `${what}… ${secs}s${detail}`;
  };

  const place = (at: At): JSX.CSSProperties => ({
    top: `${at.bottom + 6}px`,
    left: `${Math.max(window.scrollX + 12, Math.min(at.left - 4, window.scrollX + window.innerWidth - 640))}px`,
  });
  const CHIP = "lsp-pop absolute z-[240] rounded-[8px] border border-solid border-rule bg-vellum-raise px-[11px] py-[6px] font-mono text-[11px] text-ink-dim shadow-[0_10px_30px_#0008]";

  const Layer = () => (
    <>
      <Portal>
        <Show when={pop()} keyed>
          {(v) => {
            if (v.kind === "wait") {
              return (
                <div class={`${CHIP} lsp-wait flex items-center gap-[8px]`} style={place(v.at)}>
                  <span class="inline-block h-[6px] w-[6px] animate-breathe rounded-full bg-gold-leaf" />
                  <span>{waitLabel(v.since)}</span>
                  <span class="text-ink-faint">esc</span>
                </div>
              );
            }
            if (v.kind === "note") {
              return v.at ? (
                <div class={`${CHIP.replace("text-ink-dim", v.warn ? "text-ember" : "text-ink-dim")} lsp-note`} style={place(v.at)}>{v.text}</div>
              ) : (
                <div class="lsp-pop lsp-note fixed bottom-[26px] left-1/2 z-[250] max-w-[min(90vw,640px)] -translate-x-1/2 rounded-[9px] border border-solid border-rule bg-vellum-raise px-4 py-[9px] text-center font-mono text-[12px] text-ink-dim shadow-[0_14px_40px_#0009]">{v.text}</div>
              );
            }
            if (v.kind === "picks") {
              return (
                <div class={`${CHIP} lsp-picks min-w-[280px] px-0 py-[5px]`} style={place(v.at)}>
                  <For each={v.locs}>
                    {(l, i) => (
                      <button
                        class="flex w-full cursor-pointer items-baseline gap-[8px] px-[11px] py-[3px] text-left"
                        classList={{ "bg-gold-wash text-gold-leaf": i() === v.sel }}
                        onClick={() => jump(l)}
                      >
                        <span class="w-[10px] text-ink-faint">{i() + 1}</span>
                        <span class="truncate"><span class="text-ink-faint">{dirOf(l.path)}</span><b class="font-semibold text-ink">{leafOf(l.path)}</b>:{l.line}</span>
                      </button>
                    )}
                  </For>
                  <div class="px-[11px] pt-[4px] text-[10px] text-ink-faint">↵ go · j/k · esc</div>
                </div>
              );
            }
            return (
              <div
                class="lsp-pop lsp-hover absolute z-[240] max-h-[46vh] w-max max-w-[min(620px,calc(100vw-24px))] overflow-auto rounded-[9px] border border-solid border-rule border-l-2 border-l-gold-deep bg-[#1b1815] px-[14px] py-[9px] text-[13px] leading-[1.5] text-ink shadow-[0_14px_40px_#0009]"
                style={place(v.at)}
                // innerHTML: tsgo's markdown for this repo's own code — local, and hljs escapes code bodies
                innerHTML={renderMarkdown(v.md)}
              />
            );
          }}
        </Show>
      </Portal>
    </>
  );

  return { Layer };
}
