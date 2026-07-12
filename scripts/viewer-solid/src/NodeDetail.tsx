import { createSignal, createMemo, createEffect, on, Show, For, type JSX } from "solid-js";
import { useQueryClient, createQuery, keepPreviousData } from "@tanstack/solid-query";
import { useViewerLocation, forestKey, withNode, forestRepo } from "./router";
import { provider, canMutate, withRepo } from "./provider";
import { leaf, isBlessed, flattenForest } from "./shared";
import { setCameFrom } from "./cameFrom";
import { DirtyRail, FileEntry, CommitsList } from "./FileRail";
import { FilePanel } from "./FilePanel";
import { useNodeMutations } from "./useNodeMutations";
import { useNodeKeyboard } from "./useNodeKeyboard";
import { NodeHeader } from "./NodeHeader";
import { useScrollSpy } from "./useScrollSpy";
import { useNodeChat } from "./useNodeChat";
import { useOpenInNvim } from "./useOpenInNvim";
import ChatIndex from "./ChatIndex";
import { chatToTmux } from "./chatDrawer";
import { useFileCycle } from "./useFileCycle";
import type { FileDiff } from "./types";

// node-view file filter + the `?` shortcut cheatsheet — scoped here so it rides the viewer palette
// without touching the shared index.css.
const NODE_KBD_CSS = `
.file-filter {
  width: 100%; box-sizing: border-box; margin: 0 0 8px; font: inherit; font-size: 12px;
  background: var(--bg, #100e0c); color: var(--ink, #e9e2d4);
  border: 1px solid var(--rule, #3a332b); border-radius: 6px; padding: 5px 8px; outline: none;
}
.file-filter:focus { border-color: var(--gold, #e0ad4e); }
.file-filter::placeholder { color: var(--ink-faint, #6f675a); }
.kbd-help-scrim {
  position: fixed; inset: 0; z-index: 70; display: flex; align-items: center; justify-content: center;
  background: rgba(8,7,6,.55);
}
.kbd-help {
  min-width: 320px; max-width: 92vw; padding: 18px 20px; border-radius: 12px;
  background: var(--raised, #1b1815); border: 1px solid var(--rule, #3a332b);
  box-shadow: 0 24px 64px rgba(0,0,0,.5); font-family: "IBM Plex Mono", ui-monospace, monospace;
  color: var(--ink, #e9e2d4);
}
.kbd-help-head { font-size: 11px; letter-spacing: .08em; text-transform: uppercase; color: var(--ink-faint, #6f675a); margin-bottom: 14px; }
.kbd-help dl { display: grid; grid-template-columns: auto 1fr; gap: 8px 16px; margin: 0; align-items: baseline; }
.kbd-help dl > div { display: contents; }
.kbd-help dt { display: flex; gap: 4px; justify-self: start; margin: 0; }
.kbd-help dt .k {
  font-size: 11px; line-height: 1.5; padding: 1px 7px; border-radius: 5px;
  background: var(--bg, #100e0c); border: 1px solid var(--rule, #3a332b); color: var(--gold, #e0ad4e);
}
.kbd-help dd { margin: 0; font-size: 12.5px; color: var(--ink-dim, #a89e8c); }
`;

