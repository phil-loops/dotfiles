// The words a branch carries, in one column beside its diff: the description (the branch's one
// human line), the outline (every own commit's subject + optional why, oldest first), and the
// landing text — the PR title and body the squash-merge turns into main's commit.
//
// Saving writes every changed row in one server pass (POST /outline): one new commit chain on
// the identical trees, guarded by the head this editor loaded, so a branch another writer moved
// refuses instead of being clobbered. Descendants reseat in the background and report here.
// Rows a remote already holds are read-only. Hints are live and never block.
import { createSignal, createMemo, createEffect, on, For, Show, onCleanup, type JSX } from "solid-js";
import { createStore, reconcile } from "solid-js/store";
import { createQuery, useQueryClient, keepPreviousData } from "@tanstack/solid-query";
import { withRepo, canMutate } from "./provider";
import { postStatus } from "./actions";
import { hintsFor, SUBJECT_LIMIT, type Hint, type Words } from "./outlineHints";
import { PacketEditor, PacketReview, usePacket } from "./ReviewPacket";
import { EMPTY_HAND, handJson, sameHand, type Hand } from "./packetModel";

type Row = {
  sha: string; short: string; subject: string; body: string; pushed: boolean; merge: boolean;
  carried: boolean; locked: string; files: number; add: number; del: number;
};
type Job = {
  id: string; state: "running" | "done"; err?: string;
  results: { branch: string; parent: string; status: "reseated" | "held" | "skipped"; why?: string; commits?: number }[];
};
type Outline = {
  ok: boolean; err?: string; branch: string; parent: string; head: string; description: string; story: string; ticket: string;
  commits: Row[];
  pr: { exists: boolean; number?: number; url?: string; state?: string; draft?: boolean; title?: string | null; body?: string | null; pending?: boolean };
  draft: { title: string; titleSaved: boolean; body: string; bodySaved: boolean; derivedBody: string | null; bodyPending: boolean };
  reseat: Job | null;
  undo: { id: string; ts: number; commits: number; fields: string[] } | null;
};
type SaveResult = {
  ok: boolean; err?: string; moved?: boolean; newTip?: string; changed?: number; fields?: string[];
  reseat?: string | null; restored?: string[]; commits?: number;
};
// undefined = untouched; null = back to the derived value (follow the opening commit / the forest)
type Draft = { desc?: string; rows: Record<string, Words>; prTitle?: string | null; prBody?: string | null; packet?: Hand; prLabel?: boolean };

// sync's last step lands here instead of in a message box: it hands over what it routed and
// asks the column to take focus
const [syncNote, setSyncNote] = createSignal<string[]>([]);
const [focusTick, setFocusTick] = createSignal(0);
// Reading and writing are different jobs: the column opens for writing (e, a click on the words
// header, or sync handing over) and closes again with esc, so the diff reads at full width.
const [wordsOpen, setWordsOpen] = createSignal(false);
export { wordsOpen, setWordsOpen };
export const focusOutline = (notes: string[] = []) => { setSyncNote(notes); setWordsOpen(true); setFocusTick((n) => n + 1); };
export const openWords = () => focusOutline([]);

const same = (a: string, b: string) => a.trim() === b.trim();
const LABEL = "text-[10px] uppercase tracking-[0.11em] text-ink-faint";
const FIELD = "w-full resize-none border-0 bg-transparent p-0 font-mono outline-none [field-sizing:content] placeholder:text-ink-faint/70";
const TONE: Record<Hint["tone"], string> = {
  error: "text-del border-del/50",
  warn: "text-ember border-ember/40",
  note: "text-ink-faint border-rule",
};

const Lock = () => (
  <svg class="inline-block h-[11px] w-[9px] flex-none" viewBox="0 0 9 11" aria-hidden="true">
    <rect x="0.5" y="4.5" width="8" height="6" rx="1" fill="none" stroke="currentColor" />
    <path d="M2.2 4.5V3a2.3 2.3 0 0 1 4.6 0v1.5" fill="none" stroke="currentColor" />
  </svg>
);

function Hints(props: { hints: Hint[]; onFix: (h: Hint) => void }) {
  return (
    <Show when={props.hints.length}>
      <div class="ol-hints mt-[5px] flex flex-wrap gap-[5px]">
        <For each={props.hints}>
          {(h) => (
            <span class={`ol-hint inline-flex items-baseline gap-[6px] rounded-[4px] border border-dashed px-[6px] py-[1px] text-[10.5px] leading-[1.5] ${TONE[h.tone]}`}>
              <span>{h.text.split("`").map((part, i) => (i % 2 ? <code class="font-mono text-ink-dim">{part}</code> : part))}</span>
              <Show when={h.fix}>
                <button
                  class="ol-fix flex-none cursor-pointer whitespace-nowrap border-0 bg-transparent p-0 text-[10.5px] text-gold-leaf underline decoration-gold-deep underline-offset-2 hover:text-ink"
                  onClick={() => props.onFix(h)}
                >{h.fix!.label}</button>
              </Show>
            </span>
          )}
        </For>
      </div>
    </Show>
  );
}

