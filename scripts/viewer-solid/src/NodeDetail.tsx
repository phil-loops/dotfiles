import { createSignal, createMemo, createEffect, on, onCleanup, Show, For, type JSX } from "solid-js";
import { useQueryClient, createQuery, createMutation } from "@tanstack/solid-query";
import { useViewerLocation, Link, forestKey, withNode, forestRepo } from "./router";
import { provider, canMutate, withRepo } from "./provider";
import { leaf, isBlessed, interestPips, flattenForest } from "./shared";
import { setCameFrom } from "./cameFrom";
import { DirtyRail, FileEntry, CommitsList } from "./FileRail";
import { DivergedDetailPanel } from "./DivergedDetailPanel";
import { FilePanel } from "./FilePanel";
import { NodeActions } from "./NodeActions";
import ChatIndex from "./ChatIndex";
import { chatTarget, openChat, chatToTmux } from "./chatDrawer";
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
  }));
  const commits = createQuery(() => ({
    queryKey: ["commits", repoKey(), active()],
    queryFn: () => provider.commits(active()),
    enabled: !!active() && view() === "commits",
  }));

  // Optimistic in the override, no cache write and no refetch on the keystroke — the row flips in
  // place. onError restores the prior override so a failed POST snaps back.
  const bless = createMutation(() => ({
    mutationFn: (file: string) =>
      fetch(withRepo("/bless"), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ branch: active(), file }),
      }).then((r) => r.json()),
    onMutate: (file: string) => { const prev = blessOverride()[file]; setOverride(file, true); return { file, prev }; },
    onError: (_e, _file, ctx) => { if (ctx) { setOverride(ctx.file, ctx.prev); } },
  }));

  const unbless = createMutation(() => ({
    mutationFn: (file: string) =>
      fetch(withRepo("/bless"), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ branch: active(), file, unbless: true }),
      }).then((r) => r.json()),
    onMutate: (file: string) => { const prev = blessOverride()[file]; setOverride(file, false); return { file, prev }; },
    onError: (_e, _file, ctx) => { if (ctx) { setOverride(ctx.file, ctx.prev); } },
  }));

  // promote/demote this forest's manual interest level — orders it on the Forests home.
  const bumpInterest = createMutation(() => ({
    mutationFn: (arg: { project: string; delta: number }) =>
      fetch(withRepo("/interest"), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(arg),
      }).then((r) => r.json()),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["model"] });
      qc.invalidateQueries({ queryKey: ["projects"] });
    },
  }));

  // neutralize a footgun tracking ref (renamed/foreign remote or origin/main) by unsetting
  // it — config-only, keeps every commit; GitHub Desktop then offers Publish, not a Pull.
  const detachUpstream = createMutation(() => ({
    mutationFn: (branch: string) =>
      fetch("/fix-upstream", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ branch }),
      }).then((r) => r.json()),
    onSuccess: () => health.refetch(),
  }));

  // scoped reseat for a drifted node: rebase the parent's off-tip children (this node and any
  // orphaned siblings, recursively) back onto the parent's current tip — nothing else moves,
  // unlike a full restack. Local only; conflicts leave that subtree parked for a manual pass.
  const reseatChildren = createMutation(() => ({
    mutationFn: (parent: string) =>
      fetch("/reseat-children", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ branch: parent }),
      }).then((r) => r.json() as Promise<{ ok: boolean; moved: string[]; conflicts: { branch: string; err: string }[] }>),
    onSuccess: () => {
      health.refetch();
      qc.invalidateQueries({ queryKey: ["model"] }); // children's SHAs moved — diffs are stale
    },
  }));

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

  // cross-forest chat index overlay (read-only; every thread in this browser).
  const [showChats, setShowChats] = createSignal(false);
  // a chat the index asked to open on a (possibly other) branch: navigate there, then open the
  // drawer once that node's files have loaded (see the effect below). Cleared once opened.
  const [pendingChat, setPendingChat] = createSignal<{ branch: string; path: string } | null>(null);

  // resolve a chat target into the drawer: prefer the real FileDiff (carries the patch); else
  // synthesize a minimal one so the server computes the diff for that path. "" path → whole branch.
  const openChatFor = (path: string) => {
    const at = { branch: active(), origin: location() };
    if (!path) {
      openChat({ ...at, file: null });
      return;
    }
    const real = node.data?.files.find((f) => f.path === path);
    openChat({ ...at, file: real ?? { path, status: "modified" } });
  };
  // from the index: open a chat in its own branch+file context. Same branch → open now; another
  // branch → navigate (as a standalone node) and let the effect open it once its files arrive.
  const openChatInContext = (branch: string, path: string) => {
    setShowChats(false);
    if (branch === active()) {
      openChatFor(path);
    } else {
      setPendingChat({ branch, path });
      navigate({ kind: "standalone", branch });
    }
  };
  createEffect(() => {
    const p = pendingChat();
    if (p && active() === p.branch && node.data?.files) {
      openChatFor(p.path);
      setPendingChat(null);
    }
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
  // keep the lit sidebar row on screen when Tab cycles to a file scrolled out of the list
  // (block:nearest is a no-op when it's already visible, e.g. right after a click).
  createEffect(() => {
    if (!activeFile()) return;
    queueMicrotask(() =>
      document.querySelector(".file-item.active")?.scrollIntoView({ block: "nearest" })
    );
  });
  // scroll-spy: as you just scroll the diff surface, light the row for the card you're reading —
  // the last card whose top has passed under the toolbar line. rAF-throttled; also seeds the Tab
  // cursor so cycling continues from where you scrolled. (Tab/click route through here too via
  // their own scroll, so all three motions converge on the same lit row.)
  const SPY_OFFSET = 100;
  let spyRaf = 0;
  const onScroll = () => {
    if (spyRaf) return;
    spyRaf = requestAnimationFrame(() => {
      spyRaf = 0;
      const cards = document.querySelectorAll<HTMLElement>(".entry[data-path]");
      if (!cards.length) return;
      let pick = cards[0];
      for (const el of cards) {
        if (el.getBoundingClientRect().top <= SPY_OFFSET) pick = el;
        else break;
      }
      const path = pick.getAttribute("data-path") || "";
      if (path && path !== activeFile()) {
        setActiveFile(path);
        fileCycle.setCurrent(path);
      }
    });
  };
  window.addEventListener("scroll", onScroll, { passive: true });
  onCleanup(() => {
    window.removeEventListener("scroll", onScroll);
    if (spyRaf) cancelAnimationFrame(spyRaf);
  });
  // dir/base split so the sidebar greys the folder and bolds the filename (like GitHub).
  const fileSeg = (p: string): JSX.Element => {
    const i = p.lastIndexOf("/");
    return i < 0
      ? (<b>{p}</b>)
      : [<span class="file-dir">{p.slice(0, i + 1)}</span>, <b>{p.slice(i + 1)}</b>];
  };

  // hover a diff line + press o → open that exact line in the warm review-nvim. Hover-armed and
  // event-delegated off the surface; there is deliberately no click-to-open — a mouse click on a
  // line collided with plain text selection, so opening is keyboard-only.
  const [hover, setHover] = createSignal<{ path: string; line: number } | null>(null);
  const [flash, setFlash] = createSignal("");
  let flashT: ReturnType<typeof setTimeout>;
  const note = (m: string) => { setFlash(m); clearTimeout(flashT); flashT = setTimeout(() => setFlash(""), 1900); };
  const openInNvim = (path: string, line: number | null) =>
    !canMutate
      ? undefined // static snapshot: no live nvim to open into
      : fetch(withRepo("/open"), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ branch: nodeRef(), path, ...(line != null ? { pos: String(line) } : {}) }),
    })
      .then((r) => r.json())
      .then((r) => note(r.ok ? `⌁ ${leaf(path)}:${line ?? ""} → nvim` : "⌁ open failed — see server"))
      .catch(() => note("⌁ open failed — server unreachable"));
  const lineAt = (e: MouseEvent): { path: string; line: number } | null => {
    const target = e.target as Element | null;
    const ent = target?.closest<HTMLElement>(".entry");
    const tr = target?.closest<HTMLElement>("tr");
    if (!ent || !tr) return null;
    // arm anywhere in the row (code OR gutter) by reading that row's line-number cell —
    // not only when the cursor is over the tiny number itself
    const ln = tr.querySelector<HTMLElement>(".d2h-code-side-linenumber, .d2h-code-linenumber");
    const n = parseInt((ln?.textContent || "").trim(), 10);
    return Number.isFinite(n) ? { path: ent.dataset.path ?? "", line: n } : null;
  };

  // keyboard: j/k walk the spine; 1/2/3 switch the diff base; b toggles the file panel; ? for all.
  const onKey = (e: KeyboardEvent) => {
    // already typing (incl. the filter box) → let everything bubble: a 2nd ⌘F reaches native find
    if ((e.target as Element).matches("input, textarea, [contenteditable]")) return;
    if ((e.metaKey || e.ctrlKey) && e.key === "f") { e.preventDefault(); focusFilter(); return; }
    if (e.metaKey || e.ctrlKey || e.altKey) return; // leave OS/browser chords alone
    const list = spine();
    const i = list.findIndex((n) => n.id === active());
    if (e.key === "j" && i < list.length - 1) { e.preventDefault(); goto(list[i + 1].id); }
    else if (e.key === "k" && i > 0) { e.preventDefault(); goto(list[i - 1].id); }
    else if (e.key === "1") setBase("");
    else if (e.key === "2") setBase("main");
    else if (e.key === "3") setBase("blessed");
    else if (e.key === "4") setBase("@origin");
    else if (e.key === "o" && hover()) { e.preventDefault(); const h = hover()!; openInNvim(h.path, h.line); }
    else if (e.key === "c") setView((v) => (v === "commits" ? "diffs" : "commits"));
    else if (e.key === "b") { e.preventDefault(); filterAutoOpenedPanel = false; setPanelOpen((v) => !v); } // show / hide the file panel
    // ⇧B blesses the focused file and advances (B·B·B down a branch, no mouse); ⇧U unblesses it in
    // place. Per-file only — there is deliberately no bless-all key.
    // advance in the next frame — after the just-blessed card collapses — so the scroll lands the
    // next card at the toolbar line instead of over-shooting past the freed-up space.
    else if (e.key === "B" && activeFile() && base() === "") { e.preventDefault(); bless.mutate(activeFile()); requestAnimationFrame(() => fileCycle.next()); }
    else if (e.key === "U" && activeFile() && base() === "") { e.preventDefault(); unbless.mutate(activeFile()); }
    else if (e.key === "?") { e.preventDefault(); setShowHelp((v) => !v); }
    else if (e.key === "m") {
      // m → up to the forest view. The key reached for by muscle memory (Esc does it too).
      e.preventDefault();
      const p = project();
      if (p) navigate({ kind: "forest", name: p, repo: forestRepo(location()) });
    }
    else if (e.key === "Escape") {
      // up a level: help → close it; else (when the chat drawer isn't grabbing Esc) → the forest map
      if (showHelp()) { setShowHelp(false); }
      else if (!chatTarget()) { const p = project(); if (p) { navigate({ kind: "forest", name: p, repo: forestRepo(location()) }); } }
    }
  };
  window.addEventListener("keydown", onKey);
  onCleanup(() => window.removeEventListener("keydown", onKey));

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
        <header class="node-head">
          {/* forest strip — forest altitude: which project + restack-forest. Lifted out of the
              branch control bar so forest-scope actions stop bleeding into branch controls. */}
          <div
            class="nh-forest"
            style={{
              display: "flex",
              "align-items": "center",
              gap: "10px",
              "padding-bottom": "10px",
              "border-bottom": "1px solid var(--rule)",
            }}
          >
            <Show
              when={location().kind === "forest"}
              fallback={
                <span
                  style={{
                    "font-size": "11px",
                    "letter-spacing": "0.07em",
                    "text-transform": "uppercase",
                    color: "var(--ink-faint)",
                  }}
                >
                  {project()}
                </span>
              }
            >
              <Link
                class="nh-forest-back"
                to={{ kind: "forest", name: project(), repo: forestRepo(location()) }}
                title="back to the forest map — your current node stays highlighted there"
              >
                ⊞ {project()}
              </Link>
            </Show>
            <div class="nh-spacer" />
          </div>
          {/* branch strip — identity: the branch name + what it's diffed against + health badges. */}
          <div class="nh-id">
            <h1>{isGhost() ? `✦ ${project()}` : leaf(active()) || "—"}</h1>
            <Show
              when={isGhost()}
              fallback={
                <Show when={parentOf()}>
                  <span class="against">◂ {leaf(parentOf())}</span>
                </Show>
              }
            >
              <span class="against">◂ main · all changes on this project</span>
            </Show>
            <Show when={!isGhost() && interestOf() > 0}>
              <span class="nh-ready" title={`interest ${interestOf()} — this forest is promoted on the Forests home`}>
                {interestPips(interestOf())}
              </span>
            </Show>
            {/* health badges folded into the spine (reasons tooltip + ⋯ overrides) — what
                remains here is only the transient outcome of a repair fired from ⋯. */}
            <Show when={reseatChildren.isPending || detachUpstream.isPending}>
              <span class="nh-drift">{reseatChildren.isPending ? "⤴ reseating…" : "✂ detaching…"}</span>
            </Show>
            <Show when={reseatChildren.data && !reseatChildren.data.ok}>
              <span
                class="nh-drift"
                title={reseatChildren.data!.conflicts.map((c) => `${c.branch}: ${c.err}`).join("\n")}
              >
                ⚠ reseat: {reseatChildren.data!.conflicts.length} conflicted — resolve by hand or restack
              </span>
            </Show>
          </div>
          <Show when={divergedOpen() && nodeHealth(active())?.diverged}>
            <DivergedDetailPanel data={divergedDetail.data} />
          </Show>
          {/* tier 2 — controls: view switches on the left, branch state + actions on the right.
              The blessed count lives in the spine; the map opens from the spine + `m`. */}
          {/* tier-2 (Phil, strikes 6+7): no view controls at all — c flips diffs⇄commits,
              1/2/3 set the diff base, both taught in ? help. The base shows as passive text
              only when it's not the default, so a non-parent diff can't masquerade. */}
          <div class="nh-bar">
            <Show when={view() === "commits"}>
              <span class="nh-viewnote">commits · c for diffs</span>
            </Show>
            <Show when={view() === "diffs" && base() !== "" && !isGhost()}>
              <span class="nh-viewnote">vs {(BASES.find(([v]) => v === base()) ?? BASES[0])[1]} · 1 for parent</span>
            </Show>
            <div class="nh-spacer" />
            <Show when={!isGhost()}>
              <NodeActions
                branch={active()}
                isReview={location().kind === "review"}
                merged={nodeHealth(active())?.merged}
                ambient={nodeAmbient(active())}
                blessing={node.data ? { total: node.data.files.length, blessed: node.data.files.filter(blessedOf).length } : undefined}
                health={nodeHealth(active())}
                onReseat={() => { const p = nodeHealth(active())?.parent; if (p) reseatChildren.mutate(p); }}
                onDetach={() => detachUpstream.mutate(active())}
                onInspect={() => setDivergedOpen(!divergedOpen())}
                interest={canMutate ? interestOf() : undefined}
                onBump={canMutate ? (delta) => bumpInterest.mutate({ project: project(), delta }) : undefined}
                onAllChats={() => setShowChats(true)}
              />
            </Show>
            <Show when={canMutate}>
              <button class="icon-btn" onClick={() => chatToTmux({ branch: active() })} title="chat about this whole branch — opens an interactive claude beside your tmux panes">
                ✦
              </button>
            </Show>
          </div>
        </header>
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
                    {(f) => <FileEntry file={f} blessed={() => blessedOf(f)} bless={bless} branch={active()} readOnly={isGhost() || base() !== ""} onChat={(file) => chatToTmux({ branch: active(), path: file.path, patch: file.patch })} />}
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
              onChat={(file) => chatToTmux({ branch: active(), path: file.path, patch: file.patch })}
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
