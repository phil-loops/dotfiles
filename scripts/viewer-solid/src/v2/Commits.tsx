// A branch's words, read first and edited in place: what it lands as (title + why, the repo
// template folded away), then its commits one line each — a body opens when you click into its
// commit. Every hint sits in one line on top, once, with its one-click fix. Edits are drafts
// until one save (words.save, ⌘↵ in a field) rewrites them all; u undoes it. Pushed commits are
// read-only, with the reason.
import { createEffect, createResource, createSignal, For, on, onCleanup, Show, type JSX } from "solid-js";
import { oneLine } from "./commands/branch";
import { joinTemplate, splitTemplate, SUBJECT_LIMIT, type Hint } from "./outlineHints";
import { atRepo } from "./model";
import { keyOf } from "./registry";
import { bind, dispatch } from "./runner";
import { list, view } from "./store";
import { getJSON } from "./sync";
import { changed, drafts, editPr, editTo, githubOwns, hintsOf, PR, prChange, prHints, prValue, shown, valueOf, type Commit, type Outline } from "./words";

/** Copies text for a PR form filled by hand, outside the viewer's push door. */
function CopyButton(props: { label: string; text: () => string }) {
  const [done, setDone] = createSignal(false);
  let timer: ReturnType<typeof setTimeout> | undefined;
  onCleanup(() => clearTimeout(timer));
  const copy = async () => {
    await navigator.clipboard.writeText(props.text());
    setDone(true);
    clearTimeout(timer);
    timer = setTimeout(() => setDone(false), 1500);
  };
  return (
    <button type="button" class="text-ink-faint hover:text-ink" onClick={copy}>
      {done() ? "copied" : props.label}
    </button>
  );
}

const TONE: Record<Hint["tone"], string> = { error: "border-ember text-ember", warn: "border-gold-deep text-gold-leaf", note: "border-rule text-ink-faint" };

/** A branch's /outline, read again when its tip moves (and while the server drafts the PR body). */
export function useOutline(branchId: () => string) {
  const b = () => view("branch", branchId());
  const [o, { refetch }] = createResource(
    () => (b() ? `${b()!.repo}|${b()!.name}|${b()!.tip}` : null),
    async () => {
      const got = await getJSON<Outline>(atRepo(b()!.repo, `/outline?branch=${encodeURIComponent(b()!.name)}`)).catch(() => null);
      if (got) shown.set(branchId(), got);
      return got;
    },
  );
  createEffect(() => {
    if (!o()?.draft?.bodyPending) return;
    const t = window.setTimeout(() => void refetch(), 1500);
    onCleanup(() => clearTimeout(t));
  });
  return o;
}

const saveKey_ = (branchId: string) => (e: KeyboardEvent) => {
  if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
    e.preventDefault();
    dispatch("words.save", "key", { target: branchId, event: e });
  }
};

function SaveBar(props: { branchId: string; pending: number }) {
  return (
    <Show when={props.pending}>
      <div class="sticky bottom-0 flex items-center gap-3 border-t border-rule bg-vellum-raise py-2">
        <button class="rv-btn rv-btn-gold" onClick={bind("words.save", props.branchId)}>
          save {props.pending} <kbd>⌘↵</kbd>
        </button>
        <span class="text-[11px] text-ink-faint">{keyOf("undo")} undoes</span>
      </div>
    </Show>
  );
}

/** One commit's message, edited where it's read (the commits tab): the same drafts and save as the
 *  words, so an edit made in either shows in both. A pushed commit reads, with the reason. */
