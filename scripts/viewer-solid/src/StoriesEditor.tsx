import { createSignal, createResource, createEffect, For, Show } from "solid-js";
import { withRepo, canMutate } from "./provider";
import { patchHtml } from "./FileRail";

// The forest as a plain-English story, one line per branch in merge order, every line editable at
// once. The plan is fetched through any one branch of the forest — the view has no "this branch".
// Saving writes that branch's own `stack-branch.<b>.story`, so the wording renders on every
// branch's plan block and outlives the branch you happened to edit from.
//
// Every box starts BLANK — it holds the hand-written story and nothing else. The derived gloss
// (description, or the commit subject) is shown underneath as what the plan falls back to, not
// pre-filled as a draft: a story is your own read of the point, and a pre-filled line gets
// nudged instead of written. What to write it FROM is the row's own evidence — its commits AND
// its changed files with their real diffs, fetched on demand and opened when you start typing.
// File names alone were not enough to say what a branch does: you have to read the change.
type Step = {
  n: number; branch: string; job: string; story: string; description: string; subject: string;
  pr: number | null; landed: boolean;
};
type Source = "story" | "description" | "subject" | "merged";
type Evidence = { subjects: string[]; files: string[]; fileCount: number; adds: number; dels: number };
type Changed = { path: string; add: string; del: string; patch?: string };

// A well-forested node is small, so its whole diff is worth showing unasked — above this many
// changed lines the files stay folded and you open the ones you care about.
const READ_IT_ALL = 80;

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
  description: "no story yet — the plan falls back to the branch description (git config branch.<b>.description)",
  subject: "no story, no description — the plan falls back to the newest commit's subject",
  merged: "already merged — its line is its PR title, from the merge ledger",
};

const postStory = (branch: string, text: string): Promise<{ ok: boolean; prev: string }> =>
  fetch(withRepo("/story"), {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ branch, text }),
  }).then(async (r) => ({ ok: r.ok, prev: r.ok ? ((await r.json()) as { prev?: string }).prev ?? "" : "" }))
    .catch(() => ({ ok: false, prev: "" }));

const fetchEvidence = (branch: string): Promise<Evidence | null> =>
  fetch(withRepo("/step-evidence") + "?branch=" + encodeURIComponent(branch))
    .then((r) => r.json() as Promise<Evidence>)
    .catch(() => null);

// the same per-file payload the node page reviews from — path, counts, and the patch itself
const fetchChanged = (branch: string): Promise<Changed[]> =>
  fetch(withRepo("/node") + "?branch=" + encodeURIComponent(branch))
    .then((r) => r.json() as Promise<{ files?: Changed[] }>)
    .then((d) => d.files ?? [])
    .catch(() => []);

