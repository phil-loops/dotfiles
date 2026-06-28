import { createSignal, createMemo, createEffect, onCleanup, Show, For } from "solid-js";
import { createQuery } from "@tanstack/solid-query";
import { provider, canMutate } from "./provider";
import { deleteMode, setDeleteMode } from "./deleteMode";
import { track } from "./track";
import { useViewerLocation, forestKey, withNode, forestRepo } from "./router";
import { setOverviewView } from "./overviewView";

// CommandPalette — Cmd/Ctrl+K fuzzy command bar. Its highest-value job is jumping around the
// forest by name (type a branch → Enter → you're there); it also carries a few safe global
// commands. Deliberately NO "bless" command — blessing is earned per-file in the diff view
// (bulk-bless is banned house-wide). Standalone, self-styled; mount once in App.
//
// Context comes from the router: the splat path is the forest, ?node= the node.
// With a forest open it lists that forest's nodes; on the home screen it lists the forests.

type Cmd = { label: string; sub?: string; run: () => void };

const leaf = (s: string) => (s || "").split("/").pop() ?? "";
const post = (url: string, body: unknown) =>
  fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });

export default function CommandPalette() {
  const [open, setOpen] = createSignal(false);
  const [q, setQ] = createSignal("");
  const [sel, setSel] = createSignal(0);
  const { location, navigate } = useViewerLocation();
  // forestKey = the server's branch/project name for the current location; node = active branch.
  const ctx = createMemo(() => {
    const l = location();
    return { project: forestKey(l), node: l.kind === "home" || l.kind === "push" ? "" : l.node || "" };
  });
  let inputRef: HTMLInputElement | undefined;

  const onKey = (e: KeyboardEvent) => {
    if ((e.metaKey || e.ctrlKey) && (e.key === "k" || e.key === "K")) {
      e.preventDefault();
      setQ("");
      setSel(0);
      setOpen((v) => !v);
    } else if (e.key === "Escape" && open()) {
      setOpen(false);
    }
  };
  window.addEventListener("keydown", onKey);
  onCleanup(() => window.removeEventListener("keydown", onKey));

  // forest nodes (when a forest is open) — shares App's ["model", project] cache, no extra fetch
  const model = createQuery(() => ({
    queryKey: ["model", ctx().project],
    queryFn: () => provider.model(ctx().project),
    enabled: open() && !!ctx().project,
  }));
  // forests (on the home screen) — shares App's ["projects"] cache
  const projects = createQuery(() => ({
    queryKey: ["projects"],
    queryFn: () => provider.projects(),
    enabled: open() && !ctx().project,
  }));
  // every (branch, forest) pair across all projects — the global jump index, always on so
  // you can search any branch by name from anywhere (home or a different forest).
  const forestBranches = createQuery(() => ({
    queryKey: ["forest-branches"],
    queryFn: () => provider.forestBranches(),
    enabled: open(),
  }));

  const commands = createMemo<Cmd[]>(() => {
    const c = ctx();
    const cmds: Cmd[] = [];
    if (c.project && canMutate) {
      cmds.push({
        label: `⟳ restack ${leaf(c.project)} onto fresh main`,
        run: () => void post("/restack", { project: c.project }),
      });
    }
    if (c.project) {
      cmds.push({
        label: `≣ merge story — ${leaf(c.project)}`,
        sub: "the feature as ordered commits, in merge order",
        run: () => { setOverviewView("story"); navigate({ kind: "forest", name: c.project, repo: forestRepo(location()) }); },
      });
    } else {
      cmds.push({
        label: "≣ merge story view",
        sub: "open forests as ordered commits",
        run: () => setOverviewView("story"),
      });
    }
    cmds.push({
      label: "↪ jump to checkout (HEAD)",
      run: async () => {
        try {
          const h = await provider.head();
          if (!h.branch) return;
          const l = location();
          navigate(l.kind === "home" ? { kind: "forest", name: h.branch } : withNode(l, h.branch));
        } catch {
          /* head unavailable — no-op */
        }
      },
    });
    cmds.push({ label: "⌂ home — all forests", run: () => navigate({ kind: "home", tab: "forests" }) });
    // Home only: flip the forest list into drop mode (each row grows a ✕ drop button).
    if (!c.project && canMutate) {
      cmds.push({
        label: deleteMode() ? "⌫ exit delete mode" : "⌫ delete mode — drop old forests",
        run: () => setDeleteMode((v) => !v),
      });
    }

    if (c.project) {
      const nodes = model.data?.nodes ? Object.keys(model.data.nodes) : [];
      for (const b of nodes) {
        cmds.push({ label: `→ ${leaf(b)}`, sub: b, run: () => navigate(withNode(location(), b)) });
      }
    } else {
      for (const p of projects.data || []) {
        cmds.push({ label: `→ ${p.name}`, sub: p.repo !== "loops" ? p.repo : "forest", run: () => navigate({ kind: "forest", name: p.name, repo: p.repo, node: p.repo !== "loops" ? p.mergeable?.[0] : undefined }) });
      }
    }

    // global branch index: jump to ANY branch in ANY forest by name. Skip the open forest's
    // own branches — those are already listed above from the live model, the source of truth.
    const shown = c.project ? new Set(model.data?.nodes ? Object.keys(model.data.nodes) : []) : new Set<string>();
    for (const fb of forestBranches.data || []) {
      if (fb.project === c.project || shown.has(fb.branch)) continue;
      cmds.push({
        label: `→ ${fb.branch}`,
        sub: fb.repo !== "loops" ? `${fb.repo}/${fb.project}` : fb.project,
        run: () => navigate({ kind: "forest", name: fb.project, node: fb.branch, repo: fb.repo }),
      });
    }
    return cmds;
  });

  const filtered = createMemo<Cmd[]>(() => {
    const needle = q().toLowerCase().trim();
    const list = commands();
    if (!needle) return list;
    // simple subsequence-friendly contains match on label+sub
    return list.filter((c) => (c.label + " " + (c.sub || "")).toLowerCase().includes(needle));
  });

  createEffect(() => {
    const n = filtered().length;
    if (sel() >= n) setSel(Math.max(0, n - 1));
  });
  createEffect(() => {
    if (open()) queueMicrotask(() => inputRef?.focus());
  });

  const run = (c?: Cmd) => {
    setOpen(false);
    // a query typed but Enter hit with no match = "I wanted something that isn't here" —
    // the highest-signal friction event in the whole log.
    if (c) {
      track("cmd", { q: q(), label: c.label, sub: c.sub });
    } else if (q().trim()) {
      track("cmd_miss", { q: q() });
    }
    c?.run();
  };

  const onInputKey = (e: KeyboardEvent) => {
    const n = filtered().length;
    if (e.key === "ArrowDown") { e.preventDefault(); setSel((s) => Math.min(n - 1, s + 1)); }
    else if (e.key === "ArrowUp") { e.preventDefault(); setSel((s) => Math.max(0, s - 1)); }
    else if (e.key === "Enter") { e.preventDefault(); run(filtered()[sel()]); }
    else if (e.key === "Escape") { e.preventDefault(); setOpen(false); }
  };

  return (
    <>
      <style>{CMDK_CSS}</style>
      <Show when={open()}>
        <div class="cmdk-backdrop" onClick={(e) => { if (e.target === e.currentTarget) setOpen(false); }}>
          <div class="cmdk-panel">
            <input
              ref={inputRef}
              class="cmdk-input"
              placeholder="jump to a branch, or a command…"
              value={q()}
              onInput={(e) => { setQ(e.currentTarget.value); setSel(0); }}
              onKeyDown={onInputKey}
            />
            <ul class="cmdk-list">
              <Show when={filtered().length} fallback={<li class="cmdk-empty">no matches</li>}>
                <For each={filtered()}>
                  {(c, i) => (
                    <li
                      class="cmdk-item"
                      classList={{ on: i() === sel() }}
                      onMouseEnter={() => setSel(i())}
                      onMouseDown={(e) => { e.preventDefault(); run(c); }}
                    >
                      <span class="cmdk-label">{c.label}</span>
                      <Show when={c.sub}>
                        <span class="cmdk-sub">{c.sub}</span>
                      </Show>
                    </li>
                  )}
                </For>
              </Show>
            </ul>
            <div class="cmdk-hint">↑↓ move · ↵ run · esc close</div>
          </div>
        </div>
      </Show>
    </>
  );
}

