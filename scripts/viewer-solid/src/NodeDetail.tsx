import { createSignal, createMemo, createEffect, on, Show, For, type JSX } from "solid-js";
import { useQueryClient, createQuery, keepPreviousData } from "@tanstack/solid-query";
import { useViewerLocation, forestKey, nodeOf, forestRepo } from "./router";
import { provider, canMutate, withRepo } from "./provider";
import { leaf, isBlessed, flattenForest } from "./shared";
import { setCameFrom } from "./cameFrom";
import { DirtyRail, FileEntry, CommitsList, CommitDetail, EarlierHistory } from "./FileRail";
import { outlineOf, outlineNumber, sliceOf, outgoingOf } from "./commitOutline";
import { FilePanel } from "./FilePanel";
import { TestNotes } from "./TestNotes";
import { useNodeMutations } from "./useNodeMutations";
import { useNodeKeyboard } from "./useNodeKeyboard";
import { NodeHeader } from "./NodeHeader";
import { OutlineEditor, WordsHeader, wordsOpen, setWordsOpen } from "./OutlineEditor";
import { useScrollSpy } from "./useScrollSpy";
import { useOpenInNvim } from "./useOpenInNvim";
import { useFileCycle } from "./useFileCycle";
import { useLsp } from "./useLsp";
import type { FileDiff } from "./types";

const LOADING = "loading px-1 py-[14px] italic text-ink-faint";

// the `?` shortcut cheatsheet — one row per binding; the div is display:contents so
// dt/dd land directly in the dl grid.
const KBD_DT = "m-0 flex gap-1 justify-self-start";
const KBD_K = "k rounded-[5px] border border-solid border-rule bg-[#100e0c] px-[7px] py-px text-[11px] leading-[1.5] text-[#e0ad4e]";
const KBD_DD = "m-0 text-[12.5px] text-ink-dim";

