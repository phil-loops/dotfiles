import { createSignal, createMemo, createEffect, onCleanup, Show, For } from "solid-js";
import { createQuery, keepPreviousData } from "@tanstack/solid-query";
import { provider } from "./provider";
import { fetchJSON } from "./api";
import { track } from "./track";
import { useViewerLocation, forestKey, nodeOf, withNode, forestRepo } from "./router";
import { cachedModel } from "./modelCache";
import { cachedProjects } from "./projectsCache";
import { recentNodes, recents } from "./recents";
import { openMap } from "./mapState";
import { isGhostId } from "./forestLayout";

// CommandPalette — Cmd/Ctrl+K: a fuzzy finder for branches, forests and the concepts and wiki
// pages around them. 95% of four months' selections were jumps, so jumping is all it does:
// recently opened branches first, then the forest you're in, then everything. A forest opens as
// the map overlay rather than a page. Deliberately NO "bless" entry — blessing is earned per-file
// in the diff view. Standalone, self-styled; mount once in App.

type Entry = { key: string; label: string; sub?: string; recent?: boolean; run: () => void };

const leaf = (s: string) => (s || "").split("/").pop() ?? "";
const repoOf = (r?: string) => (r && r !== "loops" ? r : undefined);

// module scope so the map overlay can yield the keyboard while the palette sits over it
const [open, setOpen] = createSignal(false);
export const paletteOpen = open;

type WikiPages = { pages: { slug: string; title: string; section: string }[] };
type Concepts = { concepts: Record<string, { name: string; statement?: string }> };

