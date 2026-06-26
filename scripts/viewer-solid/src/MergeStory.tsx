import { For, Show, createMemo } from "solid-js";
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
  subject: string;
  hasPurpose: boolean;
  deps: number[]; // 1-based merge-order positions this step lands after
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

    // topological merge order (Kahn) — emit a node once all its deps are emitted; stable by leaf.
    const order: string[] = [];
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
    const pos = new Map(order.map((id, i) => [id, i + 1]));
    return order.map((id) => {
      const m = nodes[id];
      const deps = depsOf(id);
      return {
        id,
        type: typeOf(m?.description),
        subject: subjectOf(m?.description),
        hasPurpose: !!m?.description,
        deps: deps.map((d) => pos.get(d) ?? 0).sort((a, b) => a - b),
        convergence: deps.length > 0 && !hasDownstream(id) && (m?.requires?.length ?? 0) > 0,
      };
    });
  });

  const scope = () => leafOf(props.project);

  return (
    <div class="ms">
      <style>{CSS}</style>
      <div class="ms-head">
        <span class="ms-flow">{props.project} → main</span>
        <span class="ms-cap">in merge order</span>
      </div>
      <ol class="ms-list">
        <For each={steps()}>
          {(s, i) => (
            <li
              class="ms-row"
              classList={{ convergence: s.convergence }}
              onClick={() => props.onPick(s.id)}
              title={`open ${leafOf(s.id)}`}
            >
              <span class="ms-num">{s.convergence ? "★" : i() + 1}</span>
              <div class="ms-body">
                <code class="ms-commit" classList={{ faint: !s.hasPurpose }}>
                  <span class="ms-type" classList={{ refactor: s.type === "refactor" }}>{s.type}</span>
                  <span class="ms-scope">({scope()})</span>: {s.subject}
                </code>
                <Show when={s.convergence}>
                  <span class="ms-dep conv">converges {s.deps.join(" · ")} — convergence view, never merges</span>
                </Show>
                <Show when={!s.convergence && s.deps.length}>
                  <span class="ms-dep">↳ after {s.deps.join(" · ")}</span>
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
.ms-list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 4px; }
.ms-row {
  display: flex; align-items: baseline; gap: 12px; padding: 9px 12px; border-radius: 8px; cursor: pointer;
  border: 1px solid transparent;
}
.ms-row:hover { background: var(--raised, #1b1815); border-color: var(--rule, #3a332b); }
.ms-num {
  flex: none; width: 22px; text-align: center; font-size: 12px; color: var(--ink-faint, #6f675a);
  border-right: 1px solid var(--rule, #3a332b); padding-right: 10px;
}
.ms-row.convergence .ms-num { color: var(--gold, #e0ad4e); border-color: transparent; }
.ms-body { display: flex; flex-direction: column; gap: 3px; min-width: 0; }
.ms-commit { font-size: 13px; line-height: 1.5; color: var(--ink, #e9e2d4); word-break: break-word; }
.ms-commit.faint { color: var(--ink-faint, #6f675a); font-style: italic; }
.ms-type { color: var(--patina, #8a9a6b); }
.ms-type.refactor { color: var(--gold, #e0ad4e); }
.ms-scope { color: var(--ink-dim, #a89e8c); }
.ms-dep { font-size: 11px; color: var(--ink-faint, #6f675a); }
.ms-dep.conv { color: var(--gold, #e0ad4e); opacity: .85; }
.ms-row.convergence { opacity: .9; }
`;
