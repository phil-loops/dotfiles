import {
  createSignal,
  createMemo,
  createEffect,
  Show,
  For,
  onCleanup,
  type JSX,
} from "solid-js";
import {
  createQuery,
  createMutation,
  useQueryClient,
} from "@tanstack/solid-query";
import { HashRouter, Route, A, useParams, useNavigate, useSearchParams } from "@solidjs/router";
import { homePath, forestPath, nodePath } from "./routes";
import * as Diff2Html from "diff2html";
import { ColorSchemeType } from "diff2html/lib/types";
import { provider, canMutate } from "./provider";
import { deleteMode, setDeleteMode } from "./deleteMode";
import { NodeActions } from "./NodeActions";
import { ForestMap } from "./ForestMap";
import { useDiffSelection } from "./useDiffSelection";
import AskClaudeChip from "./AskClaudeChip";
import ChatPanel from "./ChatPanel";
import ChatIndex from "./ChatIndex";
import { threadMsgCount } from "./chatStore";
import { useFileCycle } from "./useFileCycle";
import CommandPalette from "./CommandPalette";
import { ServerStatus } from "./ServerStatus";
import { Hearth } from "./Hearth";
import type {
  ForestModel,
  SpineNode,
  FileDiff,
  NodeData,
  PR,
  Project,
  Standalone,
  Purpose,
  Commit,
  RestackStatus,
  Parked,
} from "./types";

const leaf = (s?: string): string => (s || "").split("/").pop() ?? "";

// Relative age of a merge, or null once it's older than a week (don't badge stale merges).
const mergedAgo = (iso?: string): string | null => {
  const t = iso ? Date.parse(iso) : NaN;
  if (!t) return null;
  const s = Math.max(0, (Date.now() - t) / 1000);
  if (s > 7 * 86400) return null;
  if (s < 90) return "just now";
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  if (s < 86400) return `${Math.round(s / 3600)}h ago`;
  return `${Math.round(s / 86400)}d ago`;
};
const isBlessed = (f: FileDiff): boolean =>
  f.status === "clean" || f.status === "blessed";

function flattenForest(model: ForestModel | undefined): SpineNode[] {
  if (!model) return [];
  const nodes = model.nodes;
  if (nodes) {
    const out: SpineNode[] = [];
    const seen = new Set<string>();
    const walk = (b: string, d: number) => {
      if (seen.has(b)) return;
      seen.add(b);
      const n = nodes[b];
      if (!n) return;
      out.push({ ...n, id: b, depth: d });
      (n.children || []).forEach((c) => walk(c, d + 1));
    };
    (model.roots || []).forEach((r) => walk(r, 0));
    Object.keys(nodes).forEach((b) => !seen.has(b) && walk(b, 0));
    return out;
  }
  return (model.links || []).map(
    (l) => ({ ...l, id: l.branch, depth: 0 }) as unknown as SpineNode
  );
}
// ── router ───────────────────────────────────────────────────────────
export default function App() {
  return (
    <HashRouter root={Layout}>
      <Route path="/" component={Home} />
      <Route path="/*forest" component={NodeDetail} />
    </HashRouter>
  );
}

// Persistent chrome that survives route changes: the SSE stream, the command
// palette, and the server-status pill. The matched route renders as props.children.
function Layout(props: { children?: JSX.Element }) {
  const qc = useQueryClient();
  // /events is a persistent SSE stream and the browser only allows ~6 connections per origin
  // (HTTP/1.1) — so a graveyard of idle tabs each squatting a stream exhausts the pool and new
  // loads hang. Hold the stream ONLY while the tab is visible: a backgrounded tab closes it
  // (frees its slot), and re-opening on show refetches to catch up on anything missed.
  let es: EventSource | null = null;
  const refresh = () => {
    qc.invalidateQueries({ queryKey: ["node"] });
    qc.invalidateQueries({ queryKey: ["model"] });
    qc.invalidateQueries({ queryKey: ["projects"] });
  };
  const openStream = () => {
    if (!canMutate || es) return; // static snapshot: no live event stream
    es = new EventSource("/events");
    es.addEventListener("update", refresh);
  };
  const closeStream = () => {
    es?.close();
    es = null;
  };
  const onVisibility = () => {
    if (document.hidden) {
      closeStream();
    } else {
      openStream();
      refresh(); // we may have missed updates while hidden
    }
  };
  if (!document.hidden) openStream();
  document.addEventListener("visibilitychange", onVisibility);
  onCleanup(() => {
    document.removeEventListener("visibilitychange", onVisibility);
    closeStream();
  });

  return (
    <>
      {props.children}
      <CommandPalette />
      <ServerStatus />
    </>
  );
}

