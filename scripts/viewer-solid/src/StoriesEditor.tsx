import { createSignal, createResource, For, Show } from "solid-js";
import { withRepo, canMutate } from "./provider";

// The forest as a plain-English story, one line per branch in merge order, every line editable at
// once. The plan is fetched through any one branch of the forest — the view has no "this branch". Each line is the branch's `job` — what it DOES, in a sentence a teammate reads without the
// diff — and saving writes that branch's own `stack-branch.<b>.story`, so the wording renders on
// every branch's plan block and outlives the branch you happened to edit from.
//
// job_of ranks story > description > subject. The badge names which one is showing, and a story
// that overrides a description shows the description underneath — an override is never silent here.
type Step = {
  n: number; branch: string; job: string; story: string; description: string; subject: string;
  pr: number | null; landed: boolean;
};
type Source = "story" | "description" | "subject" | "merged";

const sourceOf = (s: Step): Source => (s.landed ? "merged" : s.story ? "story" : s.description ? "description" : "subject");
const leafOf = (b: string): string => b.split("/").pop() || b;

const BADGE: Record<Source, string> = {
  story: "text-gold-leaf border-gold-deep",
  description: "text-patina border-patina/60",
  subject: "text-ink-faint border-rule",
  merged: "text-ink-faint border-transparent",
};
const BADGE_TITLE: Record<Source, string> = {
  story: "a hand-written story — beats the description and the commit subject",
  description: "the branch description (git config branch.<b>.description) — no story override set",
  subject: "auto-derived from the newest commit's subject — no description, no story",
  merged: "already merged — its line is its PR title, from the merge ledger",
};

const postStory = (branch: string, text: string) =>
  fetch(withRepo("/story"), {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ branch, text }),
  });

