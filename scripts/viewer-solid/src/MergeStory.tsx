import { For, Show, createMemo, createSignal } from "solid-js";
import type { ForestModel } from "./types";

// The forest read as a STORY: every branch as the semantic commit it will become, in the order it
// merges into main (deps before dependents). Order comes from the graph (parent + requires); the
// `type(scope): subject` line is derived from each node's plain purpose. So this panel doubles as
// the at-a-glance "what is this feature", the merge plan, and a preview of main's eventual history.
const leafOf = (b: string): string => b.split("/").pop() || b;

// purpose → conventional-commit subject: the first clause, made imperative-lowercase.
const subjectOf = (desc?: string): string => {
  if (!desc) {
    return "(no purpose set yet)";
  }
  const first = desc.split(/ — | – |\. |: |, /)[0].trim().replace(/[.;]+$/, "");
  return first ? first.charAt(0).toLowerCase() + first.slice(1) : desc;
};
// cleanup branches are refactors, not features — inferred from the purpose's verbs.
const typeOf = (desc?: string): "feat" | "refactor" =>
  desc && /\b(remov|drop|delet|clean|deprecat|retire|kill|unused|dead)\b/i.test(desc) ? "refactor" : "feat";

type Step = {
  id: string;
  type: "feat" | "refactor";
  subject: string; // deterministic first-clause fallback
  purpose: string; // the full plain description, sent to the LLM polish
  hasPurpose: boolean;
  buildsOn: number | null; // parent position — a CODE dep (this branch is stacked on it)
  requires: number[]; // requires positions — MERGE-AFTER fan-in deps (separate bases off main)
  depth: number; // how deep in the parent (builds-on) chain — drives the visual indent
  convergence: boolean; // the integrator: pulls lines together, never merges itself
};

