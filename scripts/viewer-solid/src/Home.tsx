import { createSignal, createMemo, createEffect, Show, For } from "solid-js";
import { useQueryClient, createQuery, createMutation } from "@tanstack/solid-query";
import { Link, useViewerLocation, type HomeTab, type ViewerLocation } from "./router";
import { provider, canMutate } from "./provider";
import { deleteMode, setDeleteMode } from "./deleteMode";
import { type Action } from "./actions";
import { Hearth } from "./Hearth";
import { ReEntry } from "./ReEntry";
import { NextQueue } from "./NextQueue";
import { ForestRow } from "./ForestRow";
import { useRestack } from "./useRestack";
import { ambientChip, landedChip, type NextStep } from "./homeModel";
import { cachedProjects, rememberProjects } from "./projectsCache";
import { WorkTab } from "./WorkTab";
import { ForestsList } from "./ForestsList";
import { leaf, mergedAgo } from "./shared";
import type { Project, PR, ReviewRequest } from "./types";

// ── home: the ledger summary ─────────────────────────────────────────

const CTX_MENU = "fixed z-[91] max-h-[calc(100dvh-16px)] min-w-[150px] overflow-y-auto overscroll-contain rounded-[8px] border border-rule bg-[#1b1815] p-[4px] shadow-[0_8px_26px_rgba(0,0,0,0.45)]";
const CTX_HEAD = "px-[8px] pt-[4px] pb-[6px] text-[10px] uppercase tracking-[0.08em] text-ink-faint";
const CTX_ITEM = "group flex w-full cursor-pointer items-center gap-[10px] rounded-[6px] px-[8px] text-left text-[12px] leading-[1.55] disabled:cursor-default disabled:bg-transparent";
const CTX_ON = "on text-gold-leaf hover:bg-vellum-edge disabled:opacity-32";
const CTX_OFF = "text-ink-dim hover:bg-vellum-edge hover:text-ink disabled:opacity-32";
const CTX_PIPS = "min-w-[58px] tracking-[-1px]";
const CTX_LBL = "text-ink-faint group-hover:text-inherit";

