// A branch's history as it'll be pushed, editable where it can be: every commit's sha, author,
// date and pushed/local; an unpushed one's subject and body are fields with v1's live hints and
// their one-click fixes (scope, length, bare follow-ups, a baked forest plan). Edits are drafts
// until one save (words.save, ⌘↵ in a field) rewrites them all; u undoes it. Pushed commits are
// read-only, with the reason.
import { createResource, For, Show } from "solid-js";
import { SUBJECT_LIMIT, type Hint } from "../outlineHints";
import { atRepo } from "./model";
import { keyOf } from "./registry";
import { bind, dispatch } from "./runner";
import { view } from "./store";
import { getJSON } from "./sync";
import { changed, drafts, editTo, hintsOf, shown, valueOf, type Commit, type Outline } from "./words";

const TONE: Record<Hint["tone"], string> = { error: "border-ember text-ember", warn: "border-gold-deep text-gold-leaf", note: "border-rule text-ink-faint" };

export default function Commits(props: { branchId: string }) {
  const b = () => view("branch", props.branchId);
  const [o] = createResource(
    () => (b() ? `${b()!.repo}|${b()!.name}|${b()!.tip}` : null),
    async () => {
      const got = await getJSON<Outline>(atRepo(b()!.repo, `/outline?branch=${encodeURIComponent(b()!.name)}`)).catch(() => null);
      if (got) shown.set(props.branchId, got);
      return got;
    },
  );
  const mine = () => drafts().get(props.branchId);
  const value = (c: Commit) => valueOf(props.branchId, c);
  const edit = (c: Commit, w: { subject: string; body: string }) => editTo(props.branchId, c, w);
  const pending = () => (o() ? changed(props.branchId).length : 0);
  const orphans = () => [...(mine()?.keys() ?? [])].filter((sha) => o() && !o()!.commits.some((c) => c.sha === sha)).length;
  const saveKey = (e: KeyboardEvent) => {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      dispatch("words.save", "key", { target: props.branchId, event: e });
    }
  };

  return (
    <Show when={o()} fallback={<p class="m-0 text-ink-faint">{o.loading ? "reading the commits…" : "couldn't read the commits"}</p>}>
      <Show when={orphans()}>
        <p class="m-0 mb-2 text-[12px] text-ink-faint">
          {orphans()} edit{orphans() === 1 ? " was" : "s were"} on commits that no longer exist — the branch moved; they won't be saved
        </p>
      </Show>
      <Show when={o()!.commits.length} fallback={<p class="m-0 text-ink-faint">no commits of its own</p>}>
        <ol class="m-0 list-none p-0">
          <For each={o()!.commits}>
            {(c) => {
              const w = () => value(c);
              const hints = () => (drafts(), hintsOf(props.branchId, c));
              return (
                <li class="mb-4">
                  <div class="flex items-baseline gap-2 text-[11px] text-ink-faint">
                    <code class={c.pushed ? "text-ink-faint" : "text-gold-leaf"}>{c.short.slice(0, 7)}</code>
                    <span>
                      {c.author} · {c.date} · {c.pushed ? "pushed" : "local"}
                    </span>
                    <Show when={mine()?.has(c.sha) && changed(props.branchId).some((x) => x.sha === c.sha)}>
                      <span class="text-gold-leaf">· edited</span>
                    </Show>
                  </div>
                  <Show
                    when={!c.locked}
                    fallback={
                      <>
                        <div class="mt-0.5 text-ink">{c.subject}</div>
                        <Show when={c.body}>
                          <pre class="m-0 mt-1 whitespace-pre-wrap font-mono text-[12px] text-ink-dim">{c.body}</pre>
                        </Show>
                        <p class="m-0 mt-1 text-[11px] text-ink-faint">read-only: {c.locked}</p>
                      </>
                    }
                  >
                    <div class="relative mt-1">
                      <input
                        class="w-full border border-rule bg-vellum-night px-2 py-1 font-mono text-[12.5px] text-ink focus:border-gold-deep focus:outline-none"
                        value={w().subject}
                        onInput={(e) => edit(c, { ...w(), subject: e.currentTarget.value })}
                        onKeyDown={saveKey}
                        aria-label={`subject of ${c.short.slice(0, 7)}`}
                      />
                      <span class="pointer-events-none absolute right-2 top-1.5 text-[10px]" classList={{ "text-ember": w().subject.trim().length > SUBJECT_LIMIT, "text-ink-faint": w().subject.trim().length <= SUBJECT_LIMIT }}>
                        {w().subject.trim().length}
                      </span>
                    </div>
                    <textarea
                      class="mt-1 w-full resize-y border border-rule bg-vellum-night px-2 py-1 font-mono text-[12px] text-ink-dim focus:border-gold-deep focus:outline-none"
                      rows={Math.min(14, Math.max(2, w().body.split("\n").length + 1))}
                      value={w().body}
                      placeholder="why, in a line (optional)"
                      onInput={(e) => edit(c, { ...w(), body: e.currentTarget.value })}
                      onKeyDown={saveKey}
                      aria-label={`body of ${c.short.slice(0, 7)}`}
                    />
                    <Show when={hints().length}>
                      <div class="mt-1 flex flex-wrap gap-1.5">
                        <For each={hints()}>
                          {(h) => (
                            <span class={`inline-flex items-baseline gap-1.5 border border-dashed px-1.5 text-[10.5px] ${TONE[h.tone]}`}>
                              {h.text}
                              <Show when={h.fix}>
                                <button class="rv-quietbtn" onClick={bind("words.fix", `${props.branchId} ${c.sha} ${h.id}`)}>
                                  {h.fix!.label}
                                </button>
                              </Show>
                            </span>
                          )}
                        </For>
                      </div>
                    </Show>
                  </Show>
                </li>
              );
            }}
          </For>
        </ol>
      </Show>
      <Show when={pending()}>
        <div class="sticky bottom-0 flex items-center gap-3 border-t border-rule bg-vellum-raise py-2">
          <button class="rv-btn rv-btn-gold" onClick={bind("words.save", props.branchId)}>
            Save {pending()} message{pending() === 1 ? "" : "s"} <kbd>⌘↵</kbd>
          </button>
          <span class="text-[11px] text-ink-faint">rewrites the unpushed commits in place · {keyOf("undo")} undoes</span>
        </div>
      </Show>
    </Show>
  );
}
