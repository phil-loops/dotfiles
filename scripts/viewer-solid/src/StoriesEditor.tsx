import { createSignal, createResource, createEffect, For, Show } from "solid-js";
import { withRepo, canMutate } from "./provider";
import { patchHtml } from "./FileRail";

// Writing a forest's stories: the branch list on the left, the selected branch's actual change
// on the right, each pane scrolling on its own.
//
// Why two panes. A story says what a branch DOES, so you have to read the change to write it —
// but with the diff folded INTO the row, the box you type in slid down the page the moment the
// code appeared, and reaching the next branch meant scrolling past a diff. Now the column you
// type in never moves, the reading pane scrolls independently, and ↵ walks the list: read the
// change, say what it does, ↵, next branch.
//
// Saving writes that branch's own `stack-branch.<b>.story`, so the wording renders on every
// branch's plan block and outlives the branch you happened to edit from. Every box starts BLANK
// — it holds the hand-written story and nothing else, with the line the plan currently falls
// back to (description, else commit subject) underneath: a pre-filled line gets nudged instead
// of written.
type Step = {
  n: number; branch: string; job: string; story: string; description: string; subject: string;
  pr: number | null; landed: boolean;
};
type Source = "story" | "description" | "subject" | "merged";
type Evidence = { subjects: string[]; fileCount: number; adds: number; dels: number };
type Changed = { path: string; add: string; del: string; patch?: string };

// The reading pane opens a normal node's files already unfolded; past this many changed lines
// they arrive folded, so landing on a big branch doesn't dump a thousand lines at you.
const READ_IT_ALL = 400;

