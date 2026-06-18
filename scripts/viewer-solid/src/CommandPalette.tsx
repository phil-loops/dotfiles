import { createSignal, createMemo, createEffect, onCleanup, Show, For } from "solid-js";
import { createQuery } from "@tanstack/solid-query";
import { useLocation, useNavigate } from "@solidjs/router";
import { provider, canMutate } from "./provider";
import { homePath, forestPath, nodePath } from "./routes";

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
  const loc = useLocation();
  const navigate = useNavigate();
  // the splat path (sans leading "/") is the forest; ?node= is the node within it.
  const ctx = createMemo(() => ({
    project: loc.pathname.replace(/^\//, ""),
    node: (loc.query.node as string) || "",
  }));
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

  const commands = createMemo<Cmd[]>(() => {
    const c = ctx();
    const cmds: Cmd[] = [];
    if (c.project && canMutate) {
      cmds.push({
        label: `⟳ restack ${leaf(c.project)} onto fresh main`,
        run: () => void post("/restack", { project: c.project }),
      });
    }
    cmds.push({
      label: "↪ jump to checkout (HEAD)",
      run: async () => {
        try {
          const h = await provider.head();
          if (h.branch) navigate(nodePath(c.project, h.branch));
        } catch {
          /* head unavailable — no-op */
        }
      },
    });
    cmds.push({ label: "⌂ home — all forests", run: () => navigate(homePath()) });

    if (c.project) {
      const nodes = model.data?.nodes ? Object.keys(model.data.nodes) : [];
      for (const b of nodes) {
        cmds.push({ label: `→ ${leaf(b)}`, sub: b, run: () => navigate(nodePath(c.project, b)) });
      }
    } else {
      for (const p of projects.data || []) {
        cmds.push({ label: `→ ${p.name}`, sub: "forest", run: () => navigate(forestPath(p.name)) });
      }
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