// ── home: the ledger summary ─────────────────────────────────────────
function Home() {
  const prs = createQuery(() => ({
    queryKey: ["myprs"],
    queryFn: () => provider.myPrs(),
  }));
  const projects = createQuery(() => ({
    queryKey: ["projects"],
    queryFn: () => provider.projects(),
  }));
  const checkOrigin = createMutation(() => ({
    mutationFn: () => fetch("/check-origin", { method: "POST", body: "{}" }).then((r) => r.json()),
    onSuccess: () => {
      prs.refetch();
      projects.refetch();
    },
  }));

  // ── restack: two-click arm → run (background) → poll → parked? hand to Claude ──
  const [armed, setArmed] = createSignal<string | null>(null); // project (or "__all__") awaiting confirm
  const [running, setRunning] = createSignal<string | null>(null); // project (or "__all__") restacking now
  const [parked, setParked] = createSignal<Parked | null>(null); // set on a conflict
  const [restackErr, setRestackErr] = createSignal<string | null>(null);
  const [menu, setMenu] = createSignal<string | null>(null); // project whose parked-action popover is open
  let armT: ReturnType<typeof setTimeout>;
  const post = (url: string, body: unknown): Promise<{ ok?: boolean; err?: string }> =>
    fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }).then((r) => r.json());
  const behindNames = () => (projects.data || []).filter((p) => p.behind > 0).map((p) => p.name);
  const start = (key: string) => {
    setRestackErr(null);
    // restack-all clears any pre-existing park first (server frees the worktree, then the
    // resilient walk restacks the rest); a single-project restack never auto-drops a park.
    const body =
      key === "__all__"
        ? { projects: behindNames(), abortParked: !!parked() }
        : { project: key };
    post(key === "__all__" ? "/restack-all" : "/restack", body).then((r) => {
      if (r.ok) {
        setParked(null);
        setRunning(key);
      } else {
        // Don't swallow it — a stale park 409s here; surface why + refresh so the parked
        // branch's contextual button appears on its row.
        setRestackErr(r.err ?? "couldn’t start restack");
        homeStatus.refetch();
      }
    });
  };
  const abort = (project: string) =>
    post("/restack-abort", { project }).then((r) => {
      if (r.ok) {
        setParked(null);
        setRestackErr(null);
        setMenu(null);
        projects.refetch();
        homeStatus.refetch();
      } else {
        setRestackErr(r.err ?? "couldn’t abort");
      }
    });
  const arm = (key: string, confirm: () => void = () => start(key)) => {
    if (armed() === key) {
      clearTimeout(armT);
      setArmed(null);
      confirm();
      return;
    }
    setArmed(key);
    clearTimeout(armT);
    armT = setTimeout(() => setArmed(null), 3000);
  };

  // ── delete mode: forget an old forest grouping (config only; branches kept) ──
  const [dropping, setDropping] = createSignal<string | null>(null);
  const dropProject = (project: string) => {
    setDropping(project);
    post("/drop-project", { project }).then((r) => {
      setDropping(null);
      if (r.ok) {
        projects.refetch();
        prs.refetch();
      } else {
        setRestackErr(r.err ?? "couldn’t drop forest");
      }
    });
  };
  onCleanup(() => setDeleteMode(false)); // leaving home always exits delete mode
  const status = createQuery(() => ({
    queryKey: ["restack-status", running()],
    queryFn: () =>
      provider.restackStatus(
        running() && running() !== "__all__" ? running()! : undefined
      ),
    enabled: !!running(),
    refetchInterval: (q) => (q.state.data?.running === false ? false : 2500),
  }));
  createEffect(() => {
    if (!running()) return;
    const d = status.data;
    if (!d || d.running) return; // still churning through the topo walk
    if (d.paused)
      setParked({ project: d.project ?? "", current: d.current ?? "", reason: d.reason ?? "" });
    setRunning(null);
    projects.refetch();
  });
  const resolve = (project: string) =>
    post("/restack-resolve", { project }).then((r) => {
      if (r.ok) {
        setParked(null);
        setMenu(null);
        setRunning(project); // re-poll while Claude resolves + resumes
      }
    });
  // Surface a parked conflict on the home screen even when nothing is running — without
  // this a stale park silently 409s every restack with no clue which branch is stuck.
  const homeStatus = createQuery(() => ({
    queryKey: ["home-restack-status"],
    queryFn: () => provider.restackStatus(),
    refetchInterval: 5000,
  }));
  createEffect(() => {
    if (running()) return; // the running-restack effect owns `parked` mid-walk
    const d = homeStatus.data;
    if (!d) return;
    setParked(
      d.paused ? { project: d.project ?? "", current: d.current ?? "", reason: d.reason ?? "" } : null
    );
  });

  // ── watching: opt-in pinned loose branches (git config stack.standalone) ──
  // Not auto-discovery — branches you deliberately pin to keep an eye on. /branches
  // (the typeahead source, ~all local heads) is heavy, so only fetch it while adding.
  const standalone = createQuery(() => ({
    queryKey: ["standalone"],
    queryFn: () => provider.standalone(),
  }));
  const [adding, setAdding] = createSignal(false);
  const [pick, setPick] = createSignal("");
  const branches = createQuery(() => ({
    queryKey: ["branches"],
    queryFn: () => provider.branches(),
    enabled: adding(),
  }));
  const pin = createMutation(() => ({
    mutationFn: (body: { branch: string; op?: string }) => post("/standalone", body),
    onSuccess: () => { standalone.refetch(); branches.refetch(); },
  }));
  const submitPin = () => {
    const b = pick().trim();
    if (!b) return;
    pin.mutate({ branch: b });
    setPick("");
    setAdding(false);
  };

  const byProject = createMemo<[string, PR[]][]>(() => {
    const m = new Map<string, PR[]>();
    for (const p of prs.data || []) {
      const k = p.project || "—";
      if (!m.has(k)) m.set(k, []);
      m.get(k)!.push(p);
    }
    return [...m.entries()];
  });

  // a PR'd forest shows its forest meta UP in its "your open PRs" group, so it drops out
  // of the FORESTS list entirely — no duplicate listing across the two sections.
  const prProjects = createMemo(() => new Set((prs.data || []).map((p) => p.project).filter(Boolean)));
  const nonPrProjects = createMemo(() => (projects.data || []).filter((p) => !prProjects().has(p.name)));
  const forestOf = (name: string): Project | undefined => (projects.data || []).find((p) => p.name === name);

  const review = (r?: string | null): [string, string] =>
    r === "APPROVED" ? ["✓", "ok"] : r === "CHANGES_REQUESTED" ? ["▲", "chg"] : ["•", "req"];

  return (
    <div class="home">
      <header class="home-head">
        <div class="brand big">
          <span class="brand-mark">✦</span> blessed
        </div>
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

      <Show when={(prs.data || []).length}>
        <section>
          <h2 class="eyebrow">your open PRs</h2>
          <For each={byProject()}>
            {([proj, list]) => (
              <div class="pr-group">
                <div class="pr-project">
                  <Show when={forestOf(proj)} fallback={proj}>
                    {(f) => (
                      <>
                        <A class="pr-project-link" href={forestPath(proj)}>{proj}</A>
                        <span class="forest-meta">
                          {" · "}{f().branches} {f().branches === 1 ? "node" : "nodes"}{" · "}
                          <span class={f().behind > 0 ? "forest-fresh behind" : "forest-fresh fresh"}>
                            {f().behind > 0 ? `↻ ${f().behind} behind` : "✦ fresh"}
                          </span>
                          <Show when={f().merged && mergedAgo(f().merged!.at)}>
                            {(rel) => (
                              <span class="forest-merged" title={f().merged!.title}>
                                {" · "}✨ merged {rel()} (#{f().merged!.pr})
                              </span>
                            )}
                          </Show>
                        </span>
                      </>
                    )}
                  </Show>
                </div>
                <For each={list}>
                  {(p) => {
                    const [mark, cls] = review(p.review);
                    const inner = () => (
                      <>
                        <span class="pr-num">#{p.num}</span>
                        <span class="pr-title">{p.title}</span>
                        {p.draft && <span class="pr-draft">draft</span>}
                        <span class={`pr-rev ${cls}`}>{mark}</span>
                      </>
                    );
                    // forest-backed PRs route in-app; a bare PR opens GitHub in a new tab.
                    return p.project ? (
                      <A class="pr-row" href={nodePath(p.project, p.branch)}>
                        {inner()}
                      </A>
                    ) : (
                      <a class="pr-row" href={p.url} target="_blank">
                        {inner()}
                      </a>
                    );
                  }}
                </For>
              </div>
            )}
          </For>
        </section>
      </Show>

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
            <button
              class="restack-all"
              classList={{ armed: armed() === "__all__", running: running() === "__all__" }}
              onClick={() => running() !== "__all__" && arm("__all__")}
            >
              {running() === "__all__"
                ? "⤳ restacking all…"
                : armed() === "__all__"
                  ? parked()
                    ? `drop parked ${leaf(parked()!.project)} & restack all?`
                    : "restack all behind?"
                  : `⟳ restack all ${behindNames().length} behind`}
            </button>
          </Show>
        </div>
        <Show
          when={nonPrProjects().length}
          fallback={
            <p class="loading">
              {(projects.data || []).length ? "every forest has an open PR ✦" : "no forests configured"}
            </p>
          }
        >
          <For each={nonPrProjects()}>
            {(p) => {
              const busy = () => running() === p.name || running() === "__all__";
              const stuck = () => parked()?.project === p.name;
              return (
                <A
                  class="forest-row"
                  classList={{ parked: stuck() }}
                  href={forestPath(p.name)}
                >
                  <span
                    class={`forest-dot ${stuck() ? "parked" : p.behind > 0 ? "behind" : "fresh"}`}
                  />
                  <span class="forest-name">{p.name}</span>
                  <span class="forest-meta">
                    {p.branches} {p.branches === 1 ? "node" : "nodes"}
                  </span>
                  <Show when={p.merged && mergedAgo(p.merged.at)}>
                    {(rel) => (
                      <span class="forest-merged" title={p.merged!.title}>
                        ✨ merged {rel()} (#{p.merged!.pr})
                      </span>
                    )}
                  </Show>
                  <Show
                    when={deleteMode() && canMutate}
                    fallback={
                  <Show
                    when={stuck()}
                    fallback={
                      <Show
                        when={p.behind > 0}
                        fallback={<span class="forest-fresh fresh">✦ fresh</span>}
                      >
                        <Show
                          when={canMutate}
                          fallback={<span class="forest-meta">⟳ {p.behind} behind</span>}
                        >
                          <button
                            class="forest-restack"
                            classList={{ armed: armed() === p.name, running: busy() }}
                            onClick={(e) => {
                              e.preventDefault();
                              e.stopPropagation();
                              if (!busy()) arm(p.name);
                            }}
                          >
                            {busy()
                              ? "⤳ restacking…"
                              : armed() === p.name
                                ? "restack?"
                                : `⟳ ${p.behind} behind`}
                          </button>
                        </Show>
                      </Show>
                    }
                  >
                    <div class="forest-parked">
                      <button
                        class="forest-resolve"
                        classList={{ open: menu() === p.name }}
                        onClick={(e) => {
                          e.preventDefault();
                          e.stopPropagation();
                          setMenu(menu() === p.name ? null : p.name);
                        }}
                      >
                        ⚠ parked at {leaf(parked()?.current || p.name)}
                      </button>
                      <Show when={menu() === p.name}>
                        <div
                          class="forest-popover"
                          onClick={(e) => {
                            e.preventDefault();
                            e.stopPropagation();
                          }}
                        >
                          <p class="forest-popover-why">
                            Rebase paused on a conflict
                            {parked()?.current ? ` rebasing ${leaf(parked()!.current)}` : ""}. It holds a
                            worktree and blocks restacks until it’s cleared.
                          </p>
                          <Show when={parked()?.reason}>
                            {(r) => <p class="forest-popover-reason">{r()}</p>}
                          </Show>
                          <div class="forest-popover-actions">
                            <button
                              onClick={(e) => {
                                e.preventDefault();
                                e.stopPropagation();
                                resolve(p.name);
                              }}
                            >
                              ✦ resolve with Claude
                            </button>
                            <button
                              class="danger"
                              onClick={(e) => {
                                e.preventDefault();
                                e.stopPropagation();
                                abort(p.name);
                              }}
                            >
                              ✕ abort & discard
                            </button>
                          </div>
                        </div>
                      </Show>
                    </div>
                  </Show>
                    }
                  >
                    <button
                      class="forest-drop"
                      classList={{ armed: armed() === p.name, running: dropping() === p.name }}
                      onClick={(e) => {
                        e.preventDefault();
                        e.stopPropagation();
                        if (dropping() !== p.name) arm(p.name, () => dropProject(p.name));
                      }}
                    >
                      {dropping() === p.name
                        ? "⌫ dropping…"
                        : armed() === p.name
                          ? "drop forest?"
                          : "✕ drop"}
                    </button>
                  </Show>
                </A>
              );
            }}
          </For>
        </Show>
      </section>

      <section>
        <div class="eyebrow-row">
          <h2 class="eyebrow">watching</h2>
          <Show when={canMutate}>
            <button class="watch-add" onClick={() => setAdding((v) => !v)}>
              {adding() ? "× cancel" : "+ watch a branch"}
            </button>
          </Show>
        </div>
        <Show when={adding()}>
          <div class="watch-pick">
            <input
              class="watch-input"
              list="watch-branches"
              placeholder="branch name…"
              value={pick()}
              onInput={(e) => setPick(e.currentTarget.value)}
              onKeyDown={(e) => e.key === "Enter" && submitPin()}
              autofocus
            />
            <datalist id="watch-branches">
              <For each={branches.data || []}>{(b) => <option value={b} />}</For>
            </datalist>
            <button class="watch-pin" disabled={!pick().trim()} onClick={submitPin}>
              pin
            </button>
          </div>
        </Show>
        <Show
          when={(standalone.data || []).length}
          fallback={<p class="loading">nothing pinned — watch a loose branch to track it here</p>}
        >
          <For each={standalone.data}>
            {(b) => (
              <div class="watch-row">
                <A class="watch-link" href={forestPath(b.branch)}>
                  <span class="watch-dot" />
                  <span class="watch-name">{b.branch}</span>
                  <span class="watch-meta">
                    <span>{b.commits} {b.commits === 1 ? "commit" : "commits"}</span>
                    <span class="watch-add-n">+{b.add}</span>
                    <span class="watch-del-n">−{b.del}</span>
                  </span>
                </A>
                <Show when={canMutate}>
                  <button
                    class="watch-unpin"
                    title="stop watching"
                    onClick={() => pin.mutate({ branch: b.branch, op: "remove" })}
                  >
                    ×
                  </button>
                </Show>
              </div>
            )}
          </For>
        </Show>
      </section>
    </div>
  );
}

// ── node detail: forest spine + review surface ───────────────────────
function NodeDetail() {
  const qc = useQueryClient();
  const params = useParams<{ forest: string }>();
  const [search] = useSearchParams<{ node?: string }>();
  const navigate = useNavigate();
  const project = () => params.forest;

  const model = createQuery(() => ({
    queryKey: ["model", project()],
    queryFn: () => provider.model(project()),
    enabled: !!project(),
  }));
  const spine = createMemo(() => flattenForest(model.data));
  const active = () => search.node || spine()[0]?.id || project();
  const parentOf = () => model.data?.nodes?.[active()]?.parent;

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

  const node = createQuery(() => ({
    queryKey: ["node", active(), base()],
    queryFn: () => provider.node(active(), base() || undefined),
    enabled: !!active(),
  }));
  const commits = createQuery(() => ({
    queryKey: ["commits", active()],
    queryFn: () => provider.commits(active()),
    enabled: !!active() && view() === "commits",
  }));

  const bless = createMutation(() => ({
    mutationFn: (file: string) =>
      fetch("/bless", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ branch: active(), file }),
      }).then((r) => r.json()),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["node", active()] });
      qc.invalidateQueries({ queryKey: ["model"] });
    },
  }));

  const goto = (b: string) => navigate(nodePath(project(), b));
  const BASES: [string, string][] = [["", "parent"], ["main", "main"], ["blessed", "last blessed"]];
  const [showMap, setShowMap] = createSignal(false);
  // chat drawer target: a file's diff, or the whole branch ({ file: null }). null = closed.
  const [chat, setChat] = createSignal<{ file: FileDiff | null } | null>(null);
  // cross-forest chat index overlay (read-only; every thread in this browser).
  const [showChats, setShowChats] = createSignal(false);

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
      ?.scrollIntoView({ behavior: "smooth", block: "start" });
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

  // sweep-select diff text → floating "ask Claude" chip → POST /claude. Attributes selected
  // rows to a file via each .entry's existing data-path (see useDiffSelection).
  const { selection: claudeSel, clear: clearClaudeSel } = useDiffSelection();

  // hover a spine node → float its branch purpose (the one-line thesis) beside it.
  // Purposes are cheap + immutable for a session, so cache by branch and guard the
  // async gap (if the pointer left before /purpose resolved, don't pop a stale tip).
  const purposeCache = new Map<string, Purpose>();
  const [tip, setTip] = createSignal<{ text: string; x: number; y: number } | null>(null);
  let tipBranch: string | null = null;
  const showTip = async (branch: string, el: HTMLElement) => {
    tipBranch = branch;
    let p = purposeCache.get(branch);
    if (!p) {
      try { p = await provider.purpose(branch); }
      catch { p = { thesis: "" }; }
      purposeCache.set(branch, p);
    }
    if (tipBranch !== branch || !p.thesis) return;
    const r = el.getBoundingClientRect();
    setTip({ text: p.thesis, x: r.right + 12, y: r.top });
  };
  const hideTip = () => { tipBranch = null; setTip(null); };

  // hover a diff line + press o (or click the gutter #) → open that exact line in the warm
  // review-nvim. Event-delegated off the surface so it works on diff2html's raw HTML.
  const [hover, setHover] = createSignal<{ path: string; line: number } | null>(null);
  const [flash, setFlash] = createSignal("");
  let flashT: ReturnType<typeof setTimeout>;
  const note = (m: string) => { setFlash(m); clearTimeout(flashT); flashT = setTimeout(() => setFlash(""), 1900); };
  const openInNvim = (path: string, line: number | null) =>
    !canMutate
      ? undefined // static snapshot: no live nvim to open into
      : fetch("/open", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ branch: active(), path, ...(line != null ? { pos: String(line) } : {}) }),
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

  // keyboard: j/k walk the spine; 1/2/3 switch the diff base; m toggles the forest map.
  const onKey = (e: KeyboardEvent) => {
    if ((e.target as Element).matches("input, textarea, [contenteditable]")) return;
    const list = spine();
    const i = list.findIndex((n) => n.id === active());
    if (e.key === "j" && i < list.length - 1) { e.preventDefault(); goto(list[i + 1].id); }
    else if (e.key === "k" && i > 0) { e.preventDefault(); goto(list[i - 1].id); }
    else if (e.key === "1") setBase("");
    else if (e.key === "2") setBase("main");
    else if (e.key === "3") setBase("blessed");
    else if (e.key === "m") setShowMap((v) => !v);
    else if (e.key === "Escape") setShowMap(false);
    else if (e.key === "o" && hover()) { e.preventDefault(); const h = hover()!; openInNvim(h.path, h.line); }
    else if (e.key === "c") setView((v) => (v === "commits" ? "diffs" : "commits"));
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

  return (
    <div class="shell">
      <aside class="spine">
        <A class="brand" href={homePath()}>
          <span class="brand-mark">✦</span> blessed
        </A>
        <Show when={spine().length} fallback={<div class="spine-empty">{project()}</div>}>
          {/* current branch as a header; click → forest map to switch (also j/k, m) */}
          <button
            class="spine-branch"
            onClick={() => setShowMap(true)}
            onMouseEnter={(e) => showTip(active(), e.currentTarget)}
            onMouseLeave={hideTip}
            title="switch branch — forest map (m), or j/k"
          >
            <span class="spine-branch-name">{leaf(active())}</span>
            <span class="spine-branch-switch">⊞</span>
          </button>
          <Show when={node.data} fallback={<div class="spine-meta">loading…</div>}>
            {(data) => (
              <>
                <div class="spine-meta">
                  {data().files.filter(isBlessed).length}/{data().files.length} files blessed
                </div>
                <Show
                  when={data().files.length}
                  fallback={<div class="spine-empty">nothing to review</div>}
                >
                  <ul class="file-list">
                    <For each={data().files}>
                      {(f) => (
                        <li
                          class="file-item"
                          classList={{ blessed: isBlessed(f), active: activeFile() === f.path }}
                          onClick={() => scrollToFile(f.path)}
                          title={f.path}
                        >
                          <span class={`dot ${isBlessed(f) ? "blessed" : "unblessed"}`} />
                          <span class="file-item-name">{fileSeg(f.path)}</span>
                          <span class="file-item-lines">
                            <span class="add">+{f.add ?? 0}</span>
                            <span class="del">−{f.del ?? 0}</span>
                          </span>
                        </li>
                      )}
                    </For>
                  </ul>
                </Show>
              </>
            )}
          </Show>
        </Show>
      </aside>

      <main
        class="surface"
        onMouseOver={(e) => {
          const h = lineAt(e);
          // clear when off any row so `o` can't fire on a stale line; dedup to avoid churn
          setHover((prev) => (prev?.path === h?.path && prev?.line === h?.line ? prev : h));
        }}
        onMouseLeave={() => setHover(null)}
        onClick={(e) => {
          const h = lineAt(e);
          if (h) openInNvim(h.path, h.line);
        }}
      >
        <header class="node-head">
          {/* tier 1 — identity: the branch name + what it's diffed against, nothing else.
              Giving this its own line stops the long title from wrapping into the controls. */}
          <div class="nh-id">
            <h1>{leaf(active()) || "—"}</h1>
            <Show when={parentOf()}>
              <span class="against">◂ {leaf(parentOf())}</span>
            </Show>
          </div>
          {/* tier 2 — controls: view switches on the left, branch state + actions on the right.
              The blessed count lives in the spine; the map opens from the spine + `m`. */}
          <div class="nh-bar">
            <div class="view-toggle">
              <button class="view-pill" classList={{ on: view() === "diffs" }} onClick={() => setView("diffs")}>
                diffs
              </button>
              <button class="view-pill" classList={{ on: view() === "commits" }} onClick={() => setView("commits")}>
                commits
              </button>
            </div>
            <Show when={view() === "diffs"}>
              <div class="base-toggle">
                <span class="base-label">diff vs</span>
                <For each={BASES}>
                  {([v, lab]) => (
                    <button class="base-pill" classList={{ on: base() === v }} onClick={() => setBase(v)}>
                      {lab}
                    </button>
                  )}
                </For>
              </div>
            </Show>
            <div class="nh-spacer" />
            <NodeActions branch={active()} />
            <Show when={canMutate}>
              <button class="icon-btn" onClick={() => setChat({ file: null })} title="chat about this whole branch">
                ✦
              </button>
            </Show>
            <button class="icon-btn" onClick={() => setShowChats(true)} title="all chat threads across the forest">
              💬
            </button>
          </div>
        </header>
        <Show when={view() === "diffs"} fallback={<CommitsList q={commits} />}>
          <div class="diff-hint">
            <span class="kbd-hint"><b>tab</b> next file · hover a line · <b>o</b> → nvim</span>
          </div>
          <Show when={node.data} fallback={<p class="loading">loading…</p>}>
            {(data) => (
              <Show when={data().files.length} fallback={<p class="loading">nothing to review here ✦</p>}>
                <For each={data().files}>
                  {(f) => <FileEntry file={f} bless={bless} branch={active()} onChat={(file) => setChat({ file })} />}
                </For>
              </Show>
            )}
          </Show>
        </Show>
      </main>
      <Show when={canMutate}>
        <AskClaudeChip selection={claudeSel} branch={active} onClear={clearClaudeSel} />
      </Show>
      <Show when={canMutate && chat()}>
        {(c) => <ChatPanel file={c().file} branch={active()} onClose={() => setChat(null)} />}
      </Show>
      <Show when={showChats()}>
        <ChatIndex onClose={() => setShowChats(false)} />
      </Show>
      <Show when={showMap()}>
        <ForestMap
          spine={spine}
          active={active}
          onPick={(b) => {
            goto(b);
            setShowMap(false);
          }}
          onClose={() => setShowMap(false)}
        />
      </Show>
      <Show when={flash()}>
        <div class="flash">{flash()}</div>
      </Show>
      <Show when={tip()}>
        {(t) => (
          <div class="purpose-tip" style={{ left: `${t().x}px`, top: `${t().y}px` }}>
            {t().text}
          </div>
        )}
      </Show>
    </div>
  );
}