export function Home() {
  const qc = useQueryClient();
  const prs = createQuery(() => ({
    queryKey: ["myprs"],
    queryFn: () => provider.myPrs(),
  }));
  const projects = createQuery(() => ({
    queryKey: ["projects"],
    queryFn: () => provider.projects(),
    initialData: cachedProjects,
    initialDataUpdatedAt: 0, // treat the cached paint as stale so it always revalidates on open
  }));
  createEffect(() => rememberProjects(projects.data));
  // live chat presence — server truth (srv/chat.py's job registry), not this browser's
  // localStorage, so chats started in another tab (or surviving a closed one) still show.
  type ChatJob = {
    turn: string; branch: string; path: string; question: string; repo: string; project: string;
    status: string; chars: number; done: boolean; ok: boolean | null; created: number;
  };
  const chatJobs = createQuery(() => ({
    queryKey: ["chat-jobs"],
    queryFn: () => fetch("/chat-jobs").then((r) => r.json() as Promise<ChatJob[]>),
    refetchInterval: 5_000,
  }));
  const liveChats = createMemo(() => (chatJobs.data || []).filter((j) => !j.done));
  // a finished chat lingers in the strip briefly as "done ✓" so an answer that landed while you
  // were elsewhere gets seen; the server's own TTL bounds it, this just tightens the window.
  const stripChats = createMemo(() =>
    (chatJobs.data || []).filter((j) => !j.done || Date.now() - j.created * 1000 < 15 * 60_000));
  const chatTarget = (j: ChatJob): ViewerLocation =>
    j.project
      ? { kind: "forest", name: j.project, repo: j.repo || undefined, node: j.branch }
      : { kind: "forest", name: j.branch, repo: j.repo || undefined };
  const fmtChars = (n: number) => (n >= 1000 ? (n / 1000).toFixed(1) + "k" : String(n));
  const chatAgo = (createdSec: number) => {
    const s = Math.max(0, Math.floor(Date.now() / 1000 - createdSec));
    return s < 60 ? `${s}s` : s < 3600 ? `${Math.floor(s / 60)}m` : `${Math.floor(s / 3600)}h`;
  };
  const checkOrigin = createMutation(() => ({
    mutationFn: () => fetch("/check-origin", { method: "POST", body: "{}" }).then((r) => r.json()),
    onSuccess: () => {
      prs.refetch();
      projects.refetch();
    },
  }));

  const post = (url: string, body: unknown): Promise<{ ok?: boolean; err?: string }> =>
    fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }).then((r) => r.json());
  const { running, parked, restackErr, flash, menu, setMenu, dropping, start, abort, resolve, dropProject, mergedNames, progress } =
    useRestack({
      projectsData: () => projects.data,
      refetchProjects: () => projects.refetch(),
      refetchPrs: () => prs.refetch(),
    });

  // the ambient daemon's dry-run forest verdict (scripts/restack-daemon) → one quiet chip
  const ambient = createQuery(() => ({
    queryKey: ["restack-ambient"],
    queryFn: () => provider.restackAmbient(),
    refetchInterval: 15000,
  }));
  // shared cache with the Cmd+K index — lets the ambient chip resolve which forest its
  // actionable branches live in, so a click routes straight to that forest's ▸ ready button.
  const forestBranches = createQuery(() => ({
    queryKey: ["forest-branches"],
    queryFn: () => provider.forestBranches(),
    refetchInterval: 60000,
  }));

  // what just landed on main (the daemon's merge attribution) → a second quiet chip.
  // Gold + PR numbers when any of it is YOURS; a dim count otherwise; gone after a day.
  const merges = createQuery(() => ({
    queryKey: ["restack-merges"],
    queryFn: () => provider.restackMerges(),
    refetchInterval: 15000,
  }));

  const reviewReqs = createQuery(() => ({
    queryKey: ["review-requests"],
    queryFn: () => provider.reviewRequests(),
    // keep the queue warm in the background so newly-requested PRs surface on their
    // own; 30s matches the server's gh-search cache TTL, so most polls are free.
    refetchInterval: 30_000,
    refetchOnWindowFocus: true,
  }));
  const importReview = createMutation(() => ({
    mutationFn: (number: number) => post("/review-import", { number }),
    // flip the row to imported in-place; without this the button drops back to
    // "import" for the frame between the mutation settling and the refetch landing.
    onSuccess: (_res, number) => {
      qc.setQueryData<ReviewRequest[]>(["review-requests"], (cur) =>
        cur?.map((r) => (r.number === number ? { ...r, imported: true } : r)));
    },
  }));
  // right-click a forest card → set its importance (stack-project.<name>.interest) — what
  // floats the forest up the Home list.
  const [ctxMenu, setCtxMenu] = createSignal<
    { x: number; y: number; repo: string; project: string; current: number; shelved: boolean; focused: boolean; tier: string | null } | null
  >(null);
  // drop is destructive (forgets the forest grouping) — a two-click arm so a misclick can't do it.
  const [dropArmed, setDropArmed] = createSignal(false);
  const closeCtx = () => { setCtxMenu(null); setDropArmed(false); };
  // keep the menu fully on-screen: a click near the bottom would otherwise open it past the
  // viewport with its lower items (shelve, drop) unreachable. Clamp after measuring; the CSS
  // max-height caps a tall menu and it scrolls internally.
  const clampMenu = (el: HTMLElement, x: number, y: number) => {
    requestAnimationFrame(() => {
      const pad = 8;
      el.style.left = `${Math.max(pad, Math.min(x, window.innerWidth - el.offsetWidth - pad))}px`;
      el.style.top = `${Math.max(pad, Math.min(y, window.innerHeight - el.offsetHeight - pad))}px`;
    });
  };
  const setInterest = createMutation(() => ({
    mutationFn: (arg: { repo: string; project: string; value: number }) =>
      fetch(`/${arg.repo}/interest`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ project: arg.project, value: arg.value }),
      }).then((r) => r.json()),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["projects"] }),
  }));
  const setShelved = createMutation(() => ({
    mutationFn: (arg: { repo: string; project: string; on: boolean }) =>
      fetch(`/${arg.repo}/shelve`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ project: arg.project, on: arg.on }),
      }).then((r) => r.json()),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["projects"] }),
  }));
  // pin/unpin a forest to the focus lane (stack-project.<name>.focus) — cross-repo, so /focus is
  // not repo-prefixed; the body carries the repo the rank is written into.
  const setFocus = createMutation(() => ({
    mutationFn: (arg: { repo: string; project: string; on: boolean }) =>
      fetch(`/focus`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ repo: arg.repo, project: arg.project, on: arg.on }),
      }).then((r) => r.json()),
    // paint the pin/unpin into the cache NOW — the forest jumps into the lane (and out of triage)
    // instantly, instead of after the whole projects fan-out refetches. Server reconciles on settle.
    onMutate: (arg) => qc.setQueryData<Project[]>(["projects"], (cur) => {
      if (!cur) return cur;
      const maxRank = Math.max(0, ...cur.filter((p) => p.focus != null).map((p) => p.focus ?? 0));
      return cur.map((p) => p.name === arg.project && (p.repo || "loops") === (arg.repo || "loops")
        ? { ...p, focus: arg.on ? maxRank + 1 : null } : p);
    }),
    onSettled: () => qc.invalidateQueries({ queryKey: ["projects"] }),
  }));
  // set a forest's conviction tier (stack-project.<name>.tier); "" unsets → untriaged.
  const setTier = createMutation(() => ({
    mutationFn: (arg: { repo: string; project: string; tier: string }) =>
      fetch(`/${arg.repo}/tier`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ project: arg.project, tier: arg.tier }),
      }).then((r) => r.json()),
    // optimistic: the triage decision lands in the cache immediately so the forest leaves the triage
    // pile (or moves tiers) on click, not on the refetch that follows. "" → untriaged (null).
    onMutate: (arg) => qc.setQueryData<Project[]>(["projects"], (cur) =>
      cur?.map((p) => p.name === arg.project && (p.repo || "loops") === (arg.repo || "loops")
        ? { ...p, tier: (arg.tier || null) as Project["tier"] } : p)),
    onSettled: () => qc.invalidateQueries({ queryKey: ["projects"] }),
  }));

  const { location } = useViewerLocation();
  const tab = (): HomeTab => {
    const l = location();
    return l.kind === "home" ? l.tab : "work";
  };
  // hover a forest row → a card of its branches + one-line purposes ("what's in here").
  // cached per project; a short delay keeps it from flickering as the pointer crosses rows.
  type FPurpose = { branch: string; thesis: string };
  const [ftip, setFtip] = createSignal<{ rows: FPurpose[]; landed: Project["landed"]; x: number; y: number } | null>(null);
  const fpCache = new Map<string, FPurpose[]>();
  let ftipFor: string | null = null;
  let ftipTimer: ReturnType<typeof setTimeout> | undefined;
  const showFtip = (project: string, el: HTMLElement, repo?: string, landed?: Project["landed"]) => {
    clearTimeout(ftipTimer);
    ftipFor = project;
    const r = el.getBoundingClientRect();
    const place = (rows: FPurpose[]) => {
      if (ftipFor !== project || (!rows.length && !landed?.length)) return;
      const estH = 18 + rows.length * 44 + (landed?.length ? 12 + landed.length * 18 : 0);
      // flip above the row when there isn't room below, so the card stays on-screen
      const y = window.innerHeight - r.bottom >= estH + 12 ? r.bottom + 6 : Math.max(8, r.top - estH - 6);
      setFtip({ rows, landed, x: r.left + 18, y });
    };
    const key = (repo && repo !== "loops" ? repo + "/" : "") + project; // repo-qualify so names don't collide across repos
    const cached = fpCache.get(key);
    if (cached) {
      ftipTimer = setTimeout(() => place(cached), 160);
      return;
    }
    // the home list spans repos and isn't pinned to one, so prefix the hovered forest's repo here.
    const prefix = repo && repo !== "loops" ? "/" + encodeURIComponent(repo) : "";
    ftipTimer = setTimeout(() => {
      fetch(prefix + "/forest-purposes?project=" + encodeURIComponent(project))
        .then((res) => res.json() as Promise<FPurpose[]>)
        .then((rows) => { fpCache.set(key, rows); place(rows); })
        .catch(() => {});
    }, 160);
  };
  const hideFtip = () => { clearTimeout(ftipTimer); ftipFor = null; setFtip(null); };

  // declared before the work-tab memos below: createMemo runs eagerly, so a warm prs cache makes
  // them call forestOf during render — a later `const` would hit its temporal dead zone and throw.
  const forestOf = (name: string): Project | undefined => (projects.data || []).find((p) => p.name === name);

  // A PR whose own forest reports it merged is "landed", not open — the merge fact lives on the
  // forest (Project.merged), never on the PR, so without this merged PRs leak into the open list.
  const mergedOf = (p: PR) => {
    const m = forestOf(p.project)?.merged;
    return m && (m.pr === p.num || m.branch === p.branch) ? m : undefined;
  };
  const landedRecently = (p: PR): boolean => {
    const m = mergedOf(p);
    if (!m) return false;
    const at = Date.parse(m.at);
    return Number.isFinite(at) && Date.now() - at < 24 * 3_600_000;
  };
  // the open PR for a forest, if any — drives the [PR #N] badge so a PR'd forest stays in the
  // Forests list (the complete index) instead of vanishing the moment it gets a PR.
  const prOf = (name: string): PR | undefined => (prs.data || []).find((p) => p.project === name);

  const restacking = (name: string) => () => running() === name || running() === "__all__";
  // ambient-restack daemon chip: one quiet forest-wide verdict, sits next to the brand.
  // mr-auto keeps it left-grouped with the brand while ↻ check origin stays right; the
  // landed-* variants drop it (they sit right). Margin rides the variant, not the base —
  // stacking mr-auto and mr-0 would leave the winner to generated order (rule 8).
  const AMB =
    "ml-[14px] rounded-[7px] border border-solid bg-vellum-raise px-[9px] py-[3px] text-[11px] tracking-[0.03em] whitespace-nowrap";
  const AMB_LINK = "cursor-pointer no-underline hover:border-current hover:brightness-[1.12]";
  const AMB_CLS: Record<string, string> = {
    "amb-clean": "mr-auto border-gold-deep text-gold-leaf",
    "amb-restack": "mr-auto border-rule text-patina",
    "amb-contract": "mr-auto border-gold-deep text-patina",
    "amb-conflict": "mr-auto border-del text-del",
    "amb-stale": "mr-auto border-rule text-ink-faint",
    "landed-mine": "mr-0 border-gold-deep text-gold-leaf",
    "landed-other": "mr-0 border-rule text-ink-faint",
  };
  const CHIP =
    "flex-none cursor-pointer rounded-[7px] border bg-transparent px-[11px] py-[3px] text-[11px] leading-[1.55] tracking-[0.03em] transition-[border-color,color,background] duration-[120ms]";
  const dropAction = (p: Project): Action => ({
    id: "drop:" + p.name,
    class: `forest-drop ${CHIP} border-transparent text-del hover:border-del hover:bg-del-bg`,
    armedClass: `forest-drop ${CHIP} border-del bg-del text-[#1a1411]`,
    runningClass: `forest-drop ${CHIP} border-transparent text-del opacity-70 hover:bg-del-bg`,
    arm: true,
    busy: () => dropping() === p.name,
    label: () => (dropping() === p.name ? "⌫ dropping…" : "✕ drop"),
    armLabel: () => "drop forest?",
    run: () => dropProject(p.name),
  });
  const restackAllAction = (): Action => ({
    id: "restack:__all__",
    class: `restack-all ${CHIP} mt-[30px] border-patina text-patina opacity-80 hover:opacity-100`,
    armedClass: `restack-all ${CHIP} mt-[30px] border-del bg-del-bg text-del opacity-80 hover:opacity-100`,
    runningClass: `restack-all ${CHIP} mt-[30px] border-transparent text-patina opacity-80`,
    arm: true,
    busy: () => running() === "__all__",
    label: () => {
      if (running() !== "__all__") return `⟳ restack ${mergedNames().length} with merged work`;
      const d = progress();
      return d?.current
        ? `⤳ restacking ${leaf(d.current)} · ${(d.done ?? 0) + 1}/${d.total ?? "?"}…`
        : "⤳ restacking…";
    },
    armLabel: () => (parked() ? `drop parked ${leaf(parked()!.project)} & restack?` : "restack merged?"),
    run: () => start("__all__"),
  });


  const hasLiveChat = (p: Project) =>
    liveChats().some((j) => (j.project || j.branch) === p.name && (!j.repo || j.repo === p.repo));
  const onContext = (e: MouseEvent, p: Project) => {
    if (!canMutate) return;
    e.preventDefault();
    hideFtip();
    setDropArmed(false);
    setCtxMenu({ x: e.clientX, y: e.clientY, repo: p.repo, project: p.name, current: p.interest ?? 0, shelved: !!p.shelved, focused: p.focus != null, tier: p.tier ?? null });
  };
  const forestRow = (p: Project, folded: boolean, next?: { step: NextStep; start: boolean }) => (
    <ForestRow
      p={p}
      folded={folded}
      next={next}
      parked={parked}
      menu={menu}
      setMenu={setMenu}
      showFtip={showFtip}
      hideFtip={hideFtip}
      onContext={onContext}
      hasLiveChat={hasLiveChat}
      prOf={prOf}
      dropAction={dropAction}
      resolve={resolve}
      abort={abort}
    />
  );

  return (
    <div class="ledger min-h-screen">
      <main class="ledger-page mx-auto w-full max-w-[720px] px-[28px] pt-[60px] pb-[100px]">
        <header class="home-head mb-[34px] flex items-center justify-between">
          <div class="brand big inline-block px-[20px] pb-[2px] font-display text-[44px] font-semibold italic text-ink">
            <span class="brand-mark text-[18px] not-italic text-gold-leaf">✦</span> canopy
          </div>
          <Show when={landedChip(merges.data, projects.data)}>
            {(c) => c().to
              ? <Link class={`amb-chip amb-link ${c().cls} ${AMB} ${AMB_CLS[c().cls]} ${AMB_LINK}`} to={c().to!} title={c().title}>{c().text}</Link>
              : <span class={`amb-chip ${c().cls} ${AMB} ${AMB_CLS[c().cls]} cursor-default`} title={c().title}>{c().text}</span>}
          </Show>
          <Show when={ambientChip(ambient.data, forestBranches.data)}>
            {(c) => c().to
              ? <Link class={`amb-chip amb-link ${c().cls} ${AMB} ${AMB_CLS[c().cls]} ${AMB_LINK}`} to={c().to!} title={c().title}>{c().text}</Link>
              : <span class={`amb-chip ${c().cls} ${AMB} ${AMB_CLS[c().cls]} cursor-default`} title={c().title}>{c().text}</span>}
          </Show>
          <Show when={canMutate}>
            <button
              class="origin-btn cursor-pointer rounded-[8px] border border-rule bg-vellum-raise px-[15px] py-[7px] text-[12px] leading-[1.55] tracking-[0.04em] text-ink-dim transition-[border-color,color] duration-[120ms] enabled:hover:border-gold-deep enabled:hover:text-gold-leaf disabled:cursor-default disabled:opacity-60"
              disabled={checkOrigin.isPending}
              onClick={() => checkOrigin.mutate()}
            >
              {checkOrigin.isPending ? "checking…" : "↻ check origin"}
            </button>
          </Show>
        </header>

        <Hearth />

        <ReEntry
          projects={() => projects.data}
          prOf={prOf}
          reviewCount={() => (reviewReqs.data || []).filter((r) => !r.imported).length}
        />

      <Show when={stripChats().length}>
        <section class="work-sec chat-live mb-[30px]">
          <h2 class="eyebrow mt-[34px] mb-[12px] text-[10px] font-medium tracking-[0.22em] uppercase text-ink-faint">chats <span class="eyebrow-ask ml-2 font-display text-[14px] normal-case italic tracking-normal text-ink-dim">— headless claudes on your branches</span></h2>
          <div class="work-rule mb-[6px] h-px bg-rule" />
          <For each={stripChats()}>
            {(j) => (
              <Link
                class={`chat-row flex items-baseline gap-[10px] rounded-lg px-[9px] py-[6px] text-[13px] text-ink no-underline hover:bg-vellum-edge ${j.done ? "done opacity-55" : ""}`}
                to={chatTarget(j)}
                title={j.question}
              >
                <span class={`chat-mark flex-none ${j.done ? (j.ok === false ? "err text-del" : "ok text-add") : "live text-gold-leaf animate-chat-pulse-slow motion-reduce:animate-none"}`}>✦</span>
                <span class="chat-branch flex-none font-semibold">{leaf(j.branch)}</span>
                <span class="chat-file overflow-hidden text-ellipsis whitespace-nowrap text-ink-dim">{j.path ? leaf(j.path) : "whole branch"}</span>
                <span class="chat-progress ml-auto flex-none text-[12px] text-ink-faint">
                  {j.done ? (j.ok === false ? "✗ failed" : "done ✓") : `${j.status}…`} · {fmtChars(j.chars)} · {chatAgo(j.created)}
                </span>
              </Link>
            )}
          </For>
        </section>
      </Show>

      <NextQueue
        prs={() => prs.data}
        projects={() => projects.data}
        reviewReqs={() => reviewReqs.data}
        tab={tab}
        landedRecently={landedRecently}
      />

      <WorkTab
        prs={() => prs.data}
        reviewReqs={() => reviewReqs.data}
        tab={tab}
        importReview={importReview}
        forestOf={forestOf}
        landedRecently={landedRecently}
      />

      <ForestsList
        tab={tab}
        projects={() => projects.data}
        restackErr={restackErr}
        restackAllAction={restackAllAction}
        forestRow={forestRow}
        parked={parked}
        prOf={prOf}
        setTier={(repo, project, tier) => setTier.mutate({ repo, project, tier })}
      />


        <Show when={flash()}>
          <div class="flash fixed bottom-[26px] left-1/2 z-[250] max-w-[min(90vw,640px)] -translate-x-1/2 rounded-[9px] border border-solid border-rule bg-vellum-raise px-4 py-[9px] text-center text-[12px] text-ink [overflow-wrap:anywhere] shadow-[0_14px_40px_#0009]">{flash()}</div>
        </Show>
        <Show when={ftip()}>
          {(t) => (
            <div class="forest-tip pointer-events-none fixed z-[60] max-h-[calc(100vh-16px)] max-w-[440px] animate-tip-in overflow-hidden rounded-[9px] border border-solid border-rule border-l-2 border-l-gold-deep bg-vellum-raise py-[7px] shadow-[0_10px_30px_rgba(0,0,0,0.5)] motion-reduce:animate-none" style={{ left: `${t().x}px`, top: `${t().y}px` }}>
              <For each={t().rows}>
                {(r) => (
                  <div class="forest-tip-row grid grid-cols-[minmax(84px,36%)_1fr] items-baseline gap-3 px-[14px] py-1">
                    <span class="forest-tip-branch overflow-hidden text-ellipsis whitespace-nowrap font-mono text-[12px] text-ink">{leaf(r.branch)}</span>
                    <span class={`forest-tip-thesis line-clamp-2 font-mono text-[11px] leading-[1.45] ${r.thesis ? "text-ink-dim" : "text-ink-faint opacity-70"}`} classList={{ none: !r.thesis }}>
                      {r.thesis || "no purpose set"}
                    </span>
                  </div>
                )}
              </For>
              <Show when={t().landed?.length}>
                <div class="forest-tip-landed mt-[5px] border-x-0 border-t border-b-0 border-solid border-rule px-[14px] pt-[5px] pb-px">
                  <For each={t().landed}>
                    {(m) => (
                      <div class="forest-tip-landed-row flex items-baseline gap-[10px] py-[2px] font-mono text-[11px]" title={m.title}>
                        <span class="landed-pr text-gold-deep">#{m.pr}</span>
                        <span class="landed-branch flex-1 overflow-hidden text-ellipsis whitespace-nowrap text-ink-dim">{leaf(m.branch)}</span>
                        <span class="landed-ago text-ink-faint">{mergedAgo(m.at) ?? new Date(m.at).toLocaleDateString()}</span>
                      </div>
                    )}
                  </For>
                </div>
              </Show>
            </div>
          )}
        </Show>
      </main>
      <Show when={ctxMenu()}>
        {(m) => (
          <>
            <div
              class="ctx-scrim fixed inset-0 z-[90]"
              onClick={closeCtx}
              onContextMenu={(e) => { e.preventDefault(); closeCtx(); }}
            />
            <div class={`ctx-menu ${CTX_MENU}`} ref={(el) => clampMenu(el, m().x, m().y)} style={{ left: `${m().x}px`, top: `${m().y}px` }}>
              <div class={`ctx-head ${CTX_HEAD}`}>conviction</div>
              <For each={[
                { key: "committed", lbl: "committed", mark: "●", title: "I'm shipping this — keeps its full lifecycle bands" },
                { key: "trying", lbl: "trying", mark: "◐", title: "leaning in, undecided — its own light section" },
                { key: "spike", lbl: "spike", mark: "○", title: "throwaway experiment — folds away quietly" },
                { key: "", lbl: "untriaged", mark: "—", title: "no tier — sits in the triage zone to be decided" },
              ]}>
                {(t) => (
                  <button
                    class={`ctx-item ctx-tier ${CTX_ITEM} py-[5px] ${(m().tier ?? "") === t.key ? CTX_ON : CTX_OFF}`}
                    title={t.title}
                    onClick={() => {
                      setTier.mutate({ repo: m().repo, project: m().project, tier: t.key });
                      setCtxMenu(null);
                    }}
                  >
                    <span class={`ctx-pips ${CTX_PIPS} text-gold-leaf`}>{t.mark}</span>
                    <span class={`ctx-lbl ${(m().tier ?? "") === t.key ? "text-inherit" : CTX_LBL}`}>{t.lbl}</span>
                  </button>
                )}
              </For>
              <button
                class={`ctx-item ctx-focus ${CTX_ITEM} py-[5px] ${m().focused ? CTX_ON : CTX_OFF}`}
                title={m().focused ? "remove from the focus lane" : "pin to the focus lane — your hand-ordered 'pushing now' strip at the top"}
                onClick={() => {
                  setFocus.mutate({ repo: m().repo, project: m().project, on: !m().focused });
                  setCtxMenu(null);
                }}
              >
                <span class={`ctx-pips ${CTX_PIPS} text-gold-leaf`}>{m().focused ? "★" : "☆"}</span>
                <span class={`ctx-lbl ${m().focused ? "text-inherit" : CTX_LBL}`}>{m().focused ? "unpin from focus" : "pin to focus"}</span>
              </button>
              <div class={`ctx-head ${CTX_HEAD}`}>importance</div>
              <For each={[5, 4, 3, 2, 1, 0]}>
                {(lvl) => (
                  <button
                    class={`ctx-item ${CTX_ITEM} py-[5px] ${m().current === lvl ? CTX_ON : CTX_OFF}`}
                    onClick={() => {
                      setInterest.mutate({ repo: m().repo, project: m().project, value: lvl });
                      setCtxMenu(null);
                    }}
                  >
                    <span class={`ctx-pips ${CTX_PIPS} text-gold-leaf`}>{lvl === 0 ? "—" : "▲".repeat(lvl)}</span>
                    <span class={`ctx-lbl ${m().current === lvl ? "text-inherit" : CTX_LBL}`}>{lvl === 0 ? "none" : `level ${lvl}`}</span>
                  </button>
                )}
              </For>
              <button
                class={`ctx-item ctx-shelve ${CTX_ITEM} mt-[4px] border-t border-vellum-edge pt-[7px] pb-[5px] ${CTX_OFF}`}
                title={m().shelved ? "bring this forest back into the active bands" : "deliberately pause this forest — it moves to the shelved fold no matter its PR state"}
                onClick={() => {
                  setShelved.mutate({ repo: m().repo, project: m().project, on: !m().shelved });
                  setCtxMenu(null);
                }}
              >
                <span class={`ctx-pips ${CTX_PIPS} text-gold-leaf`}>{m().shelved ? "▶" : "⏸"}</span>
                <span class={`ctx-lbl ${CTX_LBL}`}>{m().shelved ? "unshelve" : "shelve"}</span>
              </button>
              <div class="ctx-sep mx-[6px] my-[5px] h-px bg-rule" />
              <button
                class={`ctx-item ctx-drop ${CTX_ITEM} py-[5px] ${dropArmed() ? "armed bg-del-bg text-del disabled:opacity-55" : "text-ink-dim hover:bg-del-bg hover:text-del disabled:opacity-55"}`}
                title="forget this forest grouping — the config tag only; its branches are kept"
                disabled={dropping() === m().project}
                onClick={() => {
                  if (dropping() === m().project) { return; }
                  if (!dropArmed()) { setDropArmed(true); return; }
                  dropProject(m().project);
                  closeCtx();
                }}
              >
                <span class={`ctx-pips ${CTX_PIPS} text-del`}>✕</span>
                <span class={`ctx-lbl ${dropArmed() ? "text-del" : CTX_LBL}`}>
                  {dropping() === m().project ? "dropping…" : dropArmed() ? "forget forest? — click to confirm" : "drop project"}
                </span>
              </button>
            </div>
          </>
        )}
      </Show>
    </div>
  );
}
