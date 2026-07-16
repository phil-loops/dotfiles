import { For, Show, createMemo, createSignal } from "solid-js";
import type { ForestModel } from "./types";
import { withRepo, canMutate } from "./provider";

// The forest read as a STORY: every branch as the semantic commit it will become, in the order it
// merges into main (deps before dependents). Order comes from the graph (parent + requires); the
// `type(scope): subject` line is derived from each node's plain purpose. So this panel doubles as
// the at-a-glance "what is this feature", the merge plan, and a preview of main's eventual history.
const leafOf = (b: string): string => b.split("/").pop() || b;

// purpose → {subject, why}: the FIRST clause is the conventional-commit subject (imperative,
// lower-cased); anything past the first delimiter is the "why". A one-clause purpose has no why, so
// the subtitle stays empty instead of restating the subject — the grammar is `subject — why`.
const splitPurpose = (desc?: string): { subject: string; why: string } => {
  if (!desc) {
    return { subject: "(no purpose set yet)", why: "" };
  }
  const m = desc.match(/^([\s\S]*?)(?: — | – |\. |: |, )([\s\S]*)$/);
  const head = (m ? m[1] : desc).trim().replace(/[.;]+$/, "");
  const subject = head ? head.charAt(0).toLowerCase() + head.slice(1) : desc;
  return { subject, why: m ? m[2].trim() : "" };
};
// cleanup branches are refactors, not features — inferred from the purpose's verbs.
const typeOf = (desc?: string): "feat" | "refactor" =>
  desc && /\b(remov|drop|delet|clean|deprecat|retire|kill|unused|dead)\b/i.test(desc) ? "refactor" : "feat";