export default function MergeStory(props: {
  model: ForestModel | undefined;
  project: string;
  onPick: (branch: string) => void;
}) {
  const steps = createMemo<Step[]>(() => {
    const nodes = props.model?.nodes ?? {};
    const ids = Object.keys(nodes).filter((id) => !id.startsWith("✦")); // drop the ghost endstate
    const inForest = new Set(ids);
    const depsOf = (id: string): string[] => {
      const m = nodes[id];
      const ds: string[] = [];
      if (m?.parent && inForest.has(m.parent)) {
        ds.push(m.parent);
      }
      for (const r of m?.requires ?? []) {
        if (inForest.has(r) && !ds.includes(r)) {
          ds.push(r);
        }
      }
      return ds;
    };
    const hasDownstream = (id: string): boolean => ids.some((o) => o !== id && depsOf(o).includes(id));
    // depth in the parent (builds-on) chain only — a separate base off main is depth 0 even if it
    // `requires` something; a true child is one deeper than its parent. Drives the indent.
    const depthOf = (id: string): number => {
      let d = 0;
      let cur = nodes[id]?.parent;
      const guard = new Set<string>();
      while (cur && inForest.has(cur) && cur !== "main" && !guard.has(cur)) {
        guard.add(cur);
        d++;
        cur = nodes[cur]?.parent;
      }
      return d;
    };

    // Merge order: consume /model's canonical mergeOrder VERBATIM (stack-merge-rank — the single
    // authority, with the declared-order tie-break already baked in), so the story, the PR-body
    // sequencing, and the map can't disagree. Sorting by the mergeRank field client-side is NOT
    // equivalent (its tie-break would fall to node-key order). Local Kahn is only a fallback for an
    // older /model that predates mergeOrder.
    const canonical = props.model?.mergeOrder?.filter((id) => inForest.has(id));
    let order: string[];
    if (canonical && canonical.length) {
      order = [...canonical];
      const seen = new Set(order);
      for (const id of ids) {
        if (!seen.has(id)) {
          order.push(id); // safety net: never silently drop a node mergeOrder happened to omit
        }
      }
    } else {
      order = [];
      const done = new Set<string>();
      const remaining = [...ids];
      let guard = 0;
      while (remaining.length && guard++ < 999) {
        const ready = remaining.filter((id) => depsOf(id).every((d) => done.has(d)));
        const batch = (ready.length ? ready : [...remaining]).sort((a, b) => leafOf(a).localeCompare(leafOf(b)));
        for (const id of batch) {
          order.push(id);
          done.add(id);
          remaining.splice(remaining.indexOf(id), 1);
        }
        if (!ready.length) {
          break; // a cycle (shouldn't happen) — dump the rest rather than spin
        }
      }
    }
    const pos = new Map(order.map((id, i) => [id, i + 1]));
    return order.map((id) => {
      const m = nodes[id];
      // parent (≠ main, in-forest) = a CODE dependency — this branch is stacked on it. requires =
      // MERGE-AFTER fan-in: separate bases that must land first. The story labels them differently.
      const parent = m?.parent && inForest.has(m.parent) && m.parent !== "main" ? m.parent : null;
      const reqs = (m?.requires ?? []).filter((r) => inForest.has(r));
      return {
        id,
        type: typeOf(m?.description),
        subject: subjectOf(m?.description),
        purpose: m?.description ?? "",
        hasPurpose: !!m?.description,
        buildsOn: parent ? (pos.get(parent) ?? null) : null,
        requires: reqs.map((r) => pos.get(r) ?? 0).filter((n) => n > 0).sort((a, b) => a - b),
        depth: depthOf(id),
        convergence: !hasDownstream(id) && reqs.length > 0,
      };
    });
  });

  const scope = () => leafOf(props.project);

  // opt-in LLM pass: crisp each subject AND read the node's diff for one non-trivial detail.
  const [polished, setPolished] = createSignal<Record<string, { subject?: string; detail?: string }>>({});
  const [polishing, setPolishing] = createSignal(false);
  const [polishErr, setPolishErr] = createSignal(false);
  const polish = async () => {
    if (polishing()) {
      return;
    }
    setPolishing(true);
    setPolishErr(false);
    try {
      const items = steps()
        .filter((s) => s.hasPurpose)
        .map((s) => ({ key: s.id, type: s.type, purpose: s.purpose }));
      const r = await fetch("/merge-subjects", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ scope: scope(), items }),
      }).then((res) => res.json());
      const map = r && typeof r === "object" ? (r as Record<string, { subject?: string; detail?: string }>) : {};
      setPolished(map);
      if (!Object.keys(map).length) {
        setPolishErr(true);
      }
    } catch {
      setPolishErr(true);
    }
    setPolishing(false);
  };

  return (
    <div class="ms">
      <style>{CSS}</style>
      <div class="ms-head">
        <span class="ms-flow">{props.project} → main</span>
        <span class="ms-cap">in merge order</span>
        <button class="ms-polish" disabled={polishing()} onClick={polish} title="crisp the subjects + pull a non-trivial implementation detail from each diff (LLM)">
          {polishing() ? "polishing…" : Object.keys(polished()).length ? "✨ re-polish" : "✨ polish"}
        </button>
        <Show when={polishErr()}>
          <span class="ms-polish-err">couldn’t polish</span>
        </Show>
      </div>
      <ol class="ms-list">
        <For each={steps()}>
          {(s, i) => (
            <li
              class="ms-row"
              classList={{ convergence: s.convergence, nested: s.depth > 0 }}
              style={{ "margin-left": `${s.depth * 26}px` }}
              onClick={() => props.onPick(s.id)}
              title={`open ${leafOf(s.id)}`}
            >
              <span class="ms-num">{s.convergence ? "★" : i() + 1}</span>
              <div class="ms-body">
                <code class="ms-commit" classList={{ faint: !s.hasPurpose }}>
                  <span class="ms-type" classList={{ refactor: s.type === "refactor" }}>{s.type}</span>
                  <span class="ms-scope">({scope()})</span>: {polished()[s.id]?.subject ?? s.subject}
                </code>
                <Show when={polished()[s.id]?.detail ?? (s.hasPurpose ? s.purpose : "")}>
                  {(detail) => <p class="ms-detail">{detail()}</p>}
                </Show>
                <Show when={s.convergence}>
                  <span class="ms-dep conv">
                    converges {[...(s.buildsOn ? [s.buildsOn] : []), ...s.requires].sort((a, b) => a - b).join(" · ")} — convergence view, never merges
                  </span>
                </Show>
                <Show when={!s.convergence}>
                  <Show when={s.buildsOn}>
                    <span class="ms-dep">↳ builds on {s.buildsOn}</span>
                  </Show>
                  <Show when={s.requires.length}>
                    <span class="ms-dep req">⤿ requires {s.requires.join(" · ")} — merges after</span>
                  </Show>
                </Show>
              </div>
            </li>
          )}
        </For>
      </ol>
    </div>
  );
}