export function StoriesEditor(props: {
  project: string;
  branch: string;
  // the branch whose node you came from, marked "this branch" — the forest view has none
  here?: string;
  // the row to open on: focused, scrolled to, evidence already unfolded
  focus?: string;
  onPick: (branch: string) => void;
}) {
  const [data, { refetch }] = createResource(
    () => props.branch,
    (b) => fetch(withRepo("/plan-steps") + "?branch=" + encodeURIComponent(b))
      .then((r) => r.json() as Promise<{ steps: Step[] }>),
  );
  const [drafts, setDrafts] = createSignal<Record<string, string>>({});
  const [saving, setSaving] = createSignal<Record<string, "saving" | "saved" | "failed">>({});
  // the story this row just overwrote, offered back for a few seconds — a story is hand-written
  // prose and git config keeps no history, so a wrong save must be one click from undone
  const [undoable, setUndoable] = createSignal<Record<string, string>>({});
  const [shown, setShown] = createSignal<Record<string, boolean>>({});
  const [evidence, setEvidence] = createSignal<Record<string, Evidence | null>>({});
  const [changed, setChanged] = createSignal<Record<string, Changed[] | null>>({});
  // which file's diff is expanded, keyed "<branch>\u0000<path>"
  const [openDiff, setOpenDiff] = createSignal<Record<string, boolean>>({});
  const areas: Record<string, HTMLTextAreaElement | undefined> = {};

  const draftOf = (s: Step): string => drafts()[s.branch] ?? s.story;
  const dirty = (s: Step): boolean => draftOf(s).trim() !== s.story.trim();
  const mark = (branch: string, v: "saving" | "saved" | "failed" | null) =>
    setSaving((m) => {
      const next = { ...m };
      if (v) next[branch] = v; else delete next[branch];
      return next;
    });

  const diffKey = (branch: string, path: string) => `${branch}\u0000${path}`;
  const diffOpen = (branch: string, path: string) => !!openDiff()[diffKey(branch, path)];
  const toggleDiff = (branch: string, path: string) =>
    setOpenDiff((m) => ({ ...m, [diffKey(branch, path)]: !m[diffKey(branch, path)] }));

  const reveal = async (branch: string) => {
    setShown((m) => ({ ...m, [branch]: true }));
    if (branch in evidence()) return;
    setEvidence((m) => ({ ...m, [branch]: null }));
    setChanged((m) => ({ ...m, [branch]: null }));
    const [e, files] = await Promise.all([fetchEvidence(branch), fetchChanged(branch)]);
    setEvidence((m) => ({ ...m, [branch]: e }));
    setChanged((m) => ({ ...m, [branch]: files }));
    const lines = files.reduce((n, f) => n + Number(f.add || 0) + Number(f.del || 0), 0);
    if (lines <= READ_IT_ALL) {
      setOpenDiff((m) => ({ ...m, ...Object.fromEntries(files.map((f) => [diffKey(branch, f.path), true])) }));
    }
  };

  // Typing the description back verbatim clears the override rather than storing a copy of it —
  // the description stays the single source, and the badge flips back to "description".
  const save = async (s: Step, text: string, verbatim = false) => {
    const t = text.trim();
    const stored = !verbatim && t === s.description.trim() ? "" : t;
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
    if (r.prev && r.prev !== stored) {
      setUndoable((u) => ({ ...u, [s.branch]: r.prev }));
      setTimeout(() => setUndoable((u) => { const n = { ...u }; delete n[s.branch]; return n; }), 15000);
    }
  };
  const revert = (s: Step) => setDrafts((d) => { const n = { ...d }; delete n[s.branch]; return n; });
  const focusNext = (from: Step) => {
    const list = (data()?.steps ?? []).filter((x) => !x.landed);
    const i = list.findIndex((x) => x.branch === from.branch);
    const next = list[i + 1];
    if (next) areas[next.branch]?.focus();
  };

  // the rows only exist once the plan resolves, so the opening focus waits for them
  let landed = false;
  createEffect(() => {
    const b = props.focus;
    if (landed || !b || !data()) return;
    landed = true;
    void reveal(b);
    requestAnimationFrame(() => {
      const el = areas[b];
      el?.focus();
      el?.scrollIntoView({ block: "center" });
    });
  });

  return (
    <div class="stories mx-auto my-0 max-w-[1100px] pt-[8px] px-[16px] pb-[40px] font-mono">
      <div class="stories-head flex items-baseline gap-[12px] pt-[6px] px-[2px] pb-[4px]">
        <span class="stories-flow text-[14px] text-ink">{props.project} → main</span>
        <span class="stories-cap text-[11px] uppercase tracking-[0.08em] text-ink-faint">stories · in merge order</span>
      </div>
      <p class="stories-hint mt-0 mx-[2px] mb-[14px] text-[11px] leading-[1.5] text-ink-dim">
        one line per branch: what it does, as a sentence a teammate reads without the diff. every box starts blank — ⌄ opens that branch's commits and the diff of every file it touches, so you can read the point off the change. ↵ saves and moves on, esc reverts, empty falls back to the line underneath.
      </p>
      <Show when={data()} fallback={<p class="stories-empty italic text-ink-faint">loading…</p>}>
        <ol class="stories-list m-0 flex list-none flex-col gap-[3px] p-0">
          <For each={data()!.steps}>
            {(s) => {
              const src = () => sourceOf(s);
              const state = () => saving()[s.branch];
              const shadowed = () => (src() === "story" && s.description ? s.description : "");
              const blank = () => !draftOf(s).trim();
              const here = () => props.here === s.branch;
              const ev = () => evidence()[s.branch];
              return (
                <li class={`stories-row flex flex-col gap-[3px] rounded-[8px] border py-[6px] px-[10px] focus-within:border-rule focus-within:bg-vellum-raise ${here() ? "border-l-2 border-l-ember border-y-transparent border-r-transparent" : "border-transparent"} ${s.landed ? "landed opacity-50" : ""}`}>
                  <div class="flex items-start gap-[10px]">
                    <span class={`stories-n min-w-[18px] flex-none pt-[4px] text-right text-[11px] ${here() ? "text-ember" : "text-gold-leaf"}`}>{s.n}</span>
                    <Show
                      when={!s.landed && canMutate}
                      fallback={<span class="stories-line min-w-0 flex-1 px-[7px] py-[3px] text-[12.5px] leading-[1.55] text-ink-dim">{s.job}</span>}
                    >
                      <textarea
                        ref={(el) => { areas[s.branch] = el; }}
                        class={`stories-input min-w-0 flex-1 resize-none rounded-[5px] border bg-transparent px-[7px] py-[3px] text-[12.5px] leading-[1.55] outline-none placeholder:italic placeholder:text-ink-faint ${dirty(s) ? "border-solid border-gold-deep text-ink" : blank() ? "border-dashed border-rule text-ink-dim focus:border-solid focus:border-gold-deep focus:text-ink" : "border-solid border-transparent text-ink-dim focus:border-gold-deep focus:text-ink hover:border-rule"}`}
                        style={{ "field-sizing": "content" }}
                        rows={1}
                        spellcheck={true}
                        placeholder="what is the point of this branch?"
                        value={draftOf(s)}
                        disabled={state() === "saving"}
                        onFocus={() => void reveal(s.branch)}
                        onInput={(e) => setDrafts((d) => ({ ...d, [s.branch]: e.currentTarget.value }))}
                        onBlur={() => { if (dirty(s) && !saving()[s.branch]) void save(s, draftOf(s)); }}
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
                      <Show when={undoable()[s.branch]}>
                        {(prev) => (
                          <button
                            class="stories-undo cursor-pointer border-0 bg-transparent p-0 text-[10px] text-gold-leaf underline decoration-dotted hover:text-ink"
                            title={`put back: ${prev()}`}
                            onClick={() => { setUndoable((u) => { const n = { ...u }; delete n[s.branch]; return n; }); void save(s, prev(), true); }}
                          >undo</button>
                        )}
                      </Show>
                      <Show when={here()}>
                        <span class="stories-here text-[9.5px] uppercase tracking-[0.06em] text-ember">this branch</span>
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
                  <Show when={blank() && !s.landed && s.job}>
                    <div class="stories-under flex items-baseline gap-[8px] pl-[35px] text-[10.5px] leading-[1.5] text-ink-faint">
                      <span class="min-w-0 flex-1 overflow-hidden text-ellipsis whitespace-nowrap" title={s.job}>
                        <span class="text-ink-faint">falls back to the {src()} ·</span> {s.job}
                      </span>
                      <Show when={canMutate}>
                        <button
                          class="flex-none cursor-pointer border-0 bg-transparent p-0 text-[10.5px] text-ink-faint underline decoration-dotted hover:text-ink"
                          title="start from that line instead of a blank box"
                          onClick={() => { setDrafts((d) => ({ ...d, [s.branch]: s.job })); areas[s.branch]?.focus(); }}
                        >start from it</button>
                      </Show>
                    </div>
                  </Show>
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
                  <Show when={!s.landed}>
                    <div class="stories-ev pl-[35px]">
                      <button
                        class="stories-ev-toggle cursor-pointer border-0 bg-transparent p-0 text-[10px] uppercase tracking-[0.06em] text-ink-faint hover:text-ink"
                        title="what this branch actually changes — its commits and the diff of every file"
                        onClick={() => (shown()[s.branch] ? setShown((m) => ({ ...m, [s.branch]: false })) : void reveal(s.branch))}
                      >{shown()[s.branch] ? "⌃ what it changes" : "⌄ what it changes"}</button>
                      <Show when={shown()[s.branch]}>
                        <Show when={ev()} fallback={<div class="text-[10.5px] italic text-ink-faint">reading the branch…</div>}>
                          {(e) => (
                            <div class="stories-ev-body mt-[3px] flex flex-col gap-[2px] border-l border-rule pl-[9px]">
                              <div class="text-[10px] text-ink-faint">
                                {e().subjects.length} commit{e().subjects.length === 1 ? "" : "s"} · {e().fileCount} file{e().fileCount === 1 ? "" : "s"}
                                {" "}<span class="text-add">+{e().adds}</span> <span class="text-del">−{e().dels}</span>
                              </div>
                              <For each={e().subjects}>
                                {(sub) => <div class="text-[11px] leading-[1.5] text-ink-dim">{sub}</div>}
                              </For>
                              {/* the change itself, not just its file names — small nodes open already read */}
                              <Show
                                when={changed()[s.branch]}
                                fallback={<div class="text-[10.5px] italic text-ink-faint">reading the diff…</div>}
                              >
                                {(files) => (
                                  <div class="stories-files mt-[2px] flex flex-col gap-[1px]">
                                    <For each={files()}>
                                      {(f) => (
                                        <div class="stories-file">
                                          <button
                                            class="stories-file-head flex w-full cursor-pointer items-baseline gap-[8px] rounded-[4px] border-0 bg-transparent px-[3px] py-[2px] text-left hover:bg-vellum-raise"
                                            title={diffOpen(s.branch, f.path) ? "fold this file" : "read this file's diff"}
                                            onClick={() => toggleDiff(s.branch, f.path)}
                                          >
                                            <span class="w-[9px] flex-none text-[9px] text-ink-faint">{diffOpen(s.branch, f.path) ? "⌃" : "⌄"}</span>
                                            <span class="min-w-0 flex-1 overflow-hidden text-ellipsis whitespace-nowrap text-[11px] text-ink-dim">{f.path}</span>
                                            <span class="flex-none text-[10px]"><span class="text-add">+{f.add}</span> <span class="text-del">−{f.del}</span></span>
                                          </button>
                                          <Show when={diffOpen(s.branch, f.path) && f.patch}>
                                            <div class="stories-file-diff diff my-[2px] overflow-x-auto rounded-[6px] border border-rule" innerHTML={patchHtml(f.patch)} />
                                          </Show>
                                        </div>
                                      )}
                                    </For>
                                  </div>
                                )}
                              </Show>
                            </div>
                          )}
                        </Show>
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