// ── node detail: forest spine + review surface ───────────────────────
export function NodeDetail() {
  const qc = useQueryClient();
  const { location, navigate } = useViewerLocation();
  const project = () => forestKey(location());
  const repoKey = () => forestRepo(location()) ?? "loops"; // segregates query caches per repo
  const nodeParam = (): string | undefined => nodeOf(location());

  const model = createQuery(() => ({
    queryKey: ["model", repoKey(), project()],
    queryFn: () => provider.model(project()),
    enabled: !!project(),
    placeholderData: keepPreviousData,
  }));
  const spine = createMemo(() => flattenForest(model.data));
  // default to the first node with actual files — a fan-in forest's first root is often an empty
  // integrator (total 0), so landing there shows a blank surface; skip to one with something to review.
  const active = () =>
    nodeParam() || spine().find((n) => (n.total ?? 0) > 0)?.id || spine()[0]?.id || project();
  const parentOf = () => model.data?.nodes?.[active()]?.parent;
  const interestOf = () => model.data?.interest ?? 0;
  const ticketOf = () => model.data?.nodes?.[active()]?.ticket;
  const forestTicket = () => model.data?.ticket;
  // remember the node you're on, so popping back to the forest map highlights where you were.
  createEffect(() => active() && setCameFrom(active()));

  // diff base + view (diffs|commits) reset when you change node.
  const [base, setBase] = createSignal(""); // "" parent | "main" | "blessed" last-blessed
  const [view, setView] = createSignal<"diffs" | "commits">("diffs");
  let lastActive: string | undefined;
  createEffect(() => {
    if (active() !== lastActive) {
      lastActive = active();
      setBase("");
      setView("diffs");
      setSelectedCommit("");
      setSliceAnchor("");
      setFollowPush(false);
      setActiveFile("");
      fileCycle.setCurrent("");
    }
  });

  // the ghost ✦<project> culmination node (picked from the forest map as "~integration"): diff
  // main..refs/stack/<project>-integration — the union of all the project's leaf changes.
  const GHOST = "~integration";
  const isGhost = () => active() === GHOST;
  const nodeRef = () => (isGhost() ? `refs/stack/${project()}-integration` : active());
  // "@origin" = the OUTGOING view: exactly what the red button would send (origin/<branch>…branch).
  // Resolved here because the sentinel must survive branch navigation; stack-forest takes the
  // resolved ref verbatim.
  const nodeBase = () => (isGhost() ? "main" : base() === "@origin" ? `origin/${active()}` : base() || undefined);
  const nodeKey = () => ["node", repoKey(), nodeRef(), nodeBase() ?? ""];

  // ⇧B/⇧U flip a file's blessed state through this local override, NOT the query cache. Writing
  // status into the cache replaces the FileDiff object, so <For> tears the row down and re-mounts
  // it — on unbless that re-renders the whole diff from scratch, which read as a refetch flash.
  // path → blessed?; keeps the object identity stable so the row just expands/collapses in place.
  // Cleared when the node changes (the next load carries fresh server truth). isBlessed reconciles.
  const [blessOverride, setBlessOverride] = createSignal<Record<string, boolean>>({});
  const blessedOf = (f: FileDiff): boolean => {
    const o = blessOverride()[f.path];
    return o === undefined ? isBlessed(f) : o;
  };
  const setOverride = (file: string, val: boolean | undefined) =>
    setBlessOverride((m) => {
      const n = { ...m };
      if (val === undefined) { delete n[file]; } else { n[file] = val; }
      return n;
    });
  createEffect(on(() => nodeKey().join("|"), () => setBlessOverride({}), { defer: true }));

  const node = createQuery(() => ({
    queryKey: nodeKey(),
    queryFn: () => provider.node(nodeRef(), nodeBase()),
    enabled: !!active(),
    placeholderData: keepPreviousData,
  }));
  // fetched with the page (not on the first `c`) so the flip to history is instant — the
  // branch-detail burst already runs in parallel and this one is a single ~150ms call
  const commits = createQuery(() => ({
    queryKey: ["commits", repoKey(), active()],
    queryFn: () => provider.commits(active()),
    enabled: !!active(),
    placeholderData: keepPreviousData,
  }));

  // commits view = the branch read one commit at a time: the outline on top, the selected
  // commit's message + own diff below, [ / ] stepping through the outline (oldest first).
  // ⇧click widens the selection to a contiguous slice (anchor … selected), read as one combined diff.
  const [selectedCommit, setSelectedCommit] = createSignal("");
  const [sliceAnchor, setSliceAnchor] = createSignal("");
  // reading "since last push" is a standing question, not a fixed set of shas: while it holds,
  // a commit landing on the branch widens the slice instead of leaving it on the old tip
  const [followPush, setFollowPush] = createSignal(false);
  const outline = createMemo(() => outlineOf(commits.data));
  const slice = createMemo(() => (sliceAnchor() ? sliceOf(outline(), sliceAnchor(), selectedCommit()) : []));
  const inSlice = () => slice().length > 1;
  const firstOwn = () => (outline().find((c) => !c.carried) ?? outline()[0])?.sha ?? "";
  const selected = () => (commits.data ?? []).find((c) => c.sha === selectedCommit());
  // opens on what a push would send (the usual question); a branch with nothing outgoing opens on commit 1
  const readOutgoing = () => {
    const pushing = outgoingOf(outline());
    if (!pushing.length) return false;
    setSliceAnchor(pushing.length > 1 ? pushing[0].sha : "");
    setSelectedCommit(pushing.at(-1)!.sha);
    setFollowPush(true);
    return true;
  };
  createEffect(() => {
    if (view() !== "commits") return;
    if (followPush()) { if (!readOutgoing()) setFollowPush(false); }
    else if (!selected() && !readOutgoing()) setSelectedCommit(firstOwn());
  });
  const commitDiff = createQuery(() => ({
    queryKey: inSlice() ? ["commit-diff", slice().at(-1)!.sha, slice()[0].sha] : ["commit-diff", selectedCommit()],
    queryFn: () => (inSlice() ? provider.commitDiff(slice().at(-1)!.sha, slice()[0].sha) : provider.commitDiff(selectedCommit())),
    enabled: view() === "commits" && !!selectedCommit(),
    staleTime: Infinity,
  }));
  const commitLabel = () => {
    const c = selected();
    if (!c) return "";
    if (inSlice()) {
      const pushing = outgoingOf(outline());
      const isOutgoing = pushing.length === slice().length && pushing[0]?.sha === slice()[0].sha;
      return `${slice().length} commits combined${isOutgoing ? " · since last push" : ""}`;
    }
    if (c.own === false) return "earlier history";
    if (c.carried) return "carried from a fan-in dep";
    const total = outline().filter((o) => !o.carried).length;
    return `commit ${outlineNumber(outline(), c.sha)} of ${total}`;
  };
  const selectCommit = (sha: string, extend = false) => {
    setFollowPush(false);
    setSliceAnchor(extend && selectedCommit() ? sliceAnchor() || selectedCommit() : "");
    setSelectedCommit(sha);
    setActiveFile("");
    fileCycle.setCurrent("");
  };
  const stepCommit = (delta: number) => {
    const list = outline();
    const next = list[list.findIndex((c) => c.sha === selectedCommit()) + delta];
    if (!next) return;
    selectCommit(next.sha);
    // two frames: leaving a slice swaps the detail's header and diff, and a scroll issued before that settles is lost
    requestAnimationFrame(() => requestAnimationFrame(() => document.querySelector(".commit-detail")?.scrollIntoView({ behavior: "instant", block: "start" })));
  };
  const panelData = () =>
    view() === "diffs"
      ? node.data
      : commitDiff.data && { branch: active(), files: commitDiff.data.files, dirty: [] };

  const { bless, unbless, detachUpstream, reseatChildren } = useNodeMutations({
    active,
    blessTarget: nodeRef,
    blessOverride,
    setOverride,
    qc,
    refetchHealth: () => health.refetch(),
  });

  // the words column: every real branch you can write to — not the integration ghost, not a
  // teammate's imported PR, not the static snapshot
  const showOutline = () => canMutate && !isGhost() && location().kind !== "review" && !!active();
  const BASES: [string, string][] = [["", "parent"], ["main", "main"], ["blessed", "last blessed"], ["@origin", "outgoing"]];
  // The forest map is a destination (the /forests/<project> overview), never docked into
  // the review surface — the diff gets the full width. "back to the forest map" lives in the
  // node header (nh-forest-back).

  // ── forest health: per-node drifted (off-parent → its diff balloons to ≈main) / merged-ghost,
  // for badges + a one-click "fix forest" (restack). Live-only; refetch after a fix lands.
  const healthIds = createMemo(() => spine().map((n) => n.id).filter(Boolean));
  const health = createQuery(() => ({
    queryKey: ["forest-health", forestRepo(location()) ?? "loops", healthIds().join(",")],
    queryFn: () =>
      fetch(withRepo("/forest-health?" + healthIds().map((b) => "branch=" + encodeURIComponent(b)).join("&"))).then(
        (r) =>
          r.json() as Promise<
            Record<
              string,
              {
                drifted: boolean;
                merged: boolean;
                contractable?: boolean;
                parent?: string;
                upstream?: string;
                upstreamBad?: boolean;
                upstreamReason?: string;
                diverged?: boolean;
                ahead?: number;
                behind?: number;
                frozenOrigin?: boolean;
              }
            >
          >,
      ),
    enabled: canMutate && healthIds().length > 0,
    placeholderData: keepPreviousData,
    // health is "did the world change while I was away" — it wakes on focus (the global
    // default is refetchOnWindowFocus: false); unattended convergence is the server's job
    // (pulse freshens the remote world, SSE pushes an update).
    refetchOnWindowFocus: true,
  }));
  const nodeHealth = (b: string) => health.data?.[b];

  // the ⇄ diverged chip's inspect panel: what the divergence actually IS, in the PR's frame —
  // each side's commits with patch-id twins flagged (a rebase reads as "same change, rewritten"),
  // a containment verdict, and what origin's review diff shows today vs after pushing local.
  // Tip-to-tip diffs are deliberately absent: post-restack they're all main-advance noise.
  const [divergedOpen, setDivergedOpen] = createSignal(false);
  createEffect(on(active, () => setDivergedOpen(false)));
  // a dirt verdict's receipt — outlives the rail, which unmounts the moment the tree goes
  // clean (success must not read as disappearance).
  const [dirtReceipt, setDirtReceipt] = createSignal<string | null>(null);
  let dirtReceiptT: ReturnType<typeof setTimeout>;
  const divergedDetail = createQuery(() => ({
    queryKey: ["diverged-detail", forestRepo(location()) ?? "loops", active()],
    placeholderData: keepPreviousData,
    queryFn: () =>
      fetch(withRepo("/diverged-detail?branch=" + encodeURIComponent(active()))).then(
        (r) =>
          r.json() as Promise<{
            ok: boolean;
            err?: string;
            upstream?: string;
            trunk?: string;
            ahead?: { sha: string; subject: string; matched: boolean; fromMain: boolean }[];
            behind?: { sha: string; subject: string; matched: boolean }[];
            containment?: "rebase" | "contained" | "clean-extra" | "overlap";
            overlap?: string[];
            prNow?: string;
            prAfter?: string;
            prFiles?: { path: string; status: "same" | "changed" | "enters" | "leaves"; now: string | null; after: string | null }[];
          }>,
      ),
    enabled: divergedOpen() && !!nodeHealth(active())?.diverged,
  }));

  // the sidebar is a GitHub-PR-style file list for the active node; clicking a row
  // scrolls its diff card into view and lights the row. activeFile tracks the lit row.
  const [activeFile, setActiveFile] = createSignal("");
  // Tab / Shift+Tab cycle through this node's diff cards (nvim <leader>gm style); onCurrent
  // lights the matching sidebar row so the list tracks the keyboard cursor.
  const fileCycle = useFileCycle({ onCurrent: setActiveFile });
  const scrollToFile = (path: string) => {
    setActiveFile(path);
    fileCycle.setCurrent(path); // so a following Tab continues from the file you clicked
    document
      .querySelector(`.entry[data-path="${CSS.escape(path)}"]`)
      ?.scrollIntoView({ behavior: "instant", block: "start" });
  };
  useScrollSpy({ activeFile, setActiveFile, fileCycle });
  // dir/base split so the sidebar greys the folder and bolds the filename (like GitHub).
  const fileSeg = (p: string): JSX.Element => {
    const i = p.lastIndexOf("/");
    return i < 0
      ? (<b>{p}</b>)
      : [<span class="file-dir">{p.slice(0, i + 1)}</span>, <b>{p.slice(i + 1)}</b>];
  };

  const { hover, setHover, flash, openInNvim, lineAt } = useOpenInNvim({ nodeRef });


  // on node change: jump to top, keep the active spine entry in view.
  createEffect(() => {
    active();
    window.scrollTo({ top: 0 });
    queueMicrotask(() =>
      document.querySelector(".spine-node.active")?.scrollIntoView({ block: "nearest" })
    );
  });

  const [panelOpen, setPanelOpen] = createSignal(true);
  // A branch small enough to read top to bottom doesn't need its file list beside the diff: fold
  // the rail once per branch at ≤3 files, unless you open it again yourself.
  let railDecided = "";
  createEffect(() => {
    const b = active(), files = node.data?.files;
    if (!b || !files || railDecided === b) return;
    railDecided = b;
    setPanelOpen(files.length > 3);
  });
  // reading is the default: a new branch opens with the words column closed
  createEffect(on(active, () => setWordsOpen(false), { defer: true }));
  // warm the branch's review worktree (+ its generated tRPC types) while you read, so the first K
  // only pays the type server's own load — CPU in the background, no language server started
  createEffect(on(active, (b) => {
    if (!b || !canMutate || isGhost() || location().kind === "review") return;
    void fetch("/prepare", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ branch: b }) }).catch(() => {});
  }));
  const [fileFilter, setFileFilter] = createSignal("");
  const [showHelp, setShowHelp] = createSignal(false);
  let filterEl: HTMLInputElement | undefined;
  // file filter (⌘F): narrow both the sidebar list and the rendered diffs to matching paths.
  const matchFilter = (f: { path: string }): boolean => {
    const q = fileFilter().trim().toLowerCase();
    return !q || f.path.toLowerCase().includes(q);
  };
  // ⌘F may pop the file panel open just to filter. Remember if WE opened it, so dismissing the
  // filter (esc, or a 2nd ⌘F that hands off to native find) folds it back; if it was already open,
  // it stays open.
  let filterAutoOpenedPanel = false;
  const focusFilter = () => {
    if (!panelOpen()) {
      filterAutoOpenedPanel = true;
      setPanelOpen(true);
    }
    queueMicrotask(() => filterEl?.focus());
  };
  const restorePanel = () => {
    if (filterAutoOpenedPanel) {
      filterAutoOpenedPanel = false;
      setPanelOpen(false);
    }
  };
  useNodeKeyboard({
    focusFilter,
    hover,
    openInNvim,
    setView,
    view,
    stepCommit,
    togglePanel: () => { filterAutoOpenedPanel = false; setPanelOpen((v) => !v); },
    activeFile,
    base,
    onBless: (f) => bless.mutate(f),
    onFileCycleNext: () => fileCycle.next(),
    onUnbless: (f) => unbless.mutate(f),
    showHelp,
    setShowHelp,
    setShowHelpTo: setShowHelp,
    project,
    navigate,
    location,
  });
  const lsp = useLsp({
    branch: active,
    unavailable: () =>
      !canMutate ? "no language server behind a static snapshot"
      : isGhost() ? "the integration preview has no tree to type"
      : view() === "commits" ? "types follow the branch tip — read it in diffs (c)"
      : null,
    pointing: () => !!hover(),
    blocked: showHelp,
    openInNvim,
  });
  return (
    // collapsed → one column, so main (the only in-flow grid child once the spine hides)
    // fills it instead of landing in a 0-width track
    <div
      class={`shell grid min-h-screen ${panelOpen() ? "grid-cols-[264px_1fr]" : "panel-collapsed grid-cols-[1fr]"} ${
        showOutline() && wordsOpen() ? (panelOpen() ? "min-[1200px]:grid-cols-[264px_minmax(0,1fr)_minmax(400px,30vw)]" : "min-[1200px]:grid-cols-[minmax(0,1fr)_minmax(400px,30vw)]") : ""}`}
    >
      <Show when={!panelOpen()}>
        <button
          class="panel-reopen fixed top-4 left-0 z-[5] cursor-pointer rounded-r-lg border border-l-0 border-rule bg-vellum-edge px-[9px] py-[7px] font-mono text-[15px] leading-none text-ink-dim hover:border-gold-deep hover:text-gold-leaf"
          title="show the file panel (b)"
          onClick={() => setPanelOpen(true)}
        >
          ›
        </button>
      </Show>
      <FilePanel
        spine={spine}
        project={project}
        nodeData={panelData}
        isGhost={isGhost}
        caption={() => (view() === "commits" && commitDiff.data ? `${commitDiff.data.files.length} files in ${inSlice() ? `these ${slice().length} commits` : "this commit"}` : undefined)}
        blessedOf={(f) => view() === "diffs" && blessedOf(f)}
        activeFile={activeFile}
        fileFilter={fileFilter}
        setFileFilter={setFileFilter}
        matchFilter={matchFilter}
        scrollToFile={scrollToFile}
        fileSeg={fileSeg}
        onPanelClose={() => setPanelOpen(false)}
        onFilterEl={(el) => (filterEl = el)}
        onRestorePanel={restorePanel}
      />

      {/* min-w-0: a grid child defaults to min-width:auto, so a diff table's min-content
          would silently widen the 1fr track past the viewport — the page scrolled sideways
          at narrow widths while .diff's own overflow-x never engaged */}
      <main
        class="surface min-w-0 max-w-[1500px] px-[34px] pt-[30px] pb-[90px]"
        onMouseOver={(e) => {
          const h = lineAt(e);
          // clear when off any row so `o` can't fire on a stale line; dedup to avoid churn
          setHover((prev) => (prev?.path === h?.path && prev?.line === h?.line ? prev : h));
        }}
        onMouseLeave={() => setHover(null)}
      >
        <NodeHeader
          location={location}
          project={project}
          isGhost={isGhost}
          active={active}
          parentOf={parentOf}
          interestOf={interestOf}
          ticketOf={ticketOf}
          forestTicket={forestTicket}
          reseatChildren={reseatChildren}
          detachUpstream={detachUpstream}
          divergedOpen={divergedOpen}
          setDivergedOpen={setDivergedOpen}
          nodeHealth={nodeHealth}
          divergedData={() => divergedDetail.data}
          view={view}
          commitLabel={commitLabel}
          base={base}
          BASES={BASES}
          nodeData={() => node.data}
          blessedOf={blessedOf}
        />
        <Show when={showOutline() && !wordsOpen()}>
          <WordsHeader branch={active} />
        </Show>
        <TestNotes branch={active} />
        <Show when={view() === "diffs"} fallback={
            <>
              <CommitsList
                q={commits}
                branch={active()}
                frozen={!!health.data?.[active()]?.frozenOrigin}
                selected={selectedCommit()}
                slice={slice()}
                onSelect={selectCommit}
                onSelectOutgoing={() => {
                  if (!readOutgoing()) return;
                  setActiveFile("");
                  fileCycle.setCurrent("");
                }}
                onChanged={() => {
                  // a dropped or reverted commit moved the shas: refresh the list, the push manifest, the model
                  setSelectedCommit("");
                  setSliceAnchor("");
                  commits.refetch();
                  qc.invalidateQueries({ queryKey: ["push-preview"] });
                  qc.invalidateQueries({ queryKey: ["model"] });
                }}
              />
              <CommitDetail commit={selected()} slice={slice()} label={commitLabel()} diff={commitDiff.data} branch={active()} />
              <EarlierHistory q={commits} branch={active()} selected={selectedCommit()} onSelect={selectCommit} />
            </>
          }>
          <Show when={node.data} fallback={<p class={LOADING}>loading…</p>}>
            {(data) => (
              <Show
                when={data().files.length}
                fallback={
                  <p class={LOADING}>
                    {base() === "@origin"
                      ? "nothing outgoing — origin already has all of this (or the branch was never pushed; vs parent shows everything)"
                      : "nothing to review here ✦"}
                  </p>
                }
              >
                <Show when={data().files.filter(matchFilter).length} fallback={<p class={LOADING}>no files match “{fileFilter()}”</p>}>
                  {/* off-parent bases are view-only — bless keys on the parent...child patch-id, not the shown diff */}
                  <For each={data().files.filter(matchFilter)}>
                    {/* the ghost has no real branch — send the project so the seed resolves the integrator ref */}
                    {(f) => <FileEntry file={f} blessed={() => blessedOf(f)} bless={bless} branch={active()} readOnly={base() !== ""} />}
                  </For>
                </Show>
              </Show>
            )}
          </Show>
          {/* uncommitted — working-tree dirt of the worktree holding this branch. Read-only:
              blessing keys on committed content, and dirt isn't committed anywhere yet. This
              is the local-vs-shared model's missing tier made visible (the dirty-sync incident:
              dirt was only ever discovered by tripping a guard). */}
          <Show when={(node.data?.dirty?.length ?? 0) > 0}>
            <DirtyRail
              dirty={node.data!.dirty!}
              worktree={node.data!.worktree ?? ""}
              branch={active()}
              bless={bless}
              onCommit={(receipt) => {
                node.refetch();
                if (receipt) {
                  setDirtReceipt(receipt);
                  clearTimeout(dirtReceiptT);
                  dirtReceiptT = setTimeout(() => setDirtReceipt(null), 8000);
                }
              }}
            />
          </Show>
          <Show when={dirtReceipt()}>
            <p class="dirt-receipt mx-[2px] my-[14px] text-[12px] text-add transition-opacity duration-[240ms] ease-[ease] starting:opacity-0">{dirtReceipt()}{(node.data?.dirty?.length ?? 0) === 0 ? " · working tree clean" : ""}</p>
          </Show>
        </Show>
      </main>
      <Show when={showOutline()}>
        <div class={wordsOpen() ? `outline-dock min-w-0 ${panelOpen() ? "max-[1199px]:col-start-2" : "max-[1199px]:col-span-full"} max-[1199px]:border-t max-[1199px]:border-solid max-[1199px]:border-rule min-[1200px]:sticky min-[1200px]:top-0 min-[1200px]:flex min-[1200px]:h-screen min-[1200px]:flex-col` : "outline-dock hidden"}>
          <OutlineEditor
            branch={active}
            reading={() => (view() === "commits" && !inSlice() ? selectedCommit() : "")}
            onRead={(sha) => {
              if (!sha) { setView("diffs"); return; }
              const c = (commits.data ?? []).find((x) => sha.startsWith(x.sha));
              setView("commits");
              selectCommit(c?.sha ?? sha);
              window.scrollTo({ top: 0 });
            }}
          />
        </div>
      </Show>
      <Show when={showHelp()}>
        <div class="kbd-help-scrim fixed inset-0 z-[70] flex items-center justify-center bg-[rgba(8,7,6,0.55)]" onClick={() => setShowHelp(false)}>
          <div class="kbd-help min-w-[320px] max-w-[92vw] rounded-[12px] border border-solid border-rule bg-[#1b1815] px-5 py-[18px] font-mono text-ink shadow-[0_24px_64px_rgba(0,0,0,0.5)]" onClick={(e) => e.stopPropagation()}>
            <div class="kbd-help-head mb-[14px] text-[11px] uppercase tracking-[0.08em] text-ink-faint">keyboard · reviewing a branch</div>
            <dl class="m-0 grid grid-cols-[auto_1fr] items-baseline gap-x-4 gap-y-2">
              <div class="contents"><dt class={KBD_DT}><span class={KBD_K}>tab</span></dt><dd class={KBD_DD}>next file</dd></div>
              <div class="contents"><dt class={KBD_DT}><span class={KBD_K}>e</span></dt><dd class={KBD_DD}>edit the words — description, outline, landing text (⌘↵ saves, esc reverts)</dd></div>
              <div class="contents"><dt class={KBD_DT}><span class={KBD_K}>c</span></dt><dd class={KBD_DD}>flip diffs ⇄ commits</dd></div>
              <div class="contents"><dt class={KBD_DT}><span class={KBD_K}>[</span><span class={KBD_K}>]</span></dt><dd class={KBD_DD}>previous / next commit (commits view) · ⇧click a row for a slice</dd></div>
              <div class="contents"><dt class={KBD_DT}><span class={KBD_K}>b</span></dt><dd class={KBD_DD}>show / hide the file panel</dd></div>
              <div class="contents"><dt class={KBD_DT}><span class={KBD_K}>⌘F</span></dt><dd class={KBD_DD}>filter files</dd></div>
              <div class="contents"><dt class={KBD_DT}><span class={KBD_K}>⇧B</span></dt><dd class={KBD_DD}>bless file &amp; advance</dd></div>
              <div class="contents"><dt class={KBD_DT}><span class={KBD_K}>⇧U</span></dt><dd class={KBD_DD}>unbless file</dd></div>
              <div class="contents"><dt class={KBD_DT}><span class={KBD_K}>o</span></dt><dd class={KBD_DD}>open hovered line in nvim</dd></div>
              <div class="contents"><dt class={KBD_DT}><span class={KBD_K}>K</span><span class={KBD_K}>space k</span></dt><dd class={KBD_DD}>type under the pointer — starts the branch's tsgo on first ask</dd></div>
              <div class="contents"><dt class={KBD_DT}><span class={KBD_K}>g d</span></dt><dd class={KBD_DD}>go to definition — in the diff, else a side pane (o opens it in Helix, esc closes)</dd></div>
              <div class="contents"><dt class={KBD_DT}><span class={KBD_K}>m</span><span class={KBD_K}>esc</span></dt><dd class={KBD_DD}>forest map — arrows move, ↵ opens</dd></div>
              <div class="contents"><dt class={KBD_DT}><span class={KBD_K}>?</span></dt><dd class={KBD_DD}>this help</dd></div>
            </dl>
          </div>
        </div>
      </Show>
      <lsp.Layer />
      <Show when={flash()}>
        <div class="flash fixed bottom-[26px] left-1/2 z-[250] max-w-[min(90vw,640px)] -translate-x-1/2 rounded-[9px] border border-solid border-rule bg-vellum-raise px-4 py-[9px] text-center text-[12px] text-ink [overflow-wrap:anywhere] shadow-[0_14px_40px_#0009]">{flash()}</div>
      </Show>
    </div>
  );
}
