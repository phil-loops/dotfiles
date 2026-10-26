// A conversation at its line (folded like GitHub's when resolved or outdated), the second reader's
// note under it, a draft from the ledger (a comment or a reply not on GitHub yet), and the comment box.
import { createMemo, For, onMount, Show } from "solid-js";
import { keyOf } from "../registry";
import { bind, dispatch } from "../runner";
import { list, view } from "../store";
import type { Comment, Item, Thread } from "../types";
import { now } from "../ui";
import { renderMarkdown, plain } from "./markdown";
import { page as pg, rowsOf, short } from "./page";

export function ago(at: string): string {
  const s = Math.max(0, (now() - Date.parse(at)) / 1000);
  if (!Number.isFinite(s)) return "";
  if (s < 90) return "just now";
  if (s < 5400) return `${Math.round(s / 60)}m ago`;
  if (s < 129600) return `${Math.round(s / 3600)}h ago`;
  return `${Math.round(s / 86400)}d ago`;
}

/** The lines a thread sits on at the local tip, as the diff shows them — what a suggestion replaces. */
function linesOf(t: Thread): string[] {
  // once a local commit changed them, the tip's lines aren't what the suggestion replaced
  if (!t.local || t.local.addressedBy) return [];
  const f = pg.files().find((x) => x.path === t.path);
  if (!f) return [];
  const from = t.local.startLine ?? t.local.line;
  return rowsOf(f, false)
    .filter((r) => r.right && r.right.new! >= from && r.right.new! <= t.local!.line)
    .map((r) => r.right!.text);
}

const VERDICT: Record<string, string> = { right: "right", wrong: "worth questioning", partly: "partly right", unclear: "unclear" };

export function ThreadView(props: { id: string; selected: (k: string | undefined) => boolean; aside?: boolean }) {
  const t = () => view("thread", props.id) as Thread;
  const key = `t|${props.id}`;
  const open = () => pg.isOpen(t());
  const first = () => t().comments[0];
  const replies = createMemo(() => pg.repliesTo(props.id));
  const replying = () => {
    const c = pg.composer();
    return c?.kind === "reply" && c.threadId === props.id;
  };
  const by = () => t().local?.addressedBy;
  const where = () => (t().local ? `${t().path}:${t().local!.startLine ? `${t().local!.startLine}–` : ""}${t().local!.line}` : `${t().path}:${t().originalLine ?? "?"}`);
  return (
    <Show when={t()}>
      <div class="rv-thread" data-stop={key} classList={{ "rv-on": props.selected(key), "rv-thread-done": t().resolved || t().outdated }}>
        <div class="rv-th-head" onClick={bind("review.cursor.set", key)}>
          <button class="rv-fold" onClick={bind("review.fold", props.id)}>{open() ? "▾" : "▸"}</button>
          <Show when={!open()}>
            <span class="rv-author">{first()?.author}</span>
          </Show>
          <Show when={props.aside || t().outdated || t().local?.startLine}>
            <span class="rv-where">{where()}</span>
          </Show>
          <Show when={!open()}>
            <span class="rv-summary">{plain(first()?.body ?? "", 110)}</span>
          </Show>
          <Show when={t().comments.length > 1}>
            <span class="rv-chip">{t().comments.length - 1} repl{t().comments.length === 2 ? "y" : "ies"}</span>
          </Show>
          <Show when={t().resolved}>
            <span class="rv-chip rv-chip-ok">resolved</span>
          </Show>
          <Show when={t().outdated}>
            <span class="rv-chip">outdated</span>
          </Show>
          <Show when={t().fixedBy?.length}>
            <span class="rv-chip rv-chip-gold" title="a commit declares it addresses this thread (its Addresses: trailer)">
              fixed in {t().fixedBy.map((f) => f.short).join(", ")}
            </span>
          </Show>
          <Show when={by() && !t().outdated && !t().fixedBy?.length}>
            <span class="rv-chip rv-chip-gold" title="a local commit since the PR head changed these lines">
              changed in {by() ? short(by()!) : "a local commit"}?
            </span>
          </Show>
          <Show when={t().applying}>
            <span class="rv-chip rv-chip-gold">applying…</span>
          </Show>
          <Show when={t().note}>
            <span class={`rv-chip rv-verdict-${t().note!.verdict}`}>2nd: {VERDICT[t().note!.verdict]}</span>
          </Show>
          <span class="flex-1" />
          <Show when={props.selected(key)}>
            <span class="rv-hint">{hints(t())}</span>
          </Show>
        </div>
        <Show when={open()}>
          <Show when={t().outdated && first()?.hunk}>
            <pre class="rv-oldhunk">{first()!.hunk!.split("\n").slice(-4).join("\n")}</pre>
          </Show>
          <For each={t().comments}>{(c) => <CommentView c={c} replaces={linesOf(t())} />}</For>
          <For each={replies()}>{(r) => <PendingView item={r} selected={props.selected} />}</For>
          <Show when={replying()}>
            <ComposerView />
          </Show>
          <Show when={t().note}>
            <NoteView t={t()} />
          </Show>
        </Show>
      </div>
    </Show>
  );
}

