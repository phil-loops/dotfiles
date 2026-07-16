import { createSignal, createMemo, Show, For } from "solid-js";
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
import { WorkTab } from "./WorkTab";
import { ForestsList } from "./ForestsList";
import { leaf, mergedAgo } from "./shared";
import type { Project, PR, ReviewRequest } from "./types";

// ── home: the ledger summary ─────────────────────────────────────────
export function Home() {
  const qc = useQueryClient();
  const prs = createQuery(() => ({
    queryKey: ["myprs"],
    queryFn: () => provider.myPrs(),
  }));
  const projects = createQuery(() => ({
    queryKey: ["projects"],
    queryFn: () => provider.projects(),
  }));
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
  const { running, parked, restackErr, flash, menu, setMenu, dropping, start, abort, resolve, dropProject, behindNames } =
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
    { x: number; y: number; repo: string; project: string; current: number; shelved: boolean; focused: boolean } | null
  >(null);
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
    onSuccess: () => qc.invalidateQueries({ queryKey: ["projects"] }),
  }));

  const { location, navigate } = useViewerLocation();
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

  const workCount = () => (prs.data || []).length + (reviewReqs.data || []).length;

  const restacking = (name: string) => () => running() === name || running() === "__all__";
  const dropAction = (p: Project): Action => ({
    id: "drop:" + p.name,
    class: "forest-drop",
    arm: true,
    busy: () => dropping() === p.name,
    label: () => (dropping() === p.name ? "⌫ dropping…" : "✕ drop"),
    armLabel: () => "drop forest?",
    run: () => dropProject(p.name),
  });
  const restackAllAction = (): Action => ({
    id: "restack:__all__",
    class: "restack-all",
    arm: true,
    busy: () => running() === "__all__",
    label: () => (running() === "__all__" ? "⤳ restacking all…" : `⟳ restack all ${behindNames().length} behind`),
    armLabel: () => (parked() ? `drop parked ${leaf(parked()!.project)} & restack all?` : "restack all behind?"),
    run: () => start("__all__"),
  });


  const hasLiveChat = (p: Project) =>
    liveChats().some((j) => (j.project || j.branch) === p.name && (!j.repo || j.repo === p.repo));
  const onContext = (e: MouseEvent, p: Project) => {
    if (!canMutate) return;
    e.preventDefault();
    hideFtip();
    setCtxMenu({ x: e.clientX, y: e.clientY, repo: p.repo, project: p.name, current: p.interest ?? 0, shelved: !!p.shelved, focused: p.focus != null });
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
    <div class="ledger">
      <nav class="thumb-index">
        <div class="thumb-brand"><span class="brand-mark">✦</span></div>
        <For each={[
          { id: "work" as const, label: "Work", count: workCount() },
          { id: "forests" as const, label: "Forests", count: (projects.data || []).length },
        ]}>
          {(t) => (
            <button
              class="thumb"
              classList={{ active: tab() === t.id }}
              onClick={() => navigate({ kind: "home", tab: t.id })}
            >
              <span class="thumb-label">{t.label}</span>
              <Show when={t.count}>
                <span class="thumb-count">{t.count}</span>
              </Show>
            </button>
          )}
        </For>
      </nav>

      <main class="ledger-page">
        <header class="home-head">
          <div class="brand big">
            <span class="brand-mark">✦</span> blessed
          </div>
          <Show when={landedChip(merges.data, projects.data)}>
            {(c) => c().to
              ? <Link class={`amb-chip amb-link ${c().cls}`} to={c().to!} title={c().title}>{c().text}</Link>
              : <span class={`amb-chip ${c().cls}`} title={c().title}>{c().text}</span>}
          </Show>
          <Show when={ambientChip(ambient.data, forestBranches.data)}>
            {(c) => c().to
              ? <Link class={`amb-chip amb-link ${c().cls}`} to={c().to!} title={c().title}>{c().text}</Link>
              : <span class={`amb-chip ${c().cls}`} title={c().title}>{c().text}</span>}
          </Show>
          <Show when={canMutate}>
            <button
              class="origin-btn"
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
        <section class="work-sec chat-live">
          <h2 class="eyebrow">chats <span class="eyebrow-ask">— headless claudes on your branches</span></h2>
          <div class="work-rule" />
          <For each={stripChats()}>
            {(j) => (
              <Link class="chat-row" classList={{ done: j.done }} to={chatTarget(j)} title={j.question}>
                <span class={`chat-mark ${j.done ? (j.ok === false ? "err" : "ok") : "live"}`}>✦</span>
                <span class="chat-branch">{leaf(j.branch)}</span>
                <span class="chat-file">{j.path ? leaf(j.path) : "whole branch"}</span>
                <span class="chat-progress">
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
      />


        <Show when={flash()}>
          <div class="flash">{flash()}</div>
        </Show>
        <Show when={ftip()}>
          {(t) => (
            <div class="forest-tip" style={{ left: `${t().x}px`, top: `${t().y}px` }}>
              <For each={t().rows}>
                {(r) => (
                  <div class="forest-tip-row">
                    <span class="forest-tip-branch">{leaf(r.branch)}</span>
                    <span class="forest-tip-thesis" classList={{ none: !r.thesis }}>
                      {r.thesis || "no purpose set"}
                    </span>
                  </div>
                )}
              </For>
              <Show when={t().landed?.length}>
                <div class="forest-tip-landed">
                  <For each={t().landed}>
                    {(m) => (
                      <div class="forest-tip-landed-row" title={m.title}>
                        <span class="landed-pr">#{m.pr}</span>
                        <span class="landed-branch">{leaf(m.branch)}</span>
                        <span class="landed-ago">{mergedAgo(m.at) ?? new Date(m.at).toLocaleDateString()}</span>
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
              class="ctx-scrim"
              onClick={() => setCtxMenu(null)}
              onContextMenu={(e) => { e.preventDefault(); setCtxMenu(null); }}
            />
            <div class="ctx-menu" style={{ left: `${m().x}px`, top: `${m().y}px` }}>
              <button
                class="ctx-item ctx-focus"
                classList={{ on: m().focused }}
                title={m().focused ? "remove from the focus lane" : "pin to the focus lane — your hand-ordered 'pushing now' strip at the top"}
                onClick={() => {
                  setFocus.mutate({ repo: m().repo, project: m().project, on: !m().focused });
                  setCtxMenu(null);
                }}
              >
                <span class="ctx-pips">{m().focused ? "★" : "☆"}</span>
                <span class="ctx-lbl">{m().focused ? "unpin from focus" : "pin to focus"}</span>
              </button>
              <div class="ctx-head">importance</div>
              <For each={[5, 4, 3, 2, 1, 0]}>
                {(lvl) => (
                  <button
                    class="ctx-item"
                    classList={{ on: m().current === lvl }}
                    onClick={() => {
                      setInterest.mutate({ repo: m().repo, project: m().project, value: lvl });
                      setCtxMenu(null);
                    }}
                  >
                    <span class="ctx-pips">{lvl === 0 ? "—" : "▲".repeat(lvl)}</span>
                    <span class="ctx-lbl">{lvl === 0 ? "none" : `level ${lvl}`}</span>
                  </button>
                )}
              </For>
              <button
                class="ctx-item ctx-shelve"
                title={m().shelved ? "bring this forest back into the active bands" : "deliberately pause this forest — it moves to the shelved fold no matter its PR state"}
                onClick={() => {
                  setShelved.mutate({ repo: m().repo, project: m().project, on: !m().shelved });
                  setCtxMenu(null);
                }}
              >
                <span class="ctx-pips">{m().shelved ? "▶" : "⏸"}</span>
                <span class="ctx-lbl">{m().shelved ? "unshelve" : "shelve"}</span>
              </button>
            </div>
          </>
        )}
      </Show>
    </div>
  );
}