export default function CommandPalette() {
  const [q, setQ] = createSignal("");
  const [sel, setSel] = createSignal(0);
  const { location, navigate } = useViewerLocation();
  const ctx = createMemo(() => {
    const l = location();
    return { project: l.kind === "forest" ? forestKey(l) : "", node: nodeOf(l) || "" };
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

  // The key MUST match ForestOverview/NodeDetail's ["model", repo, project] or this is a separate
  // cache entry: the palette then fires its own cold /model on open (1.1-5.7s, a brand-new forest
  // 16-39s) and the forest you are standing in has ZERO entries for the whole fetch (2026-10-07).
  const repoKey = () => forestRepo(location()) ?? "loops";
  const model = createQuery(() => ({
    queryKey: ["model", repoKey(), ctx().project],
    queryFn: () => provider.model(ctx().project),
    enabled: open() && !!ctx().project,
    initialData: () => cachedModel(repoKey(), ctx().project),
    placeholderData: keepPreviousData,
  }));
  const projects = createQuery(() => ({
    queryKey: ["projects"],
    queryFn: () => provider.projects(),
    initialData: cachedProjects,
    initialDataUpdatedAt: 0,
    enabled: open(),
  }));
  const forestBranches = createQuery(() => ({
    queryKey: ["forest-branches"],
    queryFn: () => provider.forestBranches(),
    enabled: open(),
  }));
  const wiki = createQuery(() => ({
    queryKey: ["palette-wiki"],
    queryFn: () => fetchJSON<WikiPages>("/wiki-pages"),
    enabled: open(),
    staleTime: 5 * 60_000,
  }));
  const concepts = createQuery(() => ({
    queryKey: ["palette-concepts"],
    queryFn: () => fetchJSON<Concepts>("/learning-state"),
    enabled: open(),
    staleTime: 5 * 60_000,
  }));

  const entries = createMemo<Entry[]>(() => {
    const c = ctx();
    const out: Entry[] = [];
    const seen = new Set<string>();
    const add = (e: Entry) => {
      if (seen.has(e.key)) return;
      seen.add(e.key);
      out.push(e);
    };
    const toNode = (branch: string, project: string, repo?: string) => () =>
      navigate(c.project === project && repoOf(repo) === forestRepo(location())
        ? withNode(location(), branch)
        : { kind: "forest", name: project, node: branch, repo: repoOf(repo) });

    for (const n of recentNodes()) {
      if (n.branch === c.node) continue;
      add({ key: `b:${n.repo ?? ""}:${n.branch}`, label: `↺ ${leaf(n.branch)}`, sub: n.branch, recent: true, run: toNode(n.branch, n.project, n.repo) });
    }
    for (const b of Object.keys(model.data?.nodes ?? {})) {
      if (b === c.node) continue;
      const ghost = isGhostId(b);
      add({
        key: `b:${repoOf(forestRepo(location())) ?? ""}:${b}`,
        label: `→ ${ghost ? b : leaf(b)}`,
        sub: ghost ? "the whole forest, integrated" : b,
        run: toNode(ghost ? "~integration" : b, c.project, forestRepo(location())),
      });
    }
    const recentForests = new Set(recents().map((r) => (r.to.kind === "forest" ? `${repoOf(r.to.repo) ?? ""}:${r.to.name}` : "")));
    const forests = [...(projects.data ?? [])].sort((a, b) =>
      Number(recentForests.has(`${repoOf(b.repo) ?? ""}:${b.name}`)) - Number(recentForests.has(`${repoOf(a.repo) ?? ""}:${a.name}`))
      || (b.lastCommit ?? 0) - (a.lastCommit ?? 0));
    for (const p of forests) {
      add({
        key: `f:${repoOf(p.repo) ?? ""}:${p.name}`,
        label: `⊞ ${p.name}`,
        sub: `forest · ${p.branches} ${p.branches === 1 ? "node" : "nodes"}${repoOf(p.repo) ? ` · ${p.repo}` : ""}`,
        recent: recentForests.has(`${repoOf(p.repo) ?? ""}:${p.name}`),
        run: () => openMap({ name: p.name, repo: repoOf(p.repo) }),
      });
    }
    for (const fb of forestBranches.data ?? []) {
      if (fb.branch === c.node) continue;
      add({ key: `b:${repoOf(fb.repo) ?? ""}:${fb.branch}`, label: `→ ${fb.branch}`, sub: repoOf(fb.repo) ? `${fb.repo}/${fb.project}` : fb.project, run: toNode(fb.branch, fb.project, fb.repo) });
    }
    for (const [id, k] of Object.entries(concepts.data?.concepts ?? {})) {
      add({ key: `c:${id}`, label: `◇ ${k.name}`, sub: "concept", run: () => navigate({ kind: "tutor", concept: id }) });
    }
    for (const p of wiki.data?.pages ?? []) {
      add({ key: `w:${p.slug}`, label: `¶ ${p.title}`, sub: p.section ? `wiki · ${p.section}` : "wiki", run: () => navigate({ kind: "wiki", slug: p.slug }) });
    }
    return out;
  });

  // substring outranks subsequence; consecutive runs and word-start hits rank tighter
  const fuzzyScore = (needle: string, hay: string): number => {
    const at = hay.indexOf(needle);
    if (at !== -1) return 1e6 - at * 10 - hay.length;
    let score = 0;
    let prev = -2;
    for (const ch of needle) {
      const j = hay.indexOf(ch, prev + 1);
      if (j === -1) return -Infinity;
      score += j === prev + 1 ? 10 : 1;
      if (j === 0 || "-/ _.".includes(hay[j - 1])) score += 5;
      prev = j;
    }
    return score - hay.length * 0.01;
  };

  // a place you were recently wins a near-tie, never a clearly better match
  const RECENT_BONUS = 40;
  const filtered = createMemo<Entry[]>(() => {
    const needle = q().toLowerCase().replace(/\s+/g, "");
    const list = entries();
    if (!needle) return list.slice(0, 200);
    return list
      .map((c, i) => ({ c, i, s: fuzzyScore(needle, (c.label.slice(2) + " " + (c.sub || "")).toLowerCase()) + (c.recent ? RECENT_BONUS : 0) }))
      .filter((x) => x.s > -Infinity)
      .sort((a, b) => b.s - a.s || a.i - b.i)
      .slice(0, 200)
      .map((x) => x.c);
  });

  createEffect(() => {
    const n = filtered().length;
    if (sel() >= n) setSel(Math.max(0, n - 1));
  });
  createEffect(() => {
    if (open()) queueMicrotask(() => inputRef?.focus());
  });

  const run = (c?: Entry) => {
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
      {/* empty strut where the old inline <style> stood — removing the node renumbers every later sibling in the rect baselines; drop it in a deliberate rects-only re-baseline commit */}
      <Show when={open()}>
        <div
          class="cmdk-backdrop fixed inset-0 z-[80] flex items-start justify-center bg-[rgba(0,0,0,0.45)] pt-[14vh]"
          onClick={(e) => { if (e.target === e.currentTarget) setOpen(false); }}
        >
          <div class='cmdk-panel w-[min(560px,90vw)] overflow-hidden rounded-xl border border-[#3a332b] bg-[#1b1815] font-["IBM_Plex_Mono",ui-monospace,monospace] shadow-[0_18px_50px_rgba(0,0,0,0.55)]'>
            <input
              ref={inputRef}
              class="cmdk-input w-full border-0 border-b border-[#3a332b] bg-transparent px-4 py-[13px] text-[14px] leading-[1.55] text-ink outline-none [font-family:inherit]"
              placeholder="jump to a branch, forest, concept…"
              value={q()}
              onInput={(e) => { setQ(e.currentTarget.value); setSel(0); }}
              onKeyDown={onInputKey}
            />
            <ul class="cmdk-list m-0 max-h-[46vh] list-none overflow-y-auto p-1.5">
              <Show when={filtered().length} fallback={<li class="cmdk-empty p-3 text-[12.5px] text-[#a89e8c]">no matches</li>}>
                <For each={filtered()}>
                  {(c, i) => (
                    <li
                      class="cmdk-item flex cursor-pointer items-baseline gap-2.5 rounded-[7px] px-2.5 py-[7px] text-[12.5px] text-ink"
                      classList={{ "on bg-[#221e1a]": i() === sel() }}
                      ref={(el) => createEffect(() => { if (i() === sel()) el.scrollIntoView({ block: "nearest" }); })}
                      onMouseEnter={() => setSel(i())}
                      onMouseDown={(e) => { e.preventDefault(); run(c); }}
                    >
                      <span class="cmdk-label min-w-0 flex-none overflow-hidden text-ellipsis whitespace-nowrap">{c.label}</span>
                      <Show when={c.sub}>
                        <span class="cmdk-sub ml-auto min-w-0 overflow-hidden text-ellipsis whitespace-nowrap text-[11px] text-[#6f675a]">{c.sub}</span>
                      </Show>
                    </li>
                  )}
                </For>
              </Show>
            </ul>
            <div class="cmdk-hint border-t border-[#3a332b] px-3.5 py-2 text-[11px] text-[#6f675a]">↺ recent · ⊞ forest map · ◇ concept · ¶ wiki — ↑↓ move · ↵ go · esc close</div>
          </div>
        </div>
      </Show>
    </>
  );
}