const CMDK_CSS = `
.cmdk-backdrop {
  position: fixed; inset: 0; z-index: 80;
  background: rgba(0,0,0,0.45);
  display: flex; align-items: flex-start; justify-content: center;
  padding-top: 14vh;
}
.cmdk-panel {
  width: min(560px, 90vw);
  background: var(--raised, #1b1815);
  border: 1px solid var(--line, #3a332b);
  border-radius: 12px;
  box-shadow: 0 18px 50px rgba(0,0,0,0.55);
  overflow: hidden;
  font-family: "IBM Plex Mono", ui-monospace, monospace;
}
.cmdk-input {
  width: 100%; box-sizing: border-box;
  background: transparent; color: var(--ink, #e9e2d4);
  border: 0; border-bottom: 1px solid var(--line, #3a332b);
  padding: 13px 16px; font: inherit; font-size: 14px; outline: none;
}
.cmdk-list { list-style: none; margin: 0; padding: 6px; max-height: 46vh; overflow-y: auto; }
.cmdk-item {
  display: flex; align-items: baseline; gap: 10px;
  padding: 7px 10px; border-radius: 7px; cursor: pointer;
  color: var(--ink, #e9e2d4); font-size: 12.5px;
}
.cmdk-item.on { background: var(--panel, #221e1a); }
.cmdk-label { flex: 0 0 auto; }
.cmdk-sub { color: var(--faint, #6f675a); font-size: 11px; margin-left: auto; }
.cmdk-empty { padding: 12px; color: var(--dim, #a89e8c); font-size: 12.5px; }
.cmdk-hint { padding: 8px 14px; border-top: 1px solid var(--line, #3a332b); color: var(--faint, #6f675a); font-size: 11px; }
`;
