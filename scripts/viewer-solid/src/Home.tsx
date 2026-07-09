import { createSignal, createMemo, Show, For, Switch, Match } from "solid-js";
import { useQueryClient, createQuery, createMutation } from "@tanstack/solid-query";
import { Link, useViewerLocation, type HomeTab, type ViewerLocation } from "./router";
import { provider, canMutate } from "./provider";
import { deleteMode, setDeleteMode } from "./deleteMode";
import { ActionBar, type Action } from "./actions";
import { Hearth } from "./Hearth";
import { NextQueue } from "./NextQueue";
import { ForestRow } from "./ForestRow";
import { useRestack } from "./useRestack";
import { ambientChip, landedChip } from "./homeModel";
import { leaf, mergedAgo, interestPips } from "./shared";
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
    { x: number; y: number; repo: string; project: string; current: number } | null
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

  const { location, navigate } = useViewerLocation();
  const tab = (): HomeTab => {
    const l = location();
    return l.kind === "home" ? l.tab : "work";
  };
  const [forestQuery, setForestQuery] = createSignal("");
  // Forests recency — one opinionated order, no sort knobs (Phil, 2026-07-05, third strike
  // on option-proliferation). "Most recently alive": the latest of local commit, PR opened,
  // and merge-to-main. The individual timestamps stay as passive per-card metadata.
  const forestTs = (p: Project): number =>
    Math.max(
      (p.lastCommit ?? 0) * 1000,
      p.prOpened ? Date.parse(p.prOpened) : 0,
      p.merged?.at ? Date.parse(p.merged.at) : 0,
    );

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
  // one lifecycle state per row — drives the status-rail colour (the "blessing spine").
  type WorkState = "changes" | "review" | "pending" | "draft" | "landed";
  const prState = (p: PR): WorkState =>
    landedRecently(p) ? "landed"
    : p.review === "CHANGES_REQUESTED" ? "changes"
    : p.review === "APPROVED" ? "review"
    : p.draft ? "draft"
    : "pending";

  // Work tab partitions: what needs you (changes requested) → what's in flight (open, by
  // forest) → what just landed (merged < 1d, then it drops off on its own).
  const needsYouPRs = createMemo(() =>
    (prs.data || []).filter((p) => !landedRecently(p) && p.review === "CHANGES_REQUESTED"));
  const inFlightByProject = createMemo<[string, PR[]][]>(() => {
    const m = new Map<string, PR[]>();
    for (const p of prs.data || []) {
      if (landedRecently(p) || p.review === "CHANGES_REQUESTED") continue;
      const k = p.project || "—";
      (m.get(k) ?? m.set(k, []).get(k)!).push(p);
    }
    return [...m.entries()];
  });
  const landedPRs = createMemo(() => (prs.data || []).filter(landedRecently));
  // one verdict per in-flight forest, replacing the 4-fact comma run in the old header.
  const forestVerdict = (proj: string, list: PR[]): { label: string; state: WorkState } => {
    const f = forestOf(proj);
    if (list.some((p) => p.review === "APPROVED")) return { label: "in review", state: "review" };
    if (f && f.behind > 60) return { label: `${f.behind} behind · stale`, state: "changes" };
    if (list.every((p) => p.draft)) return { label: "draft", state: "draft" };
    return { label: "open", state: "pending" };
  };

  // the trailing slot of a work row — a landed row reads "forest · ago ✓"; everything else keeps
  // the review mark (▲ changes / ✓ approved / • pending) and a draft tag when relevant.
  const workRowTrail = (p: PR) => {
    if (landedRecently(p)) {
      const m = mergedOf(p)!;
      return (
        <>
    <span class="work-meta">{p.project} · {mergedAgo(m.at)}</span>
          <span class="pr-rev ok">✓</span>
        </>
      );
    }
    const [mark, cls] = review(p.review);
    return (
      <>
{p.draft && <span class="pr-draft">draft</span>}
        <span class={`pr-rev ${cls}`}>{mark}</span>
      </>
    );
  };

  // one work row, state-rail on the left. Forest-backed PRs route in-app and carry recessive
  // hover actions; a bare PR is itself the GitHub link, so it needs no action bar.
  // A landed row's answer to "what now": the forest's first mergeable root still
  // without a PR — the natural next push after a merge contracts the stack.
  const nextUp = (p: PR): string | undefined =>
    p.project ? forestOf(p.project)?.candidates?.[0] : undefined;

  const workRow = (p: PR) => {
    const state = prState(p);
    const body = (
      <>
        <span class="pr-num">#{p.num}</span>
        <span class="pr-title">{p.title}</span>
        {workRowTrail(p)}
      </>
    );
    return p.project ? (
      <div class={`work-row work-state-${state}`}>
        <Link class="work-link" to={{ kind: "forest", name: p.project, node: p.branch }}>{body}</Link>
        <Show when={state !== "landed"}>
          <span class="work-acts"><ActionBar actions={workRowActions(p)} /></span>
        </Show>
        <Show when={state === "landed" && nextUp(p)}>
          {(n) => (
            <Link class="work-next" to={{ kind: "forest", name: p.project!, node: n() }}>
              next ▸ {leaf(n())}
            </Link>
          )}
        </Show>
      </div>
    ) : (
      <a class={`work-row work-state-${state}`} href={p.url} target="_blank">{body}</a>
    );
  };

  // the open PR for a forest, if any — drives the [PR #N] badge so a PR'd forest stays in the
  // Forests list (the complete index) instead of vanishing the moment it gets a PR.
  const prOf = (name: string): PR | undefined => (prs.data || []).find((p) => p.project === name);

  const filteredForests = createMemo(() => {
    const needle = forestQuery().trim().toLowerCase();
    const list = projects.data || [];
    return needle ? list.filter((p) => p.name.toLowerCase().includes(needle)) : list;
  });
  // A forest folds into "recently merged" only once it's fully wrapped up: a recent merge AND no
  // mergeable roots left (every branch landed AND got contracted). A forest where one base merged
  // but others are still open/unpushed keeps mergeable roots, so it stays in the active list —
  // that's the moment to restack and ship the rest, not bury it. (mergeable still lists squash-
  // merged-but-uncontracted roots, so a just-merged forest lingers in active until you contract it.)
  const recentlyMerged = (p: Project): boolean =>
    !!(p.merged && mergedAgo(p.merged.at)) && !p.mergeable?.length;
  // Group the home list by repo (loops first, then alphabetical), then within each repo split the
  // active forests into PRIORITY TIERS (interest level, descending) so same-priority work stands
  // together, and pull recently-merged forests aside into their own fold.
  // A project's identity is (repo, name) — the same forest name can exist in two repos.
  const pkey = (p: Project) => (p.repo || "loops") + " " + p.name;
  // Cross-repo "epic" clusters: same stack-project.<name>.epic tag spanning ≥2 repos folds into one
  // card at the top (ranked by its members' max interest). A single-repo epic is left in its normal
  // repo bucket — pulling one row out into a lone "cluster" would only fragment the list.
  const epicClusters = createMemo(() => {
    const byEpic = new Map<string, Project[]>();
    for (const p of filteredForests()) {
      if (!p.epic || recentlyMerged(p)) continue;
      (byEpic.get(p.epic) ?? byEpic.set(p.epic, []).get(p.epic)!).push(p);
    }
    return [...byEpic.entries()]
      .filter(([, items]) => new Set(items.map((p) => p.repo || "loops")).size >= 2)
      .map(([epic, items]) => ({
        epic,
        interest: Math.max(...items.map((p) => p.interest ?? 0)),
        items: items.sort((a, b) => forestTs(b) - forestTs(a)),
      }))
      .sort((a, b) => b.interest - a.interest || b.items.length - a.items.length);
  });
  const clusteredKeys = createMemo(() => new Set(epicClusters().flatMap((c) => c.items.map(pkey))));
  const forestGroups = createMemo(() => {
    const clustered = clusteredKeys();
    const by = new Map<string, Project[]>();
    for (const p of filteredForests()) {
      if (clustered.has(pkey(p))) continue; // shown in an epic cluster above, not under its repo header
      const r = p.repo || "loops";
      (by.get(r) ?? by.set(r, []).get(r)!).push(p);
    }
    return [...by.entries()]
      .sort(([a], [b]) => (a === "loops" ? -1 : b === "loops" ? 1 : a.localeCompare(b)))
      .map(([repo, items]) => {
        const merged = items.filter(recentlyMerged).sort((a, b) => forestTs(b) - forestTs(a));
        const active = items.filter((p) => !recentlyMerged(p));
        const levels = [...new Set(active.map((p) => p.interest ?? 0))].sort((a, b) => b - a);
        const tiers = levels.map((interest) => ({
          interest,
          // within a tier, most-recently-alive first (blended commit/PR/merge recency).
          items: active
            .filter((p) => (p.interest ?? 0) === interest)
            .sort((a, b) => forestTs(b) - forestTs(a)),
        }));
        return { repo, tiers, merged };
      });
  });
  const multiRepo = createMemo(() => forestGroups().length > 1);
  // recently-merged fold is collapsed per repo until clicked.
  const [mergedOpenSet, setMergedOpenSet] = createSignal<Set<string>>(new Set());
  const mergedOpen = (r: string) => mergedOpenSet().has(r);
  const toggleMerged = (r: string) =>
    setMergedOpenSet((s) => {
      const n = new Set(s);
      if (n.has(r)) { n.delete(r); } else { n.add(r); }
      return n;
    });
  const workCount = () => (prs.data || []).length + (reviewReqs.data || []).length;

  const review = (r?: string | null): [string, string] =>
    r === "APPROVED" ? ["✓", "ok"] : r === "CHANGES_REQUESTED" ? ["▲", "chg"] : ["•", "req"];

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

  const githubAction = (url: string, branch: string): Action => ({
    id: "gh:" + branch,
    title: "open on GitHub",
    label: () => "↗ GitHub",
    run: () => window.open(url, "_blank"),
  });
  // GitHub link only — the worktree reveal moved to the node ⋯ menu (telemetry trim:
  // ≤4 uses in 10d didn't earn a pill on every work row).
  const workRowActions = (p: PR): Action[] => [githubAction(p.url, p.branch)];

  const hasLiveChat = (p: Project) =>
    liveChats().some((j) => (j.project || j.branch) === p.name && (!j.repo || j.repo === p.repo));
  const onContext = (e: MouseEvent, p: Project) => {
    if (!canMutate) return;
    e.preventDefault();
    hideFtip();
    setCtxMenu({ x: e.clientX, y: e.clientY, repo: p.repo, project: p.name, current: p.interest ?? 0 });
  };
  const forestRow = (p: Project, folded: boolean) => (
    <ForestRow
      p={p}
      folded={folded}
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

      <Show when={tab() === "work" && needsYouPRs().length}>
        <section class="work-sec">
          <h2 class="eyebrow">needs you <span class="eyebrow-ask">— blocked or waiting on your call</span></h2>
          <div class="work-rule" />
          <For each={needsYouPRs()}>{(p) => workRow(p)}</For>
        </section>
      </Show>

      <Show when={tab() === "work" && (reviewReqs.data || []).length}>
        <section class="work-sec">
          <h2 class="eyebrow">review requests <span class="eyebrow-ask">— teammates waiting on your review</span></h2>
          <div class="work-rule" />
          <For each={reviewReqs.data}>
            {(r) => {
              const importing = () => importReview.isPending && importReview.variables === r.number;
              const body = (
                <>
                  <span class="pr-num">#{r.number}</span>
                  <span class="pr-title">{r.title}</span>
                  <span class="work-meta">@{r.author}</span>
                </>
              );
              return (
                <div class="work-row work-state-review">
                  {r.imported ? (
                    <Link class="work-link" to={{ kind: "review", pr: r.number }}>{body}</Link>
                  ) : (
                    <a class="work-link" href={r.url} target="_blank">{body}</a>
                  )}
                  {/* import is the primary act here + "on viewer ✓" is at-a-glance status, so both
                      stay visible (not folded into the hover-recessive work-acts the PR rows use). */}
                  <Show
                    when={canMutate && !r.imported}
                    fallback={<Show when={r.imported}><span class="review-on">on viewer ✓</span></Show>}
                  >
                    <button class="watch-pin review-import" disabled={importing()} onClick={() => importReview.mutate(r.number)}>
                      {importing() ? "importing…" : "import"}
                    </button>
                  </Show>
                </div>
              );
            }}
          </For>
        </section>
      </Show>

      <Show when={tab() === "work" && inFlightByProject().length}>
        <section class="work-sec">
          <h2 class="eyebrow">in flight <span class="eyebrow-ask">— your open work, by forest</span></h2>
          <div class="work-rule" />
          <For each={inFlightByProject()}>
            {([proj, list]) => {
              const v = forestVerdict(proj, list);
              return (
                <>
                  <div class={`work-forest work-state-${v.state}`}>
                    <Link class="work-forest-name" to={{ kind: "forest", name: proj }}>{proj}</Link>
                    <span class="work-verdict">{v.label}</span>
                    <Show when={forestOf(proj)}>
                      {(f) => <span class="work-meta">{f().branches} {f().branches === 1 ? "node" : "nodes"}</span>}
                    </Show>
                  </div>
                  <For each={list}>{(p) => workRow(p)}</For>
                </>
              );
            }}
          </For>
        </section>
      </Show>

      <Show when={tab() === "work" && landedPRs().length}>
        <section class="work-sec">
          <h2 class="eyebrow">just landed <span class="eyebrow-ask">— merged in the last day, then it fades</span></h2>
          <div class="work-rule" />
          <For each={landedPRs()}>{(p) => workRow(p)}</For>
        </section>
      </Show>

      <Show when={tab() === "forests"}>
      <section>
        <div class="eyebrow-row">
          <h2 class="eyebrow">forests</h2>
          <Show when={deleteMode()}>
            <span class="delete-mode-tag">
              delete mode
              <button class="delete-mode-exit" onClick={() => setDeleteMode(false)}>exit</button>
            </span>
          </Show>
          <Show when={restackErr()}>
            <span class="restack-err">{restackErr()}</span>
          </Show>
          <Show when={canMutate && (projects.data || []).some((p) => p.behind > 0)}>
            <ActionBar actions={[restackAllAction()]} />
          </Show>
        </div>
        <Show when={(projects.data || []).length > 6}>
          <input
            class="forest-search"
            placeholder="filter forests…"
            value={forestQuery()}
            onInput={(e) => setForestQuery(e.currentTarget.value)}
          />
        </Show>
        <Show
          when={filteredForests().length}
          fallback={
            <p class="loading">
              {forestQuery()
                ? `no forest matches “${forestQuery()}”`
                : "no forests configured"}
            </p>
          }
        >
          <For each={epicClusters()}>
            {(cluster) => (
              <div class="epic-cluster">
                <h3 class="epic-head" title="one effort spanning repos, linked by epic tag (advisory — each half still merges on its own main)">
                  ⇌ {cluster.epic}
                </h3>
                <For each={cluster.items}>
                  {(p) => (
                    <div class="epic-subrow">
                      <span class="epic-repo-badge">{p.repo || "loops"}</span>
                      {forestRow(p, false)}
                    </div>
                  )}
                </For>
              </div>
            )}
          </For>
          <For each={forestGroups()}>
            {(group) => (
              <>
                <Show when={multiRepo()}>
                  <h3 class="forest-repo-head">{group.repo}</h3>
                </Show>
                <For each={group.tiers}>
                  {(tier) => (
                    <>
                      <Show when={group.tiers.length > 1}>
                        <div class="forest-tier-head">
                          {tier.interest > 0 ? interestPips(tier.interest) : "no priority"}
                        </div>
                      </Show>
                      <For each={tier.items}>{(p) => forestRow(p, false)}</For>
                    </>
                  )}
                </For>
                <Show when={group.merged.length}>
                  <button class="forest-mfold" onClick={() => toggleMerged(group.repo)}>
                    {mergedOpen(group.repo) ? "▾" : "▸"} {group.merged.length} recently merged
                  </button>
                  <Show when={mergedOpen(group.repo)}>
                    <For each={group.merged}>{(p) => forestRow(p, true)}</For>
                  </Show>
                </Show>
              </>
            )}
          </For>
        </Show>
      </section>
      </Show>

      <Show when={tab() === "work" && !workCount()}>
        <p class="tab-empty">Nothing waiting on you — no open PRs or review requests.</p>
      </Show>

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
            </div>
          </>
        )}
      </Show>
    </div>
  );
}