export function OutlineEditor(props: {
  branch: () => string;
  reading: () => string;
  onRead: (sha: string | null) => void;
}) {
  const qc = useQueryClient();
  const q = createQuery(() => ({
    queryKey: ["outline", props.branch()],
    queryFn: () => fetch(withRepo("/outline?branch=" + encodeURIComponent(props.branch()))).then((r) => r.json() as Promise<Outline>),
    enabled: !!props.branch(),
    placeholderData: keepPreviousData,
  }));
  const data = () => (q.data?.ok && q.data.branch === props.branch() ? q.data : undefined);

  const [draft, setDraft] = createStore<Draft>({ rows: {} });
  const [baseHead, setBaseHead] = createSignal("");
  const [banner, setBanner] = createSignal<{ tone: "err" | "ok" | "moved"; text: string } | null>(null);
  const [saving, setSaving] = createSignal(false);
  const [jobId, setJobId] = createSignal<string | null>(null);
  const resetDraft = () => setDraft(reconcile({ rows: {} } as Draft));
  createEffect(on(props.branch, () => { resetDraft(); setBaseHead(""); setBanner(null); setJobId(null); setSyncNote([]); }));

  const rows = () => data()?.commits ?? [];
  const opening = () => rows().find((r) => !r.carried);
  const rowVal = (r: Row): Words => draft.rows[r.sha] ?? { subject: r.subject, body: r.body };
  const rowDirty = (r: Row) => { const d = draft.rows[r.sha]; return !!d && (!same(d.subject, r.subject) || !same(d.body, r.body)); };
  const descVal = () => draft.desc ?? data()?.description ?? "";
  const descDirty = () => draft.desc !== undefined && !same(draft.desc, data()?.description ?? "");
  const followTitle = () => (opening() ? rowVal(opening()!).subject : "");
  const titleVal = () =>
    draft.prTitle === null ? followTitle() : (draft.prTitle ?? (data()?.draft.titleSaved ? data()!.draft.title : followTitle()));
  const titleFollows = () => draft.prTitle === null || (draft.prTitle === undefined && !data()?.draft.titleSaved);
  const titleDirty = () =>
    draft.prTitle === null ? !!data()?.draft.titleSaved : draft.prTitle !== undefined && !same(draft.prTitle, data()?.draft.titleSaved ? data()!.draft.title : followTitle());
  const derivedBody = () => data()?.draft.derivedBody ?? "";
  const bodyVal = () => (draft.prBody === null ? derivedBody() : (draft.prBody ?? data()?.draft.body ?? ""));
  const bodyFollows = () => draft.prBody === null || (draft.prBody === undefined && !data()?.draft.bodySaved);
  const bodyDirty = () =>
    draft.prBody === null ? !!data()?.draft.bodySaved : draft.prBody !== undefined && !same(draft.prBody, data()?.draft.body ?? "");
  // the review packet: only its hand parts are drafted here; the server renders the rest
  const pk = usePacket(props.branch, { guide: () => !!data() && !data()!.pr.exists, enabled: () => wordsOpen() && !!data() });
  const packet = () => (pk.data?.ok && pk.data.branch === props.branch() ? pk.data : undefined);
  const savedHand = () => packet()?.hand ?? EMPTY_HAND;
  const handVal = () => draft.packet ?? savedHand();
  const packetDirty = () => draft.packet !== undefined && !sameHand(draft.packet, savedHand());
  const labelVal = () => draft.prLabel ?? packet()?.label ?? true;
  const labelDirty = () => draft.prLabel !== undefined && draft.prLabel !== (packet()?.label ?? true);
  const dirtyRows = () => rows().filter(rowDirty);
  const dirtyCount = () => dirtyRows().length + (descDirty() ? 1 : 0) + (titleDirty() ? 1 : 0) + (bodyDirty() ? 1 : 0)
    + (packetDirty() ? 1 : 0) + (labelDirty() ? 1 : 0);

  // the head the drafts were written against: adopted silently while clean, held while dirty so
  // a writer that moves the branch underneath shows up here before the save refuses it
  createEffect(on(() => data()?.head, (head) => {
    if (!head) return;
    if (!baseHead() || dirtyCount() === 0) setBaseHead(head);
  }));
  const moved = () => !!data() && !!baseHead() && data()!.head !== baseHead() && dirtyCount() > 0;
  const keepEditsOnNewHead = () => {
    const live = new Set(rows().map((r) => r.sha));
    const orphans = Object.keys(draft.rows).filter((s) => !live.has(s));
    for (const s of orphans) setDraft("rows", s, undefined!);
    setBaseHead(data()!.head);
    setBanner(orphans.length
      ? { tone: "moved", text: `${orphans.length} edit${orphans.length === 1 ? " was" : "s were"} on commits that no longer exist — dropped; the rest now apply to the new head` }
      : { tone: "ok", text: "your edits now apply to the new head" });
  };

  const hintsOf = (r: Row) => (r.locked ? [] : hintsFor(rowVal(r), { opening: r.sha === opening()?.sha, ticket: data()?.ticket || undefined }));
  const titleHints = () => hintsFor({ subject: titleVal(), body: "" }, { opening: true, ticket: data()?.ticket || undefined, kind: "title" });

  const invalidate = () => {
    for (const key of ["outline", "packet", "commits", "node", "model", "push-preview", "prep-route", "forest-health", "outbox"]) {
      void qc.invalidateQueries({ queryKey: [key] });
    }
  };
  const job = createQuery(() => ({
    queryKey: ["outline-reseat", jobId()],
    queryFn: () => fetch(withRepo("/outline-reseat?id=" + jobId())).then((r) => r.json() as Promise<Job & { ok: boolean }>),
    enabled: !!jobId(),
    refetchInterval: (qq) => (qq.state.data?.state === "done" ? false : 300),
  }));
  createEffect(on(() => job.data?.state, (s, prev) => { if (s === "done" && prev !== "done") invalidate(); }));
  const shownJob = () => (jobId() ? job.data : data()?.reseat) ?? null;

  // drafts stay up until the rewritten outline is back, so the column never flashes the old words
  const finish = async (r: SaveResult, verb: string) => {
    setJobId(r.reseat ?? null);
    setBanner({ tone: "ok", text: verb });
    invalidate();
    await q.refetch();
    resetDraft();
    setBaseHead(data()?.head ?? r.newTip ?? "");
  };
  const save = async () => {
    const d = data();
    if (!d || saving() || dirtyCount() === 0) return;
    setSaving(true);
    setBanner(null);
    try {
      const body: Record<string, unknown> = {
        branch: d.branch,
        head: baseHead(),
        edits: dirtyRows().map((r) => ({ sha: r.sha, subject: rowVal(r).subject.trim(), body: rowVal(r).body.trim() })),
      };
      if (descDirty()) body.description = draft.desc;
      if (titleDirty()) body.prTitle = titleFollows() ? "" : titleVal();
      if (bodyDirty()) body.prBody = bodyFollows() ? "" : bodyVal();
      if (packetDirty()) body.packet = handJson(handVal());
      if (labelDirty()) body.prLabel = labelVal() ? "" : "off";
      const { body: r } = await postStatus<SaveResult>("/outline", body);
      if (!r.ok) {
        setBanner({ tone: r.moved ? "moved" : "err", text: r.err || "save refused" });
        if (r.moved) void q.refetch();
        return;
      }
      const parts = [
        r.changed ? `${r.changed} message${r.changed === 1 ? "" : "s"}` : "",
        ...(r.fields ?? []).map((f) => ({ description: "description", prTitle: "PR title", prBody: "PR body", packet: "review packet", prLabel: "review label" })[f] ?? f),
      ].filter(Boolean);
      await finish(r, `✓ saved ${parts.join(" · ") || "nothing new"}`);
    } catch (e) {
      setBanner({ tone: "err", text: (e as Error).message || "save failed" });
    } finally {
      setSaving(false);
    }
  };
  const undo = async () => {
    setSaving(true);
    setBanner(null);
    try {
      const { body: r } = await postStatus<SaveResult>("/outline-undo", { branch: props.branch() });
      if (!r.ok) {
        setBanner({ tone: r.moved ? "moved" : "err", text: r.err || "undo refused" });
        return;
      }
      const what = [r.commits ? `${r.commits} message${r.commits === 1 ? "" : "s"}` : "", ...(r.restored ?? [])].filter(Boolean);
      await finish(r, `↶ restored ${what.join(" · ")}`);
    } finally {
      setSaving(false);
    }
  };
  const revertAll = () => { resetDraft(); setBanner(null); };

  // ── keyboard: ⌘↵ saves everything, esc reverts the field (then lets go of it), e jumps in ──
  let colEl: HTMLElement | undefined;
  const firstField = () => colEl?.querySelector<HTMLElement>(".ol-row:not(.locked) .ol-subject") ?? colEl?.querySelector<HTMLElement>(".ol-desc");
  // ⌘↵ saves from anywhere on the page except another editor (the chat composer owns its own)
  const onGlobalKey = (e: KeyboardEvent) => {
    const t = e.target as Element;
    const typing = t.matches("input, textarea, [contenteditable]");
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
      if (typing && !colEl?.contains(t)) return;
      e.preventDefault();
      void save();
      return;
    }
    if (e.key === "Escape" && wordsOpen() && !typing && !dirtyCount()) {
      setWordsOpen(false);
      return;
    }
    if (e.key !== "e" || e.metaKey || e.ctrlKey || e.altKey || typing) return;
    e.preventDefault();
    if (!wordsOpen()) { openWords(); return; }
    firstField()?.focus();
  };
  window.addEventListener("keydown", onGlobalKey);
  onCleanup(() => window.removeEventListener("keydown", onGlobalKey));
  createEffect(on(focusTick, (n) => {
    if (!n) return;
    queueMicrotask(() => { colEl?.scrollIntoView({ block: "nearest" }); firstField()?.focus(); });
  }, { defer: true }));
  const escTo = (e: KeyboardEvent, dirty: boolean, revert: () => void) => {
    if (e.key !== "Escape") return;
    e.preventDefault();
    if (dirty) revert();
    else (e.currentTarget as HTMLElement).blur();
  };

  // the row being edited shows its counts and hints; the rest stay quiet
  const [focusRow, setFocusRow] = createSignal<string | null>(null);
  const [titleFocus, setTitleFocus] = createSignal(false);
  const [bodyOpen, setBodyOpen] = createSignal(false);
  const setRow = (r: Row, w: Partial<Words>) => setDraft("rows", r.sha, { ...rowVal(r), ...w });

  const Section = (p: { label: string; aside?: JSX.Element; children: JSX.Element }) => (
    <section class="ol-section border-x-0 border-t-0 border-b border-solid border-rule px-[18px] py-[14px]">
      <div class="mb-[8px] flex items-baseline gap-[8px]"><span class={LABEL}>{p.label}</span><span class="ml-auto">{p.aside}</span></div>
      {p.children}
    </section>
  );

  return (
    <aside
      ref={colEl}
      class="outline-col flex min-h-0 flex-1 flex-col border-y-0 border-r-0 border-l border-solid border-rule bg-[linear-gradient(180deg,rgba(230,182,78,0.035),transparent_220px)] font-mono"
    >
      <header class="flex flex-none items-baseline gap-[10px] border-x-0 border-t-0 border-b border-solid border-rule px-[18px] pt-[18px] pb-[11px]">
        <span class="flex-none whitespace-nowrap font-display text-[19px] italic text-gold-leaf">✦ the words</span>
        <button
          class="ml-auto flex-none cursor-pointer border-0 bg-transparent p-0 font-mono text-[11px] text-ink-faint hover:text-ink"
          title={dirtyCount() ? "save or revert first — closing would hide unsaved words" : "back to reading (esc)"}
          disabled={!!dirtyCount()}
          onClick={() => setWordsOpen(false)}
        >esc ✕</button>
        <Show when={data()?.undo && !dirtyCount()}>
          <button
            class="ol-undo flex-none cursor-pointer whitespace-nowrap rounded-[5px] border border-solid border-rule bg-transparent px-[8px] py-[2px] text-[11px] text-ink-dim hover:border-gold-deep hover:text-gold-leaf disabled:opacity-40"
            disabled={saving() || !canMutate}
            title="restore the messages and fields from before the last save — only while they are unpushed and nothing moved the branch since"
            onClick={() => void undo()}
          >↶ undo last save</button>
        </Show>
      </header>

      <Show when={data()} fallback={<p class="px-[18px] py-[16px] text-[12px] italic text-ink-faint">{q.data && !q.data.ok ? q.data.err : "reading the outline…"}</p>}>
        {(d) => (
          <div class="ol-scroll min-h-0 flex-1 overflow-y-auto">
            <Show when={syncNote().length}>
              <p class="ol-sync m-0 border-x-0 border-t-0 border-b border-solid border-rule bg-[rgba(127,160,147,0.07)] px-[18px] py-[8px] text-[11px] italic text-patina">
                ⟲ {syncNote().join(" · ")}
              </p>
            </Show>
            <Show when={moved() || banner()}>
              <div
                class={`ol-banner flex flex-wrap items-baseline gap-x-[10px] gap-y-[4px] border-x-0 border-t-0 border-b border-solid px-[18px] py-[9px] text-[11.5px] leading-[1.5] ${
                  moved() || banner()?.tone === "moved" ? "border-ember/40 bg-ember-wash text-ember"
                    : banner()?.tone === "err" ? "border-del/40 bg-del-bg text-del" : "border-rule bg-add-bg text-add"}`}
                role={banner()?.tone === "err" ? "alert" : "status"}
              >
                <span class="min-w-0 basis-full">{moved() ? "the branch moved while you were editing — another writer landed commits" : banner()!.text}</span>
                <Show when={moved()}>
                  <button class="cursor-pointer border-0 bg-transparent p-0 text-[11px] text-gold-leaf underline underline-offset-2" onClick={keepEditsOnNewHead}>keep my edits on the new head</button>
                  <button class="cursor-pointer border-0 bg-transparent p-0 text-[11px] text-ink-dim underline underline-offset-2" onClick={() => { revertAll(); setBaseHead(d().head); }}>discard them</button>
                </Show>
                <Show when={!moved() && banner()?.tone !== "ok"}>
                  <button class="cursor-pointer border-0 bg-transparent p-0 text-[11px] text-ink-dim hover:text-ink" onClick={() => setBanner(null)}>dismiss</button>
                </Show>
              </div>
            </Show>

            <Section label="what it does" aside={<Show when={descDirty()}><span class="text-[10px] text-gold-leaf">● edited</span></Show>}>
              <textarea
                class={`ol-desc ${FIELD} !font-display text-[18px] italic leading-[1.35] text-ink`}
                rows={1}
                value={descVal()}
                placeholder="one verb-first line — what this branch does"
                readOnly={!canMutate}
                onInput={(e) => setDraft("desc", e.currentTarget.value.replace(/\n/g, " "))}
                onKeyDown={(e) => {
                  if (e.key === "Enter" && !e.metaKey && !e.ctrlKey) { e.preventDefault(); colEl?.querySelector<HTMLElement>(".ol-row:not(.locked) .ol-subject")?.focus(); }
                  escTo(e, descDirty(), () => setDraft("desc", undefined));
                }}
              />
              <Show when={d().story && !same(d().story, descVal())}>
                <p class="ol-story m-0 mt-[7px] text-[11px] leading-[1.5] text-ink-faint">
                  <span class="text-patina">story</span> “{d().story}”
                  <button
                    class="ml-[8px] cursor-pointer border-0 bg-transparent p-0 text-[11px] text-gold-leaf underline decoration-gold-deep underline-offset-2 hover:text-ink"
                    title="the story and the description did the same job — make this the branch's one line (the story stays stored)"
                    onClick={() => setDraft("desc", d().story)}
                  >use story as description</button>
                </p>
              </Show>
            </Section>

            <Section
              label={`the outline · ${rows().filter((r) => !r.carried).length} commit${rows().filter((r) => !r.carried).length === 1 ? "" : "s"}`}
            >
              <Show when={rows().length} fallback={<p class="m-0 text-[12px] italic text-ink-faint">no commits of its own yet</p>}>
                <ol class="m-0 flex list-none flex-col gap-[3px] p-0">
                  <For each={rows()}>
                    {(r, i) => {
                      const n = () => rows().slice(0, i() + 1).filter((x) => !x.carried).length;
                      const isReading = () => !!props.reading() && r.sha.startsWith(props.reading());
                      const len = () => rowVal(r).subject.trim().length;
                      return (
                        <li
                          class={`ol-row group relative rounded-[7px] border border-solid px-[10px] pt-[7px] pb-[7px] transition-[background,border-color] duration-150 ${
                            isReading() ? "border-gold-deep bg-gold-wash" : rowDirty(r) ? "border-gold-deep/60 bg-[rgba(230,182,78,0.04)]" : "border-transparent hover:bg-[rgba(255,255,255,0.02)]"}`}
                          classList={{ locked: !!r.locked }}
                          data-sha={r.sha}
                          onFocusIn={() => setFocusRow(r.sha)}
                          onFocusOut={(e) => { if (!e.currentTarget.contains(e.relatedTarget as Node | null)) setFocusRow((x) => (x === r.sha ? null : x)); }}
                        >
                          <div class="flex items-baseline gap-[9px]">
                            <span class={`w-[14px] flex-none text-right font-display text-[14px] italic ${r.sha === opening()?.sha ? "text-gold-leaf" : "text-ink-faint"}`}>
                              {r.carried ? "·" : n()}
                            </span>
                            <Show
                              when={!r.locked && canMutate}
                              fallback={
                                <span class="min-w-0 flex-1 text-[12.5px] leading-[1.5] text-ink-dim" title={r.locked}>
                                  {r.subject}
                                </span>
                              }
                            >
                              <textarea
                                class={`ol-subject ${FIELD} min-w-0 flex-1 text-[12.5px] leading-[1.5] ${rowDirty(r) ? "text-gold-leaf" : "text-ink"}`}
                                rows={1}
                                value={rowVal(r).subject}
                                spellcheck={false}
                                aria-label={`subject of commit ${n()}`}
                                onInput={(e) => setRow(r, { subject: e.currentTarget.value.replace(/\n/g, " ") })}
                                onKeyDown={(e) => {
                                  if (e.key === "Enter" && !e.metaKey && !e.ctrlKey) {
                                    e.preventDefault();
                                    (e.currentTarget.closest(".ol-row")?.querySelector(".ol-body") as HTMLElement | null)?.focus();
                                  }
                                  escTo(e, rowDirty(r), () => setDraft("rows", r.sha, undefined!));
                                }}
                              />
                              <Show when={focusRow() === r.sha}>
                                <span class={`flex-none text-[10px] tabular-nums ${len() > SUBJECT_LIMIT ? "text-ember" : "text-ink-faint/60"}`}>{len()}</span>
                              </Show>
                            </Show>
                          </div>
                          <div class="pl-[23px]">
                            <Show
                              when={!r.locked && canMutate}
                              fallback={<Show when={r.body}><p class="m-0 mt-[2px] whitespace-pre-wrap text-[11.5px] leading-[1.5] text-ink-faint">{r.body}</p></Show>}
                            >
                              <textarea
                                class={`ol-body ${FIELD} mt-[1px] text-[11.5px] leading-[1.55] ${rowDirty(r) ? "text-ink-dim" : "text-ink-faint"} focus:text-ink-dim ${rowVal(r).body.trim() || focusRow() === r.sha ? "" : "hidden"}`}
                                rows={1}
                                value={rowVal(r).body}
                                spellcheck={false}
                                placeholder="why — only if it isn't obvious"
                                aria-label={`why of commit ${n()}`}
                                onInput={(e) => setRow(r, { body: e.currentTarget.value })}
                                onKeyDown={(e) => escTo(e, rowDirty(r), () => setDraft("rows", r.sha, undefined!))}
                              />
                            </Show>
                            <Show when={focusRow() === r.sha || rowDirty(r)}>
                              <Hints hints={hintsOf(r)} onFix={(h) => setRow(r, h.fix!.apply(rowVal(r)))} />
                            </Show>
                            <div class={`mt-[3px] flex-wrap items-center gap-x-[9px] text-[10px] text-ink-faint ${r.locked || isReading() || focusRow() === r.sha ? "flex" : "hidden group-hover:flex"}`}>
                              <span class="tabular-nums">{r.short.slice(0, 8)}</span>
                              <button
                                tabIndex={-1}
                                class={`ol-read cursor-pointer border-0 bg-transparent p-0 text-[10px] ${isReading() ? "text-gold-leaf" : "text-ink-faint hover:text-ink-dim"}`}
                                title={isReading() ? "back to the whole branch's diff" : "read this commit's own diff in the main column"}
                                onClick={() => props.onRead(isReading() ? null : r.sha)}
                              >
                                {isReading() ? "◂ reading" : "▸"} {r.files} file{r.files === 1 ? "" : "s"} <span class="text-add">+{r.add}</span> <span class="text-del">−{r.del}</span>
                              </button>
                              <Show when={r.locked}>
                                <span class="inline-flex items-center gap-[4px] text-ink-faint" title={r.locked}><Lock /> {r.pushed ? "pushed" : r.merge ? "merge" : "carried"}</span>
                              </Show>
                            </div>
                          </div>
                        </li>
                      );
                    }}
                  </For>
                </ol>
              </Show>
            </Section>

            <Section
              label="lands on main as"
              aside={<Show when={d().pr.exists}><a class="text-[10.5px] text-gold-leaf no-underline hover:text-ink" href={d().pr.url} target="_blank" rel="noreferrer">edit on GitHub ↗</a></Show>}
            >
              <div class="ol-landing relative rounded-[8px] border border-solid border-rule bg-vellum-night/70 py-[10px] pr-[12px] pl-[16px] before:absolute before:top-[10px] before:bottom-[10px] before:left-[6px] before:w-[2px] before:rounded-full before:bg-gold-deep before:content-['']">
                <Show
                  when={!d().pr.exists}
                  fallback={
                    <Show when={!d().pr.pending} fallback={<p class="m-0 text-[11.5px] italic text-ink-faint">reading the PR from GitHub…</p>}>
                      <p class="m-0 text-[13px] leading-[1.45] text-ink">
                        {d().pr.title ?? <span class="italic text-ink-faint">couldn't read the title from GitHub</span>} <span class="text-ink-faint">(#{d().pr.number})</span>
                      </p>
                      <Show when={d().pr.body}>
                        <p class="ol-pr-body m-0 mt-[8px] max-h-[220px] overflow-y-auto whitespace-pre-wrap text-[11px] leading-[1.55] text-ink-dim">{d().pr.body}</p>
                      </Show>
                      <Show when={packet()?.review}>
                        {(rv) => <div class="mt-[10px] border-x-0 border-b-0 border-t border-dashed border-rule pt-[8px]"><PacketReview review={rv()} /></div>}
                      </Show>
                    </Show>
                  }
                >
                  <div class="flex items-baseline gap-[6px]">
                    <textarea
                      class={`ol-title ${FIELD} min-w-0 flex-1 text-[13px] leading-[1.45] ${titleDirty() ? "text-gold-leaf" : "text-ink"}`}
                      rows={1}
                      value={titleVal()}
                      spellcheck={false}
                      readOnly={!canMutate}
                      aria-label="PR title"
                      onInput={(e) => setDraft("prTitle", e.currentTarget.value.replace(/\n/g, " "))}
                      onFocus={() => setTitleFocus(true)}
                      onBlur={() => setTitleFocus(false)}
                      onKeyDown={(e) => {
                        if (e.key === "Enter" && !e.metaKey && !e.ctrlKey) e.preventDefault();
                        escTo(e, titleDirty(), () => setDraft("prTitle", undefined));
                      }}
                    />
                    <span class="flex-none text-[12px] text-ink-faint">(#…)</span>
                  </div>
                  <Show when={!titleFollows()}>
                    <button class="mt-[3px] cursor-pointer border-0 bg-transparent p-0 text-[10px] text-ink-faint underline underline-offset-2 hover:text-ink-dim" onClick={() => setDraft("prTitle", null)}>↺ follow commit 1</button>
                  </Show>
                  <Show when={titleFocus() || titleDirty()}>
                    <Hints hints={titleHints()} onFix={(h) => setDraft("prTitle", h.fix!.apply({ subject: titleVal(), body: "" }).subject)} />
                  </Show>
                  <Show
                    when={d().draft.bodySaved || bodyDirty()}
                    fallback={
                      <Show when={bodyOpen() || packetDirty() || labelDirty()} fallback={
                        <button
                          class="ol-packet-fold mt-[8px] block cursor-pointer border-0 bg-transparent p-0 text-left font-mono text-[10.5px] text-ink-faint hover:text-ink-dim"
                          title="the PR body: checkable claims, scope, place in the forest, reading order, what's verified"
                          onClick={() => setBodyOpen(true)}
                        >
                          ▸ review packet
                          <Show when={packet()}>
                            {(p) => <span class="text-ink-faint/80"> · {(handVal().intent ?? p().sections.intentSeed).length} claims{p().sections.notDerived.length + handVal().not.length ? ` · ${p().sections.notDerived.length + handVal().not.length} out of scope` : ""} · {labelVal() ? "◉" : "○"} {p().labelName}</span>}
                          </Show>
                        </button>
                      }>
                        <PacketEditor
                          branch={props.branch}
                          title={titleVal}
                          hand={handVal}
                          setHand={(h) => setDraft("packet", h)}
                          label={labelVal}
                          setLabel={(on) => setDraft("prLabel", on)}
                          packet={packet}
                          refetch={() => void pk.refetch()}
                        />
                        <Show when={!packetDirty() && !labelDirty()}>
                          <button class="mt-[6px] cursor-pointer border-0 bg-transparent p-0 text-[10px] text-ink-faint hover:text-ink-dim" onClick={() => setBodyOpen(false)}>▾ fold</button>
                        </Show>
                      </Show>
                    }
                  >
                  <textarea
                    class={`ol-prbody ${FIELD} mt-[10px] min-h-[5lh] border-x-0 border-b-0 border-t border-dashed border-rule pt-[8px] text-[11px] leading-[1.6] ${bodyDirty() ? "text-ink" : "text-ink-dim"}`}
                    rows={4}
                    value={bodyVal()}
                    spellcheck={false}
                    readOnly={!canMutate}
                    placeholder={d().draft.bodyPending ? "drafting from the forest…" : "the PR body — your words on top, the forest furniture below"}
                    aria-label="PR body"
                    onInput={(e) => setDraft("prBody", e.currentTarget.value)}
                    onKeyDown={(e) => escTo(e, bodyDirty(), () => setDraft("prBody", undefined))}
                  />
                  <div class="mt-[3px] flex items-baseline gap-[10px] text-[10px] text-ink-faint">
                    <span class="text-ink-faint">a hand-written body — it wins over the review packet</span>
                    <Show when={!bodyFollows()}>
                      <button class="cursor-pointer border-0 bg-transparent p-0 text-[10px] text-gold-leaf underline underline-offset-2 hover:text-ink" onClick={() => setDraft("prBody", null)}>↺ use the review packet</button>
                    </Show>
                  </div>
                  </Show>
                </Show>
              </div>
            </Section>
          </div>
        )}
      </Show>

      <Show when={canMutate && data() && (dirtyCount() || shownJob())}>
        <footer class="ol-bar flex flex-none flex-col gap-[6px] border-x-0 border-b-0 border-t border-solid border-rule bg-vellum-night px-[18px] py-[10px]">
          <Show when={shownJob()}>
            {(j) => (
              <div class="ol-reseat flex flex-wrap items-baseline gap-x-[8px] gap-y-[2px] text-[10.5px]">
                <Show when={j().state === "running"} fallback={<span class="text-patina">⤴ descendants</span>}>
                  <span class="animate-breathe text-gold-leaf">⤴ reseating descendants…</span>
                </Show>
                <For each={j().results}>
                  {(x) => (
                    <span
                      class={x.status === "reseated" ? "text-add" : "text-ember"}
                      title={x.why ?? `${x.commits ?? 0} commit${x.commits === 1 ? "" : "s"} carried onto ${x.parent}`}
                    >{x.status === "reseated" ? "✓" : "⚠"} {x.branch.split("/").pop()}{x.status === "reseated" ? "" : ` ${x.status}`}</span>
                  )}
                </For>
                <Show when={j().err}><span class="text-del">{j().err}</span></Show>
              </div>
            )}
          </Show>
          <div class="flex items-center gap-[10px]">
            <span class="text-[10.5px] text-ink-faint">{dirtyCount() ? `${dirtyCount()} unsaved` : ""}</span>
            <button
              class="ml-auto cursor-pointer border-0 bg-transparent p-0 text-[11px] text-ink-faint hover:text-ink disabled:cursor-default disabled:opacity-40"
              disabled={!dirtyCount() || saving()}
              onClick={revertAll}
            >revert</button>
            <button
              class="ol-save cursor-pointer rounded-[6px] border border-solid border-gold-deep bg-gold-wash px-[12px] py-[4px] text-[12px] text-gold-leaf enabled:hover:bg-[rgba(230,182,78,0.16)] disabled:cursor-default disabled:border-rule disabled:bg-transparent disabled:text-ink-faint"
              disabled={!dirtyCount() || saving() || moved()}
              title="rewrite every changed unpushed message in one pass — trees untouched, gates stay green"
              onClick={() => void save()}
            >
              {saving() ? "saving…" : `save${dirtyCount() ? ` ${dirtyCount()}` : ""}`} <span class="text-[10px] opacity-70">⌘↵</span>
            </button>
          </div>
        </footer>
      </Show>
    </aside>
  );
}


// What the branch says, quietly above the diff while you read it: the description and the commit
// subjects, from the same cached /outline the column edits. One click (or e) opens the column.
export function WordsHeader(props: { branch: () => string }) {
  const q = createQuery(() => ({
    queryKey: ["outline", props.branch()],
    queryFn: () => fetch(withRepo("/outline?branch=" + encodeURIComponent(props.branch()))).then((r) => r.json() as Promise<Outline>),
    enabled: !!props.branch(),
    placeholderData: keepPreviousData,
  }));
  const d = () => (q.data?.ok && q.data.branch === props.branch() ? q.data : undefined);
  const own = () => (d()?.commits ?? []).filter((c) => !c.carried);
  // an open PR's packet: stale since publishing? what did the bot dispute? (cached server-side)
  const pk = usePacket(props.branch, { enabled: () => !!d()?.pr.exists && d()!.pr.state === "OPEN" });
  const review = () => (pk.data?.ok && pk.data.branch === props.branch() ? pk.data.review : null);
  return (
    <Show when={d()}>
      {(o) => (
        <>
        <button
          class="words-header group mb-[18px] block w-full cursor-pointer rounded-[9px] border border-solid border-transparent bg-transparent px-[2px] py-[4px] text-left hover:border-rule"
          title="edit the words — description, commits, PR title (e)"
          onClick={() => openWords()}
        >
          <span class="block font-display text-[17px] italic leading-[1.4] text-ink-dim group-hover:text-ink">
            {o().description || <span class="text-ink-faint">no description yet</span>}
          </span>
          <Show when={own().length}>
            <span class="mt-[4px] block font-mono text-[11.5px] leading-[1.6] text-ink-faint">
              <For each={own()}>{(c, i) => <span class="block truncate">{i() + 1}. {c.subject}</span>}</For>
            </span>
          </Show>
          <span class="mt-[3px] block font-mono text-[10px] text-ink-faint opacity-0 transition-opacity duration-150 group-hover:opacity-100">✎ edit the words · e</span>
        </button>
        <Show when={review() && (review()!.stale || review()!.findings.length || review()!.botRan)}>
          <div class="words-packet -mt-[12px] mb-[18px] px-[2px]"><PacketReview review={review()!} compact /></div>
        </Show>
        </>
      )}
    </Show>
  );
}