const sourceOf = (s: Step): Source => (s.landed ? "merged" : s.story ? "story" : s.description ? "description" : "subject");
const leafOf = (b: string): string => b.split("/").pop() || b;
const linesOf = (files: Changed[]) => files.reduce((n, f) => n + Number(f.add || 0) + Number(f.del || 0), 0);

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
  // the row to land on: selected, focused, its change already in the reading pane
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
  // the branch whose change fills the reading pane — follows whichever row you're in
  const [selected, setSelected] = createSignal<string>("");
  const [evidence, setEvidence] = createSignal<Record<string, Evidence | null>>({});
  const [changed, setChanged] = createSignal<Record<string, Changed[] | null>>({});
  const [folded, setFolded] = createSignal<Record<string, boolean>>({});
  const areas: Record<string, HTMLTextAreaElement | undefined> = {};

  const steps = (): Step[] => data()?.steps ?? [];
  const live = (): Step[] => steps().filter((s) => !s.landed);
  const draftOf = (s: Step): string => drafts()[s.branch] ?? s.story;
  const dirty = (s: Step): boolean => draftOf(s).trim() !== s.story.trim();
  const mark = (branch: string, v: "saving" | "saved" | "failed" | null) =>
    setSaving((m) => {
      const next = { ...m };
      if (v) next[branch] = v; else delete next[branch];
      return next;
    });

  const foldKey = (branch: string, path: string) => JSON.stringify([branch, path]);
  const isFolded = (branch: string, path: string) => !!folded()[foldKey(branch, path)];
  const toggleFold = (branch: string, path: string) =>
    setFolded((m) => ({ ...m, [foldKey(branch, path)]: !m[foldKey(branch, path)] }));

  // reading a branch's change: its commits (cheap) and its per-file patches, fetched once each
  const select = async (branch: string) => {
    setSelected(branch);
    if (branch in evidence()) return;
    setEvidence((m) => ({ ...m, [branch]: null }));
    setChanged((m) => ({ ...m, [branch]: null }));
    const [e, files] = await Promise.all([fetchEvidence(branch), fetchChanged(branch)]);
    setEvidence((m) => ({ ...m, [branch]: e }));
    setChanged((m) => ({ ...m, [branch]: files }));
    if (linesOf(files) > READ_IT_ALL) {
      setFolded((m) => ({ ...m, ...Object.fromEntries(files.map((f) => [foldKey(branch, f.path), true])) }));
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
  const step = (from: Step, by: 1 | -1) => {
    const list = live();
    const next = list[list.findIndex((x) => x.branch === from.branch) + by];
    if (next) areas[next.branch]?.focus();
  };
  const focusNext = (from: Step) => step(from, 1);

  // land on the row you came in on (the sheet's focus, else the first unmerged step) with its
  // change already in the reading pane — the rows only exist once the plan resolves
  let landed = false;
  createEffect(() => {
    if (landed || !data()) return;
    const want = props.focus && live().some((s) => s.branch === props.focus) ? props.focus : live()[0]?.branch;
    if (!want) return;
    landed = true;
    void select(want);
    requestAnimationFrame(() => areas[want]?.focus());
  });

  const readEv = () => evidence()[selected()];
  const readFiles = () => changed()[selected()];

  return (
    <div class="stories flex h-full min-h-0 font-mono">
      {/* the column you type in — a diff appearing on the right never moves it */}
      <div class="stories-col flex w-[40%] min-w-[320px] max-w-[540px] flex-col overflow-y-auto border-y-0 border-l-0 border-r border-solid border-rule px-[14px] pt-[10px] pb-[30px]">
        <div class="stories-head flex items-baseline gap-[10px] px-[2px] pb-[4px]">
          <span class="stories-flow text-[13px] text-ink">{props.project} → main</span>
          <span class="stories-cap text-[10px] uppercase tracking-[0.08em] text-ink-faint">in merge order</span>
        </div>
        <p class="stories-hint mx-[2px] mt-0 mb-[10px] text-[10.5px] leading-[1.5] text-ink-dim">
          what each branch does, in a sentence a teammate reads without the diff. every box starts blank; its change is on the right. ↵ or ↑↓ saves and moves on, esc reverts, empty falls back to the line underneath.
        </p>
        <Show when={data()} fallback={<p class="stories-empty italic text-ink-faint">loading…</p>}>
          <ol class="stories-list m-0 flex list-none flex-col gap-[2px] p-0">
            <For each={steps()}>
              {(s) => {
                const src = () => sourceOf(s);
                const state = () => saving()[s.branch];
                const shadowed = () => (src() === "story" && s.description ? s.description : "");
                const blank = () => !draftOf(s).trim();
                const here = () => props.here === s.branch;
                const on = () => selected() === s.branch;
                return (
                  <li
                    class={`stories-row flex flex-col gap-[2px] rounded-[7px] border-y-0 border-r-0 border-l-2 py-[5px] pr-[6px] pl-[8px] ${on() ? "on border-l-gold-deep bg-vellum-raise" : "border-l-transparent hover:bg-vellum-raise/50"} ${s.landed ? "landed opacity-50" : "cursor-pointer"}`}
                    onClick={() => { if (!s.landed) void select(s.branch); }}
                  >
                    <div class="flex items-start gap-[7px]">
                      <span class={`stories-n min-w-[14px] flex-none pt-[3px] text-right text-[10.5px] ${here() ? "text-ember" : "text-gold-leaf"}`}>{s.n}</span>
                      <Show
                        when={!s.landed && canMutate}
                        fallback={<span class="stories-line min-w-0 flex-1 px-[6px] py-[3px] text-[12px] leading-[1.5] text-ink-dim">{s.job}</span>}
                      >
                        <textarea
                          ref={(el) => { areas[s.branch] = el; }}
                          class={`stories-input min-w-0 flex-1 resize-none rounded-[5px] border bg-transparent px-[6px] py-[3px] text-[12px] leading-[1.5] outline-none placeholder:italic placeholder:text-ink-faint ${dirty(s) ? "border-solid border-gold-deep text-ink" : blank() ? "border-dashed border-rule text-ink-dim focus:border-solid focus:border-gold-deep focus:text-ink" : "border-solid border-transparent text-ink-dim focus:border-gold-deep focus:text-ink hover:border-rule"}`}
                          style={{ "field-sizing": "content" }}
                          rows={1}
                          spellcheck={true}
                          placeholder="what is the point of this branch?"
                          value={draftOf(s)}
                          disabled={state() === "saving"}
                          onFocus={() => void select(s.branch)}
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
                            } else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
                              // let the caret move first — a long story wraps and still needs
                              // vertical movement inside the box; only when the caret CAN'T go
                              // further does the arrow walk the list instead of dying in place
                              const el = e.currentTarget;
                              const at = el.selectionStart;
                              const by = e.key === "ArrowDown" ? 1 : -1;
                              requestAnimationFrame(() => {
                                if (el.selectionStart !== at) return;
                                if (dirty(s)) void save(s, draftOf(s));
                                step(s, by);
                              });
                            }
                          }}
                        />
                      </Show>
                    </div>
                    <div class="stories-meta flex items-baseline gap-[7px] pl-[21px] text-[9.5px]">
                      <Show when={here()}>
                        <span class="stories-here flex-none uppercase tracking-[0.06em] text-ember">this branch</span>
                      </Show>
                      <span class={`stories-src flex-none rounded-[4px] border px-[4px] uppercase tracking-[0.06em] ${BADGE[src()]}`} title={BADGE_TITLE[src()]}>
                        {src() === "merged" && s.pr ? `merged #${s.pr}` : src()}
                      </span>
                      <button
                        tabIndex={-1}
                        class="stories-branch min-w-0 flex-1 cursor-pointer overflow-hidden text-ellipsis whitespace-nowrap border-0 bg-transparent p-0 text-left text-[10px] text-ink-faint hover:text-ink"
                        title={`open ${s.branch}`}
                        onClick={(e) => { e.stopPropagation(); props.onPick(s.branch); }}
                      >{leafOf(s.branch)}</button>
                      <Show when={state()}>
                        <span class={`flex-none ${state() === "failed" ? "text-del" : "text-patina"}`}>{state() === "saving" ? "saving…" : state() === "saved" ? "saved ✓" : "couldn’t save"}</span>
                      </Show>
                      <Show when={undoable()[s.branch]}>
                        {(prev) => (
                          <button
                            tabIndex={-1}
                            class="stories-undo flex-none cursor-pointer border-0 bg-transparent p-0 text-gold-leaf underline decoration-dotted hover:text-ink"
                            title={`put back: ${prev()}`}
                            onClick={(e) => { e.stopPropagation(); setUndoable((u) => { const n = { ...u }; delete n[s.branch]; return n; }); void save(s, prev(), true); }}
                          >undo</button>
                        )}
                      </Show>
                    </div>
                    <Show when={blank() && !s.landed && s.job}>
                      <div class="stories-under flex items-baseline gap-[7px] pl-[21px] text-[10px] leading-[1.45] text-ink-faint">
                        <span class="min-w-0 flex-1 overflow-hidden text-ellipsis whitespace-nowrap" title={s.job}>
                          <span class="text-ink-faint">falls back to the {src()} ·</span> {s.job}
                        </span>
                        <Show when={canMutate}>
                          <button
                            tabIndex={-1}
                            class="flex-none cursor-pointer border-0 bg-transparent p-0 underline decoration-dotted hover:text-ink"
                            title="start from that line instead of a blank box"
                            onClick={(e) => { e.stopPropagation(); setDrafts((d) => ({ ...d, [s.branch]: s.job })); areas[s.branch]?.focus(); }}
                          >start from it</button>
                        </Show>
                      </div>
                    </Show>
                    <Show when={shadowed()}>
                      <div class="stories-under flex items-baseline gap-[7px] pl-[21px] text-[10px] leading-[1.45] text-ink-faint">
                        <span class="min-w-0 flex-1 overflow-hidden text-ellipsis whitespace-nowrap" title={shadowed()}>
                          <span class="text-patina">description</span> {shadowed()}
                        </span>
                        <Show when={canMutate}>
                          <button
                            tabIndex={-1}
                            class="flex-none cursor-pointer border-0 bg-transparent p-0 underline decoration-dotted hover:text-ink"
                            title="drop the story override — the description shows again"
                            onClick={(e) => { e.stopPropagation(); void save(s, s.description); }}
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

      {/* the change itself — its own scroll, so reading it never moves the box you type in */}
      <div class="stories-read min-w-0 flex-1 overflow-y-auto px-[16px] pt-[10px] pb-[40px]">
        <Show
          when={selected()}
          fallback={<p class="stories-read-empty px-[2px] pt-[6px] text-[11px] italic text-ink-faint">pick a branch to read its change</p>}
        >
          <div class="stories-read-head sticky top-0 z-[1] -mx-[16px] mb-[8px] flex items-baseline gap-[10px] border-x-0 border-t-0 border-b border-solid border-rule bg-vellum-night px-[16px] pt-[2px] pb-[7px]">
            <span class="text-[12px] text-ink">{leafOf(selected())}</span>
            <Show when={readEv()}>
              {(e) => (
                <span class="text-[10px] text-ink-faint">
                  {e().subjects.length} commit{e().subjects.length === 1 ? "" : "s"} · {e().fileCount} file{e().fileCount === 1 ? "" : "s"}
                  {" "}<span class="text-add">+{e().adds}</span> <span class="text-del">−{e().dels}</span>
                </span>
              )}
            </Show>
            <button
              class="ml-auto flex-none cursor-pointer border-0 bg-transparent p-0 text-[10px] text-ink-faint hover:text-ink"
              title={`open ${selected()}'s node page`}
              onClick={() => props.onPick(selected())}
            >open the node ↗</button>
          </div>
          <Show when={readEv()} fallback={<p class="text-[11px] italic text-ink-faint">reading the branch…</p>}>
            {(e) => (
              <div class="stories-read-commits mb-[8px] flex flex-col gap-[1px]">
                <For each={e().subjects}>
                  {(sub) => <div class="text-[11px] leading-[1.5] text-ink-dim">{sub}</div>}
                </For>
              </div>
            )}
          </Show>
          <Show when={readFiles()} fallback={<p class="text-[11px] italic text-ink-faint">reading the diff…</p>}>
            {(files) => (
              <Show when={files().length} fallback={<p class="text-[11px] italic text-ink-faint">nothing outgoing on this branch</p>}>
                <div class="stories-files flex flex-col gap-[6px]">
                  <For each={files()}>
                    {(f) => (
                      <div class="stories-file">
                        <button
                          class="stories-file-head flex w-full cursor-pointer items-baseline gap-[8px] rounded-[4px] border-0 bg-transparent px-[3px] py-[2px] text-left hover:bg-vellum-raise"
                          title={isFolded(selected(), f.path) ? "read this file's diff" : "fold this file"}
                          onClick={() => toggleFold(selected(), f.path)}
                        >
                          <span class="w-[9px] flex-none text-[9px] text-ink-faint">{isFolded(selected(), f.path) ? "⌄" : "⌃"}</span>
                          <span class="min-w-0 flex-1 overflow-hidden text-ellipsis whitespace-nowrap text-[11px] text-ink-dim">{f.path}</span>
                          <span class="flex-none text-[10px]"><span class="text-add">+{f.add}</span> <span class="text-del">−{f.del}</span></span>
                        </button>
                        <Show when={!isFolded(selected(), f.path) && f.patch}>
                          <div class="stories-file-diff diff mt-[2px] overflow-x-auto rounded-[6px] border border-rule" innerHTML={patchHtml(f.patch)} />
                        </Show>
                      </div>
                    )}
                  </For>
                </div>
              </Show>
            )}
          </Show>
        </Show>
      </div>
    </div>
  );
}
