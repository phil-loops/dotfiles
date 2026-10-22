// A forest's landing order: every node in merge order with the title that will actually land on
// main — the saved PR title, else the opening commit's subject, else the merged PR's own title.
// Replaces the merge-story face, whose subjects were derived from descriptions and contradicted
// the real commits. Same data as the outbox, so the two can never disagree.
import { createMemo, createSignal, For, Show } from "solid-js";
import { createQuery } from "@tanstack/solid-query";
import { Link } from "./router";
import { fetchOutbox, useOutboxActions } from "./outboxActions";
import { GatesChip, LandingTitle, PrChip } from "./OutboxParts";
import { isLaunch } from "./outboxModel";

export function ForestLanding(props: { project: string; repo?: string; onPick: (branch: string) => void }) {
  const actions = useOutboxActions();
  const q = createQuery(() => ({
    queryKey: ["outbox", (props.repo ?? "") + "/" + props.project],
    queryFn: () => fetchOutbox(props.project, props.repo),
  }));
  const forest = createMemo(() => q.data?.forests[0]);
  const [editing, setEditing] = createSignal<string | null>(null);
  return (
    <div class="fo-landing mx-auto w-full max-w-[860px] px-[28px] pt-[22px] pb-[80px]">
      <Show when={forest()} fallback={
        <p class="font-display italic text-ink-dim">{q.isLoading ? "reading the landing order…" : "Every node of this forest has landed."}</p>
      }>
        {(f) => (
          <>
            <div class="mb-[10px] flex items-baseline gap-[12px]">
              <span class="font-mono text-[10px] tracking-[0.22em] text-ink-faint uppercase">lands on main, in this order</span>
              <Show when={isLaunch(f())}>
                <Link class="ml-auto font-mono text-[11px] text-gold-leaf no-underline hover:underline"
                  to={{ kind: "outbox", launch: f().project, repo: f().repo === "loops" ? undefined : f().repo }}>
                  launch the forest ⇢
                </Link>
              </Show>
            </div>
            <ol class="m-0 list-none border-t border-rule p-0">
              <For each={f().nodes.filter((n) => n.status !== "empty")}>
                {(n) => (
                  <li class="grid cursor-pointer grid-cols-[34px_1fr] gap-x-[10px] border-b border-rule px-[6px] py-[11px] hover:bg-vellum-raise" onClick={() => props.onPick(n.branch)}>
                    <span class={`text-center font-display text-[20px] italic leading-none ${n.status === "landed" ? "text-gold-deep" : "text-ink-faint"}`}>{n.position}</span>
                    <div class="min-w-0">
                      <div class="flex min-w-0 items-baseline" style={{ "padding-left": `${(n.rank - 1) * 14}px` }}>
                        <LandingTitle n={n} repo={f().repo} actions={actions} editing={editing() === n.branch}
                          setEditing={(on) => setEditing(on ? n.branch : null)}
                          class={`font-display text-[16px] ${n.status === "landed" ? "text-ink-faint line-through decoration-gold-deep" : "text-ink"}`} />
                      </div>
                      <div class="mt-[3px] flex flex-wrap items-center gap-x-[8px] gap-y-[3px] font-mono text-[11px] text-ink-faint" style={{ "padding-left": `${(n.rank - 1) * 14}px` }}>
                        <span class="text-ink-dim">{n.branch}</span>
                        <Show when={n.stackedOn}>{(so) => <span>builds on {so().pr ? `#${so().pr}` : so().branch.split("/").pop()}</span>}</Show>
                        <Show when={n.requires.length}><span>requires {n.requires.map((r) => r.split("/").pop()).join(", ")}</span></Show>
                        <Show when={n.after.length}><span>after {n.after.map((r) => r.split("/").pop()).join(", ")}</span></Show>
                        <Show when={n.subjects.length > 1}><span>{n.commits} commits</span></Show>
                        <Show when={!n.pr}><GatesChip n={n} /></Show>
                        <PrChip n={n} />
                      </div>
                    </div>
                  </li>
                )}
              </For>
            </ol>
          </>
        )}
      </Show>
    </div>
  );
}