export function CommitWords(props: { branchId: string; sha: string; fallback: JSX.Element }) {
  const o = useOutline(() => props.branchId);
  const c = () => o()?.commits.find((x) => x.sha.startsWith(props.sha));
  const w = () => (drafts(), valueOf(props.branchId, c()!));
  const edit = (x: { subject: string; body: string }) => editTo(props.branchId, c()!, x);
  const issues = () => (drafts(), hintsOf(props.branchId, c()!));
  const key = saveKey_(props.branchId);
  return (
    <Show when={c() && !c()!.locked} fallback={props.fallback}>
      <textarea
        class={`${FIELD} block resize-none text-[12.5px] text-ink [field-sizing:content]`}
        rows={1}
        value={w().subject}
        onInput={(e) => edit({ ...w(), subject: e.currentTarget.value.replace(/\n/g, " ") })}
        onKeyDown={(e) => {
          if (e.key === "Enter" && !e.metaKey && !e.ctrlKey) e.preventDefault();
          key(e);
        }}
        aria-label="commit subject"
      />
      <textarea
        class={`${FIELD} block resize-none text-[12px] text-ink-dim placeholder:text-ink-faint [field-sizing:content]`}
        rows={1}
        value={w().body}
        placeholder="why"
        onInput={(e) => edit({ ...w(), body: e.currentTarget.value })}
        onKeyDown={key}
        aria-label="commit body"
      />
      <Show when={issues().length}>
        <div class="mt-1 flex flex-wrap gap-x-3 px-2 text-[11px]">
          <For each={issues()}>
            {(h) => (
              <span class={TONE[h.tone]}>
                {short(h)}
                <Show when={h.fix}>
                  {" "}
                  <button class="rv-quietbtn" onClick={bind("words.fix", `${props.branchId} ${c()!.sha} ${h.id}`)}>
                    {h.fix!.label}
                  </button>
                </Show>
              </span>
            )}
          </For>
        </div>
      </Show>
      <SaveBar branchId={props.branchId} pending={(drafts(), changed(props.branchId).length + (prChange(props.branchId) ? 1 : 0))} />
    </Show>
  );
}