function FileEntry(props: {
  file: FileDiff;
  bless: { mutate: (file: string) => void };
  branch: string;
  onChat: (f: FileDiff) => void;
}) {
  const [foil, setFoil] = createSignal(false);
  const [copied, setCopied] = createSignal(false);
  const blessed = () => isBlessed(props.file);
  const doBless = () => {
    setFoil(true); // play the foil on the click — feels instant; the steady gold lands on refetch
    props.bless.mutate(props.file.path);
    setTimeout(() => setFoil(false), 750);
  };
  // Copy a paste-ready reference for dropping the file into a Claude conversation.
  const copyRef = async () => {
    try {
      await navigator.clipboard.writeText(`\`${props.file.path}\` (on branch \`${props.branch}\`)`);
      setCopied(true);
      setTimeout(() => setCopied(false), 1200);
    } catch {
      /* clipboard blocked (insecure origin / denied) — silently no-op */
    }
  };
  const html = () =>
    props.file.patch
      ? Diff2Html.html(props.file.patch, {
          drawFileList: false,
          outputFormat: "side-by-side",
          matching: "lines",
          colorScheme: ColorSchemeType.DARK,
        })
      : `<p class="empty">no textual diff</p>`;
  const seg = (p: string): JSX.Element => {
    const i = p.lastIndexOf("/");
    return i < 0 ? <b>{p}</b> : [<span class="dir">{p.slice(0, i + 1)}</span>, <b>{p.slice(i + 1)}</b>];
  };
  return (
    <article class="entry" data-path={props.file.path} classList={{ blessed: blessed(), foil: foil() }}>
      <div class="entry-head">
        <span class="gutter">{blessed() || foil() ? "✦" : ""}</span>
        <span class="path">{seg(props.file.path)}</span>
        <span class="lines">
          <span class="add">+{props.file.add ?? 0}</span>
          <span class="del">−{props.file.del ?? 0}</span>
        </span>
        <button
          class="file-act"
          title="copy a paste-ready file + branch reference for a Claude conversation"
          onClick={copyRef}
        >
          {copied() ? "copied ✓" : "⎘ copy ref"}
        </button>
        <Show when={threadMsgCount(props.branch, props.file.path) > 0}>
          <span class="chat-badge" title="this file has a chat thread">
            💬 {threadMsgCount(props.branch, props.file.path)}
          </span>
        </Show>
        <Show when={canMutate}>
          <button
            class="file-act"
            title="chat about this file with Claude — streamed right here"
            onClick={() => props.onChat(props.file)}
          >
            ✦ chat
          </button>
          <button class="bless-btn" disabled={blessed()} onClick={doBless}>
            {blessed() ? "blessed" : "bless ✦"}
          </button>
        </Show>
      </div>
      <div class="diff" innerHTML={html()} />
    </article>
  );
}

function CommitsList(props: { q: { data: Commit[] | undefined } }) {
  return (
    <Show when={props.q.data} fallback={<p class="loading">loading…</p>}>
      {(data) => (
        <Show
          when={data().length}
          fallback={<p class="loading">no commits on this branch</p>}
        >
          <ol class="commits">
            <For each={data()}>
              {(c) => (
                <li class="commit">
                  <span class="c-sha">{c.sha}</span>
                  <span class="c-subject">{c.subject}</span>
                  <span class="c-meta">{c.author} · {c.date}</span>
                </li>
              )}
            </For>
          </ol>
        </Show>
      )}
    </Show>
  );
}