type Step = {
  id: string;
  type: "feat" | "refactor";
  subject: string; // deterministic first-clause fallback
  why: string; // the description's remainder past the first clause — "" when it's one clause
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
      const { subject, why } = splitPurpose(m?.description);
      return {
        id,
        type: typeOf(m?.description),
        subject,
        why,
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

  // The per-project BODY TEMPLATE — edited once here, carried to every future child. Only the
  // durable wording lives in config; the volatile facts (#PR, [this branch], position) re-fill on
  // every render. Server: GET/POST /plan-template, GET /plan-preview (a representative branch so the
  // #PRs actually show). Preview reflects SAVED state — save is the commit, then it refreshes.
  const previewBranch = () => steps().at(-1)?.id ?? "";
  const [tmplOpen, setTmplOpen] = createSignal(false);
  const [outer, setOuter] = createSignal("");
  const [stepFmt, setStepFmt] = createSignal("");
  const [tmplDefaults, setTmplDefaults] = createSignal<{ template: string; step: string }>({ template: "", step: "" });
  const [preview, setPreview] = createSignal("");
  const [savingTmpl, setSavingTmpl] = createSignal(false);

  const loadPreview = async () => {
    const b = previewBranch();
    if (!b) {
      return;
    }
    try {
      const r = await fetch(withRepo(`/plan-preview?branch=${encodeURIComponent(b)}`)).then((res) => res.json());
      setPreview(r?.plan ?? "");
    } catch {
      setPreview("");
    }
  };
  const openTemplate = async () => {
    if (tmplOpen()) {
      setTmplOpen(false);
      return;
    }
    setTmplOpen(true);
    try {
      const r = await fetch(withRepo(`/plan-template?project=${encodeURIComponent(props.project)}`)).then((res) => res.json());
      const d = r?.defaults ?? { template: "", step: "" };
      setTmplDefaults(d);
      setOuter(r?.template || d.template || "");
      setStepFmt(r?.step || d.step || "");
    } catch { /* leave fields empty */ }
    void loadPreview();
  };
  const saveTemplate = async () => {
    if (savingTmpl()) {
      return;
    }
    setSavingTmpl(true);
    try {
      await fetch(withRepo("/plan-template"), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ project: props.project, template: outer(), step: stepFmt() }),
      });
      await loadPreview();
    } catch { /* surfaced by an unchanged preview */ }
    setSavingTmpl(false);
  };
  const resetTemplate = () => {
    setOuter(tmplDefaults().template);
    setStepFmt(tmplDefaults().step);
  };

  return (
    <div class="ms mx-auto my-0 max-w-[760px] pt-[8px] px-[16px] pb-[40px] font-mono">
      <div class="ms-head flex items-baseline gap-[12px] pt-[6px] px-[2px] pb-[16px]">
        <span class="ms-flow text-[14px] text-ink">{props.project} → main</span>
        <span class="ms-cap text-[11px] uppercase tracking-[0.08em] text-ink-faint">in merge order</span>
        <Show when={canMutate}>
          <button
            class={`ms-tmpl-btn cursor-pointer whitespace-nowrap rounded-[6px] border py-[3px] px-[10px] text-[11px] leading-[1.55] opacity-90 hover:opacity-100 ${
              tmplOpen()
                ? "text-patina border-patina bg-[rgba(138,154,107,0.1)]"
                : "text-ink-dim border-rule bg-transparent hover:border-patina"
            }`}
            classList={{ on: tmplOpen() }}
            onClick={openTemplate}
            title="edit the per-project commit/PR body template — once, carried to every child"
          >
            ⚙ template
          </button>
        </Show>
        <button
          class="ms-polish ml-auto cursor-pointer whitespace-nowrap rounded-[6px] border border-[#e0ad4e] bg-transparent py-[3px] px-[10px] text-[11px] leading-[1.55] text-[#e0ad4e] opacity-90 hover:enabled:opacity-100 hover:enabled:bg-[rgba(224,173,78,0.1)] disabled:opacity-50 disabled:cursor-default"
          disabled={polishing()}
          onClick={polish}
          title="crisp the subjects + pull a non-trivial implementation detail from each diff (LLM)"
        >
          {polishing() ? "polishing…" : Object.keys(polished()).length ? "✨ re-polish" : "✨ polish"}
        </button>
        <Show when={polishErr()}>
          <span class="ms-polish-err text-[11px] text-ember">couldn’t polish</span>
        </Show>
      </div>
      <Show when={tmplOpen()}>
        <div class="ms-tmpl mt-0 mx-[2px] mb-[14px] flex flex-col gap-[6px] rounded-[8px] border border-rule bg-[#1b1815] py-[12px] px-[14px]">
          <p class="ms-tmpl-hint mt-0 mx-0 mb-[4px] text-[11px] leading-[1.5] text-ink-dim">
            edited once, carried to every child — the volatile facts (<code class="text-[10.5px] text-patina">#PR</code>, <code class="text-[10.5px] text-patina">[this branch]</code>, position) re-fill on each render.
          </p>
          <label class="ms-tmpl-lbl flex items-baseline gap-[8px] text-[11px] text-ink-faint">outer <span class="ms-tmpl-tok text-[10.5px] text-patina">{"{project}"} · {"{steps}"}</span></label>
          <textarea class={TA} rows={4} spellcheck={false} value={outer()} onInput={(e) => setOuter(e.currentTarget.value)} />
          <label class="ms-tmpl-lbl flex items-baseline gap-[8px] text-[11px] text-ink-faint">step line <span class="ms-tmpl-tok text-[10.5px] text-patina">{"{n}"} · {"{ref}"} · {"{job}"} · {"{pr}"} · {"{me}"}</span></label>
          <textarea class={TA} rows={1} spellcheck={false} value={stepFmt()} onInput={(e) => setStepFmt(e.currentTarget.value)} />
          <div class="ms-tmpl-actions mt-[2px] flex items-center gap-[10px]">
            <button
              class="ms-tmpl-save cursor-pointer rounded-[6px] bg-patina py-[4px] px-[14px] text-[11px] leading-[1.55] text-[#131110] disabled:opacity-50 disabled:cursor-default"
              disabled={savingTmpl()}
              onClick={saveTemplate}
            >{savingTmpl() ? "saving…" : "save"}</button>
            <button
              class="ms-tmpl-reset cursor-pointer rounded-[6px] border border-rule bg-transparent py-[4px] px-[10px] text-[11px] leading-[1.55] text-ink-faint hover:text-ink-dim"
              onClick={resetTemplate}
            >reset to default</button>
            <span class="ms-tmpl-note ml-auto text-[10.5px] text-ink-faint">preview as {leafOf(previewBranch())}</span>
          </div>
          <Show when={preview()}>
            <pre class="ms-tmpl-preview mt-[6px] mx-0 mb-0 overflow-x-auto whitespace-pre-wrap break-words rounded-[6px] border border-rule bg-[#131110] py-[10px] px-[12px] text-[12px] leading-[1.5] text-ink-dim">{preview()}</pre>
          </Show>
        </div>
      </Show>
      <ol class="ms-list m-0 flex list-none flex-col gap-[4px] p-0">
        <For each={steps()}>
          {(s, i) => {
            // subtitle = the LLM's diff detail, else the description's own "why" (its remainder past
            // the first clause). A one-clause purpose has no why, so it renders NOTHING rather than
            // echoing the subject back — the redundancy this hides.
            const subj = () => polished()[s.id]?.subject ?? s.subject;
            const sub = () => polished()[s.id]?.detail ?? s.why;
            return (
            <li
              class={`ms-row flex cursor-pointer items-baseline gap-[12px] py-[9px] px-[12px] hover:bg-[#1b1815] ${
                s.depth > 0
                  ? "rounded-r-[8px] border-y border-r border-l-2 border-y-transparent border-r-transparent border-l-rule hover:border-y-rule hover:border-r-rule hover:border-l-patina"
                  : "rounded-[8px] border border-transparent hover:border-rule"
              } ${s.convergence ? "opacity-90" : ""}`}
              classList={{ convergence: s.convergence, nested: s.depth > 0 }}
              style={{ "margin-left": `${s.depth * 26}px` }}
              onClick={() => props.onPick(s.id)}
              title={`open ${leafOf(s.id)}`}
            >
              <span
                class={`ms-num w-[22px] flex-none border-r pr-[10px] text-center text-[12px] ${
                  s.convergence ? "text-[#e0ad4e] border-r-transparent" : "text-ink-faint border-r-rule"
                }`}
              >{s.convergence ? "★" : i() + 1}</span>
              <div class="ms-body flex min-w-0 flex-col gap-[3px]">
                <code
                  class={`ms-commit break-words text-[13px] leading-[1.5] ${!s.hasPurpose ? "text-ink-faint italic" : "text-ink"}`}
                  classList={{ faint: !s.hasPurpose }}
                >
                  <span
                    class={`ms-type ${s.type === "refactor" ? "text-[#e0ad4e]" : "text-patina"}`}
                    classList={{ refactor: s.type === "refactor" }}
                  >{s.type}</span>
                  <span class="ms-scope text-ink-dim">({scope()})</span>: {subj()}
                </code>
                <Show when={sub() && sub() !== subj()}>
                  <p class="ms-detail mt-[2px] mx-0 mb-0 max-w-[64ch] text-[12px] leading-[1.55] text-ink-dim">{sub()}</p>
                </Show>
                <Show when={s.convergence}>
                  <span class="ms-dep conv block text-[11px] text-[#e0ad4e] opacity-[0.85]">
                    converges {[...(s.buildsOn ? [s.buildsOn] : []), ...s.requires].sort((a, b) => a - b).join(" · ")} — convergence view, never merges
                  </span>
                </Show>
                <Show when={!s.convergence}>
                  <Show when={s.buildsOn}>
                    <span class="ms-dep block text-[11px] text-ink-faint">↳ builds on {s.buildsOn}</span>
                  </Show>
                  <Show when={s.requires.length}>
                    <span class="ms-dep req block text-[11px] text-patina">⤿ requires {s.requires.join(" · ")} — merges after</span>
                  </Show>
                </Show>
              </div>
            </li>
            );
          }}
        </For>
      </ol>
    </div>
  );
}

// font: inherit on a textarea pulled the .ms mono stack in; box-border beats the UA's content-box
const TA =
  "ms-tmpl-ta box-border w-full resize-y overflow-x-auto whitespace-pre rounded-[6px] border border-rule bg-[#131110] py-[7px] px-[9px] font-mono text-[12px] leading-[1.5] text-ink focus:outline-none focus:border-patina";