function hints(t: Thread): string {
  const k = keyOf;
  const out = [`${k("review.fold")} fold`, `${k("review.reply")} reply`];
  if (!t.outdated && !t.resolved) out.push(`${k("review.address")} address`);
  if (!t.outdated && !t.local?.addressedBy && t.comments.some((c) => c.body.includes("```suggestion"))) out.push(`${k("review.apply")} apply`);
  if (t.note?.draftReply) out.push(`${k("review.note.insert")} draft`);
  return out.join(" · ");
}

function CommentView(props: { c: Comment; replaces: string[] }) {
  const reactions = () => Object.entries(props.c.reactions ?? {});
  return (
    <div class="rv-comment">
      <div class="rv-c-head">
        <span class="rv-author">{props.c.author}</span>
        <span class="text-ink-faint">{ago(props.c.at)}</span>
        <Show when={props.c.state === "PENDING"}>
          <span class="rv-chip rv-chip-gold" title="in your pending review — only you see it until you submit on GitHub">pending</span>
        </Show>
      </div>
      <div class="md" innerHTML={renderMarkdown(props.c.body, { replaces: props.replaces })} />
      <Show when={reactions().length}>
        <div class="rv-reactions">
          <For each={reactions()}>{([k, n]) => <span>{EMOJI[k] ?? k} {n}</span>}</For>
        </div>
      </Show>
    </div>
  );
}

const EMOJI: Record<string, string> = { THUMBS_UP: "👍", THUMBS_DOWN: "👎", LAUGH: "😄", HOORAY: "🎉", CONFUSED: "😕", HEART: "❤️", ROCKET: "🚀", EYES: "👀" };

function NoteView(props: { t: Thread }) {
  const n = () => props.t.note!;
  const open = () => pg.unfold().get(`note:${props.t.id}`) ?? false;
  const places = () => n().elsewhere.length;
  return (
    <div class="rv-note">
      <button class="rv-note-line" onClick={bind("review.note.toggle", props.t.id)}>
        <span class="rv-note-mark">second reader</span>
        <span class={`rv-verdict-${n().verdict}`}>{VERDICT[n().verdict]}</span>
        <Show when={places()}>
          <span>· {places()} more like it</span>
        </Show>
        <span class="text-ink-faint">{open() ? "▾" : "▸"}</span>
      </button>
      <Show when={open()}>
        <div class="rv-note-body">
          <For each={n().evidence}>
            {(e) => (
              <div>
                <code>{e.path}:{e.line}</code> — {e.why}
              </div>
            )}
          </For>
          <Show when={places()}>
            <div class="rv-note-sub">elsewhere</div>
            <For each={n().elsewhere}>
              {(e) => (
                <div>
                  <code>{e.path}:{e.line}</code>
                  <Show when={e.branch}> on {e.branch}</Show> — {e.why}
                </div>
              )}
            </For>
          </Show>
          <Show when={n().cause}>
            <div class="rv-note-sub">cause</div>
            <div>{n().cause}</div>
          </Show>
          <Show when={n().draftReply}>
            <div class="rv-note-sub">draft reply</div>
            <div class="rv-note-draft">{n().draftReply}</div>
          </Show>
          <div class="text-ink-faint">— {n().model}</div>
        </div>
      </Show>
    </div>
  );
}

const SAYS: Record<Item["state"], string> = {
  draft: "draft · only here",
  waiting: "waits for a push",
  sending: "sending to your pending review…",
  pending: "pending",
  submitted: "submitted",
  gone: "not on GitHub any more",
};

/** A ledger item GitHub doesn't show yet: a draft, one waiting on a push, one being sent. */
export function PendingView(props: { item: Item; selected: (k: string | undefined) => boolean }) {
  const key = `p|${props.item.key}`;
  const it = () => props.item;
  const hint = () => {
    const out: string[] = [];
    if (it().state === "draft") out.push(`${keyOf("review.send")} sends to your pending review`);
    if (it().state !== "sending") out.push(`${keyOf("review.pending.remove")} deletes`);
    return out.join(" · ");
  };
  return (
    <div class="rv-thread rv-pending" data-stop={key} classList={{ "rv-on": props.selected(key), "rv-reply-draft": it().kind === "reply" }} onClick={bind("review.cursor.set", key)}>
      <div class="rv-th-head">
        <span class="rv-author">{pg.conv()?.viewer || "you"}</span>
        <span class="rv-chip rv-chip-gold">
          {it().waitingFix
            ? "waits for its fix"
            : it().state === "waiting"
              ? `waits for push`
              : SAYS[it().state]}
        </span>
        <Show when={it().kind === "comment" && it().startLine}>
          <span class="rv-where">lines {it().startLine}–{it().line}</span>
        </Show>
        <Show when={it().err}>
          <span class="text-ember">{it().err}</span>
        </Show>
        <span class="flex-1" />
        <Show when={props.selected(key)}>
          <span class="rv-hint">{hint()}</span>
        </Show>
      </div>
      <div class="rv-comment">
        <div class="md" innerHTML={renderMarkdown(withFix(it()))} />
      </div>
    </div>
  );
}