export default function Commits(props: { branchId: string; readOnly?: boolean; landing?: boolean; landingOnly?: boolean }) {
  const b = () => view("branch", props.branchId);
  const o = useOutline(() => props.branchId);
  /** thread URL → "author on file:line", for the commits whose Addresses: trailers name one */
  const threadsByUrl = () => {
    const out = new Map<string, string>();
    for (const t of list("thread")) {
      if (t.repo === b()?.repo && t.branch === b()?.name && t.comments[0]?.url) {
        out.set(t.comments[0].url, `${t.comments[0].author} on ${t.path.split("/").pop()}:${t.local?.line ?? t.line ?? "?"}`);
      }
    }
    return out;
  };
  const addresses = (body: string) =>
    [...body.matchAll(/^Addresses:\s*(\S+)\s*$/gm)].map((m) => threadsByUrl().get(m[1]) ?? m[1].replace(/^https:\/\/github\.com\//, ""));
  const mine = () => drafts().get(props.branchId);
  const value = (c: Commit) => valueOf(props.branchId, c);
  const edit = (c: Commit, w: { subject: string; body: string }) => editTo(props.branchId, c, w);
  const pending = () => (o() ? changed(props.branchId).length + (prChange(props.branchId) ? 1 : 0) : 0);
  const pr = () => (o(), drafts(), prValue(props.branchId));
  /** every hint on the branch's words, once each: the title's, then each commit's — an opening
   *  commit that is the title says nothing the title didn't */
  const issues = () => {
    drafts();
    const out: { where: string; key: string; h: Hint }[] = [];
    for (const h of props.landing ? prHints(props.branchId) : []) out.push({ where: h.id === "plan" || h.id === "prose" ? "body" : "title", key: PR, h });
    if (props.landingOnly || props.readOnly) return out;
    for (const c of o()?.commits ?? []) {
      const sameAsTitle = props.landing && value(c).subject.trim() === pr().subject.trim();
      for (const h of hintsOf(props.branchId, c)) {
        if (!(sameAsTitle && TITLE_HINTS.has(h.id))) out.push({ where: c.short.slice(0, 7), key: c.sha, h });
      }
    }
    return out;
  };
  const orphans = () => [...(mine()?.keys() ?? [])].filter((sha) => o() && !o()!.commits.some((c) => c.sha === sha)).length;
  const saveKey = (e: KeyboardEvent) => saveKey_(props.branchId)(e);

  const prParts = () => splitTemplate(pr().body);
  const editOwn = (own: string) => editPr(props.branchId, { ...pr(), body: joinTemplate(own, prParts().template) });

  return (
    <Show when={o()} fallback={<p class="m-0 text-ink-faint">{o.loading ? "reading the commits…" : "couldn't read the commits"}</p>}>
      <Show when={orphans()}>
        <p class="m-0 mb-2 text-[12px] text-ink-faint">
          {orphans()} edit{orphans() === 1 ? "" : "s"} dropped · branch moved
        </p>
      </Show>
      <Show when={props.landing}>
        <div class="mb-4">
          <div class="rv-words-k">description</div>
          <DescriptionField branchId={props.branchId} />
        </div>
        <div class="mb-4">
          <div class="rv-words-k">lands as</div>
          <Show
            when={!githubOwns(o()!.pr)}
            fallback={
              <>
                <div class="px-2 text-ink">{o()!.pr!.title ?? "—"}</div>
                <Show when={splitTemplate(o()!.pr!.body ?? "").own}>
                  <p class="m-0 mt-1 whitespace-pre-wrap px-2 text-[12px] text-ink-dim">{splitTemplate(o()!.pr!.body ?? "").own}</p>
                </Show>
                <p class="m-0 mt-1 px-2 text-[11px] text-ink-faint">#{o()!.pr!.number} is {o()!.pr!.state === "MERGED" ? "merged" : "open"} — GitHub owns its words</p>
              </>
            }
          >
            <textarea
              class={`${FIELD} block resize-none text-[12.5px] text-ink [field-sizing:content]`}
              rows={1}
              value={pr().subject}
              onInput={(e) => editPr(props.branchId, { ...pr(), subject: e.currentTarget.value.replace(/\n/g, " ") })}
              onKeyDown={(e) => {
                if (e.key === "Enter" && !e.metaKey && !e.ctrlKey) e.preventDefault();
                saveKey(e);
              }}
              aria-label="PR title"
            />
            <textarea
              class={`${FIELD} block resize-none text-[12px] text-ink-dim placeholder:text-ink-faint [field-sizing:content]`}
              rows={1}
              value={prParts().own}
              placeholder="why — a line or three"
              onInput={(e) => editOwn(e.currentTarget.value)}
              onKeyDown={saveKey}
              aria-label="PR body"
            />
            <Show when={prParts().template}>
              <div class="px-2 text-[11px] text-ink-faint">＋ the repo's PR template</div>
            </Show>
            <div class="mt-1 flex gap-3 px-2 text-[11px]">
              <CopyButton label="copy title" text={() => pr().subject} />
              <CopyButton label="copy body" text={() => pr().body} />
            </div>
          </Show>
        </div>
      </Show>
      <Show when={!props.readOnly && issues().length}>
        <div class="mb-3 mt-1 flex flex-wrap gap-x-3 gap-y-0.5 text-[11px]">
          <For each={issues()}>
            {(x) => (
              <span class={TONE[x.h.tone]}>
                <span class="text-ink-faint">{x.where}</span> {short(x.h)}
                <Show when={x.h.fix}>
                  {" "}
                  <button class="rv-quietbtn" onClick={bind("words.fix", `${props.branchId} ${x.key} ${x.h.id}`)}>
                    {x.h.fix!.label}
                  </button>
                </Show>
              </span>
            )}
          </For>
        </div>
      </Show>
      <Show when={!props.landingOnly}>
        <Show when={props.landing}>
          <div class="rv-words-k">commits</div>
        </Show>
        <Show when={o()!.commits.length} fallback={<p class="m-0 text-ink-faint">no commits</p>}>
          <ol class="m-0 list-none p-0">
            <For each={o()!.commits}>
              {(c) => {
                const w = () => value(c);
                const editable = () => !c.locked && !props.readOnly;
                const edited = () => !!mine()?.has(c.sha) && changed(props.branchId).some((x) => x.sha === c.sha);
                return (
                  <li class="group">
                    <For each={addresses(w().body)}>{(a) => <div class="pl-16 text-[11px] text-gold-leaf">addresses {a}</div>}</For>
                    <div class="flex items-baseline gap-2">
                      <code class="shrink-0 text-[11px]" classList={{ "text-ink-faint": c.pushed, "text-gold-leaf": !c.pushed }} title={`${c.date} · ${c.pushed ? "pushed" : "local"}${c.locked ? ` · ${c.locked}` : ""}`}>
                        {c.short.slice(0, 7)}
                      </code>
                      <Show when={editable()} fallback={<span class="min-w-0 flex-1 truncate px-2 py-0.5 text-ink-dim">{c.subject}</span>}>
                        <input
                          class={`${FIELD} min-w-0 flex-1 py-0.5 text-[12.5px] text-ink-dim focus:text-ink`}
                          value={w().subject}
                          onInput={(e) => edit(c, { ...w(), subject: e.currentTarget.value })}
                          onKeyDown={saveKey}
                          aria-label={`subject of ${c.short.slice(0, 7)}`}
                        />
                      </Show>
                      <Show when={edited()}>
                        <span class="text-[10.5px] text-gold-leaf">edited</span>
                      </Show>
                      <Show when={w().body.trim()}>
                        <span class="text-[10.5px] text-ink-faint group-focus-within:hidden" title="has a body — click the subject to see it">¶</span>
                      </Show>
                    </div>
                    <Show when={editable()}>
                      <textarea
                        class={`${FIELD} mb-2 ml-14 !w-[calc(100%-3.5rem)] hidden resize-y text-[12px] text-ink-dim group-focus-within:block`}
                        rows={Math.min(14, Math.max(2, w().body.split("\n").length + 1))}
                        value={w().body}
                        placeholder="why"
                        onInput={(e) => edit(c, { ...w(), body: e.currentTarget.value })}
                        onKeyDown={saveKey}
                        aria-label={`body of ${c.short.slice(0, 7)}`}
                      />
                    </Show>
                  </li>
                );
              }}
            </For>
          </ol>
        </Show>
      </Show>
      <Show when={!props.readOnly}>
        <SaveBar branchId={props.branchId} pending={pending()} />
      </Show>
    </Show>
  );
}

/** The branch's description, edited where it's read: ↵ or leaving the field saves it (u undoes),
 *  esc puts it back. Its length shows, and an "and" — the split-point test — warns, never blocks. */
export function DescriptionField(props: { branchId: string; inline?: boolean; onDone?: () => void }) {
  const saved = () => view("branch", props.branchId)?.description ?? "";
  const [text, setText] = createSignal(saved());
  createEffect(on(saved, (s) => setText(s), { defer: true }));
  const save = (e: Event) => {
    if (oneLine(text()) !== saved()) dispatch("branch.describe", e instanceof KeyboardEvent ? "key" : "click", { target: props.branchId, arg: text(), event: e });
    props.onDone?.();
  };
  const split = () => / and /i.test(text());
  return (
    <div>
      <input
        ref={(el) => props.inline && queueMicrotask(() => el.focus())}
        class={`${FIELD} text-[12.5px] text-ink`}
        value={text()}
        placeholder="one verb-first line"
        onInput={(e) => setText(e.currentTarget.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") {
            e.preventDefault();
            save(e);
          } else if (e.key === "Escape") {
            setText(saved());
            e.currentTarget.value = saved();
          }
        }}
        onBlur={save}
        aria-label="branch description"
      />
      <div class="flex gap-3 px-2 text-[11px] text-ink-faint">
        <span>{oneLine(text()).length}</span>
        <Show when={split()}>
          <span class="text-gold-leaf" title="every “and” joining two behaviors is a split point — another branch">“and” · a split point?</span>
        </Show>
      </div>
    </div>
  );
}

const FIELD = "w-full border border-transparent bg-transparent px-2 py-1 font-mono hover:border-rule focus:border-gold-deep focus:bg-vellum-night focus:outline-none";

/** hints the PR title already carries when the opening commit's subject is the title */
const TITLE_HINTS = new Set(["empty", "wip", "long", "scope", "type"]);

/** A hint as the issues line says it: a few words, the fix button doing the rest. */
function short(h: Hint): string {
  const n = /^(\d+) chars/.exec(h.text)?.[1];
  const words: Record<string, string> = {
    long: `long (${n}/${SUBJECT_LIMIT})`,
    plan: "forest block",
    wip: "placeholder",
    empty: "empty",
    scope: "scope",
    type: "no type:",
    bare: "prefix on a follow-up",
    prose: "long body",
  };
  return words[h.id] ?? h.text;
}
