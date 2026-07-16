import { createSignal, createMemo, Show, For } from "solid-js";
import { useQueryClient, createMutation } from "@tanstack/solid-query";
import { Link, type ViewerLocation } from "./router";
import { nextStep } from "./homeModel";
import type { Project, PR } from "./types";

// ── focus lane: the hand-ordered "what I'm pushing now" strip ───────────────
// The forest bands rank by shipping momentum; this ranks by Phil's explicit priority. A short
// pinned list (stack-project.<p>.focus N), drag-reordered — the answer to "reorder as priorities
// change" without the old right-click-a-number gesture. Pin/unpin lives in the forest-card ctx
// menu; this owns the ordering (drag → POST /focus {order}).
const pkey = (p: Project) => (p.repo || "loops") + "/" + p.name;

export function FocusLane(props: {
  projects: () => Project[] | undefined;
  prOf: (name: string) => PR | undefined;
}) {
  const qc = useQueryClient();
  // pinned forests in rank order; a live optimistic override holds during a drag so the row
  // doesn't snap back to server order between drop and refetch.
  const [override, setOverride] = createSignal<string[] | null>(null);
  const pinned = createMemo(() => {
    const list = (props.projects() || []).filter((p) => p.focus != null)
      .sort((a, b) => (a.focus ?? 0) - (b.focus ?? 0));
    const ov = override();
    if (!ov) return list;
    const byKey = new Map(list.map((p) => [pkey(p), p]));
    return ov.map((k) => byKey.get(k)).filter((p): p is Project => !!p);
  });

  const reorder = createMutation(() => ({
    mutationFn: (order: { repo: string; project: string }[]) =>
      fetch("/focus", { method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ order }) }).then((r) => r.json()),
    onSettled: () => { setOverride(null); qc.invalidateQueries({ queryKey: ["projects"] }); },
  }));

  const [drag, setDrag] = createSignal<string | null>(null);
  const [over, setOver] = createSignal<string | null>(null);

  const drop = (targetKey: string) => {
    const from = drag();
    setDrag(null); setOver(null);
    if (!from || from === targetKey) return;
    const keys = pinned().map(pkey);
    const fi = keys.indexOf(from), ti = keys.indexOf(targetKey);
    if (fi < 0 || ti < 0) return;
    keys.splice(ti, 0, ...keys.splice(fi, 1));
    setOverride(keys);
    const byKey = new Map(pinned().map((p) => [pkey(p), p]));
    reorder.mutate(keys.map((k) => ({ repo: byKey.get(k)!.repo || "loops", project: byKey.get(k)!.name })));
  };

  const target = (p: Project): ViewerLocation => ({
    kind: "forest", name: p.name, repo: p.repo && p.repo !== "loops" ? p.repo : undefined,
  });

  return (
    <Show when={pinned().length}>
      <section class="focus-lane">
        <h2 class="eyebrow">focus <span class="eyebrow-ask">— what you're pushing now, drag to reorder</span></h2>
        <div class="focus-rows">
          <For each={pinned()}>
            {(p, i) => {
              const step = createMemo(() => nextStep(p, props.prOf(p.name)));
              return (
                <div
                  class="focus-row"
                  classList={{ dragging: drag() === pkey(p), over: over() === pkey(p) }}
                  draggable={true}
                  onDragStart={() => setDrag(pkey(p))}
                  onDragEnd={() => { setDrag(null); setOver(null); }}
                  onDragOver={(e) => { e.preventDefault(); setOver(pkey(p)); }}
                  onDrop={(e) => { e.preventDefault(); drop(pkey(p)); }}
                >
                  <span class="focus-grip" title="drag to reorder">⠿</span>
                  <span class="focus-rank">{i() + 1}</span>
                  <Link class="focus-name" to={target(p)}>
                    {p.repo && p.repo !== "loops" ? <span class="focus-repo">{p.repo}</span> : null}
                    {p.name}
                  </Link>
                  <Show when={step()}>
                    <span class="focus-next" classList={{ yours: !!step()!.yourMove }} title={step()!.title}>
                      {step()!.text}
                    </span>
                  </Show>
                </div>
              );
            }}
          </For>
        </div>
      </section>
    </Show>
  );
}