/** A reply's "{fix}" as the commit that declares its thread now, the sha it'll go out with. */
export function withFix(it: Item): string {
  if (!it.fixFor) return it.body;
  const t = (list("thread") as Thread[]).find((x) => x.comments[0]?.url === it.fixFor);
  return it.body.replace("{fix}", t?.fixedBy?.[0]?.short ?? "‹its fix›");
}

const unpushedIn = (body: string): string[] => {
  const un = pg.conv()?.unpushed ?? [];
  return [...new Set((body.match(/\b[0-9a-f]{7,40}\b/g) ?? []).flatMap((w) => un.filter((s) => s.startsWith(w))))];
};

export function ComposerView() {
  const c = () => pg.composer()!;
  let ta!: HTMLTextAreaElement;
  onMount(() => {
    ta.focus();
    ta.setSelectionRange(ta.value.length, ta.value.length);
  });
  const text = () => (pg.composer() ? pg.text(c().key) : "");
  const note = () => { const x = pg.composer(); return x?.kind === "line" ? x.sha : undefined; };
  const reviewing = () => (pg.conv()?.pending?.count ?? 0) > 0;
  const waits = createMemo(() => (c()?.kind === "reply" ? unpushedIn(text()) : []));
  const onKey = (e: KeyboardEvent) => {
    const mod = e.metaKey || e.ctrlKey;
    if (e.key === "Escape") {
      e.preventDefault();
      dispatch("review.compose.cancel", "key", { event: e });
    } else if (mod && e.key === "Enter") {
      e.preventDefault();
      dispatch(e.shiftKey ? "review.compose.draft" : "review.compose.send", "key", { event: e });
    } else if (e.ctrlKey && (e.key === "g" || e.key === "G")) {
      e.preventDefault();
      dispatch("review.compose.suggest", "key", { event: e });
    }
  };
  return (
    <Show when={pg.composer()}>
      <div class="rv-composer">
        <Show when={c().kind === "line"}>
          <div class="rv-c-head text-ink-faint">
            {(() => {
              const x = c();
              return x.kind === "line" ? `${x.side === "LEFT" ? "old " : ""}line${x.startLine ? `s ${x.startLine}–${x.line}` : ` ${x.line}`}` : "";
            })()}
          </div>
        </Show>
        <textarea
          ref={ta}
          class="rv-textarea"
          rows={Math.min(14, Math.max(3, text().split("\n").length + 1))}
          placeholder={c().kind === "reply" ? "Reply…" : note() ? `A note for Claude — it fixes ${note()!.slice(0, 7)}` : "Leave a comment"}
          value={text()}
          onInput={(e) => pg.setText(c().key, e.currentTarget.value)}
          onKeyDown={onKey}
        />
        <div class="rv-c-actions">
          <Show when={!note()}>
            <button class="rv-quietbtn" onClick={bind("review.compose.suggest")}>suggestion ^G</button>
          </Show>
          <Show when={waits().length}>
            <span class="text-gold-leaf">names {waits().map(short).join(", ")} — it stays a draft until that's on origin</span>
          </Show>
          <span class="flex-1" />
          <button class="rv-quietbtn" onClick={bind("review.compose.cancel")}>Cancel esc</button>
          <Show
            when={!note()}
            fallback={
              <button class="rv-btn rv-btn-gold" onClick={bind("review.compose.send")} title="opens a Claude session in the branch's worktree with the note typed in — you send it">
                Hand to Claude <kbd>⌘↵</kbd>
              </button>
            }
          >
            <button class="rv-btn" onClick={bind("review.compose.draft")}>Save draft <kbd>⌘⇧↵</kbd></button>
            <button class="rv-btn rv-btn-gold" onClick={bind("review.compose.send")} title="into your pending review on GitHub — private until you submit it there">
              {c().kind === "reply" ? "Reply in your review" : reviewing() ? "Add review comment" : "Start a review"} <kbd>⌘↵</kbd>
            </button>
          </Show>
        </div>
      </div>
    </Show>
  );
}