export function StoriesEditor(props: { project: string; branch: string; onPick: (branch: string) => void }) {
  const [data, { refetch }] = createResource(
    () => props.branch,
    (b) => fetch(withRepo("/plan-steps") + "?branch=" + encodeURIComponent(b))
      .then((r) => r.json() as Promise<{ steps: Step[] }>),
  );
  const [drafts, setDrafts] = createSignal<Record<string, string>>({});
  const [saving, setSaving] = createSignal<Record<string, "saving" | "saved" | "failed">>({});
  const areas: Record<string, HTMLTextAreaElement | undefined> = {};

  const draftOf = (s: Step): string => drafts()[s.branch] ?? s.job;
  const dirty = (s: Step): boolean => draftOf(s).trim() !== s.job.trim();
  const mark = (branch: string, v: "saving" | "saved" | "failed" | null) =>
    setSaving((m) => {
      const next = { ...m };
      if (v) next[branch] = v; else delete next[branch];
      return next;
    });

  // Typing the description back verbatim clears the override rather than storing a copy of it —
  // the description stays the single source, and the badge flips back to "description".
  const save = async (s: Step, text: string) => {
    const t = text.trim();
    const stored = t === s.description.trim() ? "" : t;
    if (stored === s.story.trim()) {
      setDrafts((d) => { const n = { ...d }; delete n[s.branch]; return n; });
      return;
    }
    mark(s.branch, "saving");
    const r = await postStory(s.branch, stored);
    if (!r.ok) {
      mark(s.branch, "failed");
      return;
    }
    await refetch();
    setDrafts((d) => { const n = { ...d }; delete n[s.branch]; return n; });
    mark(s.branch, "saved");
    setTimeout(() => mark(s.branch, null), 1800);
  };
  const revert = (s: Step) => setDrafts((d) => { const n = { ...d }; delete n[s.branch]; return n; });
  const focusNext = (from: Step) => {
    const list = (data()?.steps ?? []).filter((x) => !x.landed);
    const i = list.findIndex((x) => x.branch === from.branch);
    const next = list[i + 1];
    if (next) areas[next.branch]?.focus();
  };

  return (
    <div class="stories mx-auto my-0 max-w-[900px] pt-[8px] px-[16px] pb-[40px] font-mono">
      <div class="stories-head flex items-baseline gap-[12px] pt-[6px] px-[2px] pb-[4px]">
        <span class="stories-flow text-[14px] text-ink">{props.project} → main</span>
        <span class="stories-cap text-[11px] uppercase tracking-[0.08em] text-ink-faint">stories · in merge order</span>
      </div>
      <p class="stories-hint mt-0 mx-[2px] mb-[14px] text-[11px] leading-[1.5] text-ink-dim">
        one line per branch: what it does, as a sentence a teammate reads without the diff. ↵ or leaving the line saves it to that branch; ⇥ moves on; esc reverts.
      </p>
      <Show when={data()} fallback={<p class="stories-empty italic text-ink-faint">loading…</p>}>
        <ol class="stories-list m-0 flex list-none flex-col gap-[3px] p-0">
          <For each={data()!.steps}>
            {(s) => {
              const src = () => sourceOf(s);
              const state = () => saving()[s.branch];
              const shadowed = () => (src() === "story" && s.description ? s.description : "");
              return (
                <li class={`stories-row flex flex-col gap-[3px] rounded-[8px] border border-transparent py-[6px] px-[10px] focus-within:border-rule focus-within:bg-vellum-raise ${s.landed ? "landed opacity-50" : ""}`}>
                  <div class="flex items-start gap-[10px]">
                    <span class="stories-n min-w-[18px] flex-none pt-[4px] text-right text-[11px] text-gold-leaf">{s.n}</span>
                    <Show
                      when={!s.landed && canMutate}
                      fallback={<span class="stories-line min-w-0 flex-1 px-[7px] py-[3px] text-[12.5px] leading-[1.55] text-ink-dim">{s.job}</span>}
                    >
                      <textarea
                        ref={(el) => { areas[s.branch] = el; }}
                        class={`stories-input min-w-0 flex-1 resize-none rounded-[5px] border bg-transparent px-[7px] py-[3px] text-[12.5px] leading-[1.55] outline-none ${dirty(s) ? "border-gold-deep text-ink" : "border-transparent text-ink-dim focus:border-gold-deep focus:text-ink hover:border-rule"}`}
                        style={{ "field-sizing": "content" }}
                        rows={1}
                        spellcheck={true}
                        value={draftOf(s)}
                        disabled={state() === "saving"}
                        onInput={(e) => setDrafts((d) => ({ ...d, [s.branch]: e.currentTarget.value }))}
                        onBlur={() => { if (dirty(s)) void save(s, draftOf(s)); }}
                        onKeyDown={(e) => {
                          if (e.key === "Enter" && !e.shiftKey) {
                            e.preventDefault();
                            if (dirty(s)) void save(s, draftOf(s));
                            focusNext(s);
                          } else if (e.key === "Escape") {
                            revert(s);
                            e.currentTarget.blur();
                          }
                        }}
                      />
                    </Show>
                    <span class="stories-tail flex flex-none items-baseline gap-[8px] pt-[4px]">
                      <Show when={state()}>
                        <span class={`text-[10px] ${state() === "failed" ? "text-del" : "text-patina"}`}>{state() === "saving" ? "saving…" : state() === "saved" ? "saved ✓" : "couldn’t save"}</span>
                      </Show>
                      <span class={`stories-src rounded-[4px] border px-[5px] text-[9.5px] uppercase tracking-[0.06em] ${BADGE[src()]}`} title={BADGE_TITLE[src()]}>
                        {src() === "merged" && s.pr ? `merged #${s.pr}` : src()}
                      </span>
                      <button
                        class="stories-branch cursor-pointer border-0 bg-transparent p-0 text-[10.5px] text-ink-faint hover:text-ink"
                        title={`open ${s.branch}`}
                        onClick={() => props.onPick(s.branch)}
                      >{leafOf(s.branch)}</button>
                    </span>
                  </div>
                  <Show when={shadowed()}>
                    <div class="stories-under flex items-baseline gap-[8px] pl-[35px] text-[10.5px] leading-[1.5] text-ink-faint">
                      <span class="min-w-0 flex-1 overflow-hidden text-ellipsis whitespace-nowrap" title={shadowed()}>
                        <span class="text-patina">description</span> {shadowed()}
                      </span>
                      <Show when={canMutate}>
                        <button
                          class="flex-none cursor-pointer border-0 bg-transparent p-0 text-[10.5px] text-ink-faint underline decoration-dotted hover:text-ink"
                          title="drop the story override — the description shows again"
                          onClick={() => void save(s, s.description)}
                        >use description</button>
                      </Show>
                    </div>
                  </Show>
                </li>
              );
            }}
          </For>
        </ol>
      </Show>
    </div>
  );
}