// ── node detail: forest spine + review surface ───────────────────────
export function NodeDetail() {
  const qc = useQueryClient();
  const { location, navigate } = useViewerLocation();
  const project = () => forestKey(location());
  const repoKey = () => forestRepo(location()) ?? "loops"; // segregates query caches per repo
  const nodeParam = (): string | undefined => {
    const l = location();
    return l.kind === "home" || l.kind === "push" ? undefined : l.node;
  };

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
  const commits = createQuery(() => ({
    queryKey: ["commits", repoKey(), active()],
    queryFn: () => provider.commits(active()),
    enabled: !!active() && view() === "commits",
    placeholderData: keepPreviousData,
  }));

  const { bless, unbless, bumpInterest, detachUpstream, reseatChildren } = useNodeMutations({
    active,
    blessTarget: nodeRef,
    blessOverride,
    setOverride,
    qc,
    refetchHealth: () => health.refetch(),
  });

  const goto = (b: string) => navigate(withNode(location(), b));
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
              }
            >
          >,
      ),
    enabled: canMutate && healthIds().length > 0,
    placeholderData: keepPreviousData,
    // health is "did the world change while I was away" — the one query that must wake on
    // focus (the global default is refetchOnWindowFocus: false) and converge unattended,
    // else a merge only surfaces on a full reload.
    refetchOnWindowFocus: true,
    refetchInterval: 180_000,
  }));
  const nodeHealth = (b: string) => health.data?.[b];
  // the ambient daemon's per-branch dry-run verdict (shared cache with Home's chip) — surfaces
  // "would restack" / "conflicts with #PR" on the node you're actually looking at.
  const ambient = createQuery(() => ({
    queryKey: ["restack-ambient"],
    queryFn: () => provider.restackAmbient(),
    refetchInterval: 15000,
  }));
  const nodeAmbient = (b: string) => ambient.data?.report?.branches.find((x) => x.branch === b);

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

  const { showChats, setShowChats, openChatInContext } = useNodeChat({
    active,
    location,
    nodeData: () => node.data,
    navigate,
  });

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
    spine,
    active,
    goto,
    setBase,
    hover,
    openInNvim,
    setView,
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
  return (
    <div class="shell" classList={{ "panel-collapsed": !panelOpen() }}>
      <Show when={!panelOpen()}>
        <button class="panel-reopen" title="show the file panel (b)" onClick={() => setPanelOpen(true)}>
          ›
        </button>
      </Show>
      <FilePanel
        spine={spine}
        project={project}
        nodeData={() => node.data}
        isGhost={isGhost}
        blessedOf={blessedOf}
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

      <main
        class="surface"
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
          reseatChildren={reseatChildren}
          detachUpstream={detachUpstream}
          bumpInterest={bumpInterest}
          divergedOpen={divergedOpen}
          setDivergedOpen={setDivergedOpen}
          nodeHealth={nodeHealth}
          divergedData={() => divergedDetail.data}
          view={view}
          base={base}
          BASES={BASES}
          nodeAmbient={nodeAmbient}
          nodeData={() => node.data}
          blessedOf={blessedOf}
          setShowChats={setShowChats}
        />
        <Show when={view() === "diffs"} fallback={<CommitsList q={commits} />}>
          <div class="diff-hint">
            <span class="kbd-hint"><b>tab</b> next file · <b>b</b> files · <b>⌘F</b> filter · <b>?</b> shortcuts</span>
          </div>
          <Show when={node.data} fallback={<p class="loading">loading…</p>}>
            {(data) => (
              <Show
                when={data().files.length}
                fallback={
                  <p class="loading">
                    {base() === "@origin"
                      ? "nothing outgoing — origin already has all of this (or the branch was never pushed; vs parent shows everything)"
                      : "nothing to review here ✦"}
                  </p>
                }
              >
                <Show when={data().files.filter(matchFilter).length} fallback={<p class="loading">no files match “{fileFilter()}”</p>}>
                  {/* off-parent bases are view-only — bless keys on the parent...child patch-id, not the shown diff */}
                  <For each={data().files.filter(matchFilter)}>
                    {/* the ghost has no real branch — send the project so the seed resolves the integrator ref */}
                    {(f) => <FileEntry file={f} blessed={() => blessedOf(f)} bless={bless} branch={active()} readOnly={isGhost() || base() !== ""} onChat={(file, session) => chatToTmux(isGhost() ? { project: project(), path: file.path, patch: file.patch, session } : { branch: active(), path: file.path, patch: file.patch, session })} />}
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
              onChat={(file, session) => chatToTmux({ branch: active(), path: file.path, patch: file.patch, session })}
            />
          </Show>
          <Show when={dirtReceipt()}>
            <p class="dirt-receipt">{dirtReceipt()}{(node.data?.dirty?.length ?? 0) === 0 ? " · working tree clean" : ""}</p>
          </Show>
        </Show>
      </main>
      <Show when={showChats()}>
        <ChatIndex onClose={() => setShowChats(false)} onOpen={openChatInContext} />
      </Show>
      <Show when={showHelp()}>
        <div class="kbd-help-scrim" onClick={() => setShowHelp(false)}>
          <div class="kbd-help" onClick={(e) => e.stopPropagation()}>
            <div class="kbd-help-head">keyboard · reviewing a branch</div>
            <dl>
              <div><dt><span class="k">tab</span></dt><dd>next file</dd></div>
              <div><dt><span class="k">c</span></dt><dd>flip diffs ⇄ commits</dd></div>
              <div><dt><span class="k">1</span><span class="k">2</span><span class="k">3</span><span class="k">4</span></dt><dd>diff vs parent / main / last blessed / outgoing (what a push sends)</dd></div>
              <div><dt><span class="k">b</span></dt><dd>show / hide the file panel</dd></div>
              <div><dt><span class="k">⌘F</span></dt><dd>filter files</dd></div>
              <div><dt><span class="k">⇧B</span></dt><dd>bless file &amp; advance</dd></div>
              <div><dt><span class="k">⇧U</span></dt><dd>unbless file</dd></div>
              <div><dt><span class="k">o</span></dt><dd>open hovered line in nvim</dd></div>
              <div><dt><span class="k">m</span><span class="k">esc</span></dt><dd>up to the forest</dd></div>
              <div><dt><span class="k">?</span></dt><dd>this help</dd></div>
            </dl>
          </div>
        </div>
      </Show>
      <style>{NODE_KBD_CSS}</style>
      <Show when={flash()}>
        <div class="flash">{flash()}</div>
      </Show>
    </div>
  );
}