const CSS = `
.ms { max-width: 760px; margin: 0 auto; padding: 8px 16px 40px; font-family: "IBM Plex Mono", ui-monospace, monospace; }
.ms-head { display: flex; align-items: baseline; gap: 12px; padding: 6px 2px 16px; }
.ms-flow { font-size: 14px; color: var(--ink, #e9e2d4); }
.ms-cap { font-size: 11px; letter-spacing: .08em; text-transform: uppercase; color: var(--ink-faint, #6f675a); }
.ms-polish {
  margin-left: auto; font: inherit; font-size: 11px; cursor: pointer; white-space: nowrap;
  color: var(--gold, #e0ad4e); background: transparent; border: 1px solid var(--gold, #e0ad4e);
  border-radius: 6px; padding: 3px 10px; opacity: .9;
}
.ms-polish:hover:not(:disabled) { opacity: 1; background: rgba(224,173,78,.1); }
.ms-polish:disabled { opacity: .5; cursor: default; }
.ms-polish-err { font-size: 11px; color: var(--ember, #d36a36); }
.ms-list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 4px; }
.ms-row {
  display: flex; align-items: baseline; gap: 12px; padding: 9px 12px; border-radius: 8px; cursor: pointer;
  border: 1px solid transparent;
}
.ms-row:hover { background: var(--raised, #1b1815); border-color: var(--rule, #3a332b); }
.ms-row.nested { border-left: 2px solid var(--rule, #3a332b); border-top-left-radius: 0; border-bottom-left-radius: 0; }
.ms-row.nested:hover { border-left-color: var(--patina, #8a9a6b); }
.ms-num {
  flex: none; width: 22px; text-align: center; font-size: 12px; color: var(--ink-faint, #6f675a);
  border-right: 1px solid var(--rule, #3a332b); padding-right: 10px;
}
.ms-row.convergence .ms-num { color: var(--gold, #e0ad4e); border-color: transparent; }
.ms-body { display: flex; flex-direction: column; gap: 3px; min-width: 0; }
.ms-commit { font-size: 13px; line-height: 1.5; color: var(--ink, #e9e2d4); word-break: break-word; }
.ms-commit.faint { color: var(--ink-faint, #6f675a); font-style: italic; }
.ms-detail { margin: 2px 0 0; font-size: 12px; line-height: 1.55; color: var(--ink-dim, #a89e8c); max-width: 64ch; }
.ms-type { color: var(--patina, #8a9a6b); }
.ms-type.refactor { color: var(--gold, #e0ad4e); }
.ms-scope { color: var(--ink-dim, #a89e8c); }
.ms-dep { display: block; font-size: 11px; color: var(--ink-faint, #6f675a); }
.ms-dep.req { color: var(--patina, #8a9a6b); }
.ms-dep.conv { color: var(--gold, #e0ad4e); opacity: .85; }
.ms-row.convergence { opacity: .9; }
`;
