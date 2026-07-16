import { createSignal, createResource, For, Show } from "solid-js";
import { withRepo } from "./provider";

// ── per-step story editor ───────────────────────────────────────────────────
// The forest plan (the "Part of …" block) is regenerated on every branch from each step's own
// one-line story (job_of). Editing a line here writes that step's OWN branch (stack-branch.<b>.story),
// so the wording is durable — it renders on every branch's plan AND survives after this branch merges,
// instead of being frozen as text in one sibling's commit body.
type Step = { n: number; branch: string; job: string; story: string; landed: boolean; me: boolean };

const postStory = (branch: string, text: string) =>
  fetch(withRepo("/story"), {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ branch, text }),
  });

export function PlanStepsEditor(props: { branch: string; onSaved?: () => void }) {
  const [data, { refetch }] = createResource(
    () => props.branch,
    (b) => fetch(withRepo("/plan-steps") + "?branch=" + encodeURIComponent(b))
      .then((r) => r.json() as Promise<{ steps: Step[] }>),
  );
  const [editing, setEditing] = createSignal<string | null>(null);
  const [draft, setDraft] = createSignal("");
  const [busy, setBusy] = createSignal(false);
  let inputEl: HTMLInputElement | undefined;

  const begin = (s: Step) => {
    setEditing(s.branch);
    setDraft(s.job);
    requestAnimationFrame(() => inputEl?.focus());
  };
  const commit = async (branch: string, text: string) => {
    setBusy(true);
    await postStory(branch, text);
    setBusy(false);
    setEditing(null);
    await refetch();
    props.onSaved?.();
  };

  return (
    <Show when={(data()?.steps?.length ?? 0) > 0}>
      <div class="plan-steps flex flex-col gap-[2px] border-b border-rule py-[4px]">
        <div class="plan-steps-head px-[1px] pt-[2px] pb-[5px] text-[10px] uppercase tracking-[0.07em] text-ink-faint">forest steps — edit a line to set that branch's durable story</div>
        <For each={data()!.steps}>
          {(s) => (
            <div class={`plan-step flex min-h-[26px] items-center gap-[8px] ${s.landed ? "landed opacity-50" : ""} ${s.me ? "me" : ""}`}>
              <span class={`ps-n min-w-[14px] flex-none text-right font-mono text-[11px] ${s.me ? "text-ember" : "text-gold-leaf"}`}>{s.n}</span>
              <Show
                when={editing() === s.branch}
                fallback={
                  <button
                    class="ps-line flex flex-1 cursor-pointer items-baseline gap-[10px] rounded-[5px] px-[6px] py-[3px] text-left leading-[1.55] text-ink-dim min-w-0 enabled:hover:bg-gold-wash enabled:hover:text-ink disabled:cursor-default"
                    disabled={s.landed}
                    title={s.landed ? "already merged — its line is its PR" : `edit — writes ${s.branch}'s durable story`}
                    onClick={() => begin(s)}
                  >
                    <span class={`ps-job min-w-0 flex-1 overflow-hidden text-ellipsis whitespace-nowrap text-[12.5px] ${s.story ? "overridden text-gold-leaf" : ""}`}>{s.job}</span>
                    <span class="ps-tail flex flex-none items-baseline gap-[8px]">
                      {s.me ? <span class="ps-me text-[9.5px] uppercase tracking-[0.06em] text-ember">this branch</span> : null}
                      <span class="ps-branch font-mono text-[10px] text-ink-faint">{s.branch}</span>
                    </span>
                  </button>
                }
              >
                <input
                  ref={inputEl}
                  class="ps-input min-w-0 flex-1 rounded-[5px] border border-gold-deep bg-vellum-raise px-[7px] py-[4px] font-mono text-[12.5px] text-ink outline-none"
                  value={draft()}
                  disabled={busy()}
                  onInput={(e) => setDraft(e.currentTarget.value)}
                  onKeyDown={(e) => {
                    if (e.key === "Enter") commit(s.branch, draft().trim());
                    if (e.key === "Escape") setEditing(null);
                  }}
                />
                <button class="ps-btn ps-save flex-none cursor-pointer text-[11px] leading-[1.55] text-gold-leaf enabled:hover:text-ink" disabled={busy()} onClick={() => commit(s.branch, draft().trim())}>save</button>
                <Show when={s.story}>
                  <button class="ps-btn flex-none cursor-pointer text-[11px] leading-[1.55] text-ink-faint enabled:hover:text-ink" disabled={busy()} title="clear the override — revert to the commit-subject line" onClick={() => commit(s.branch, "")}>reset</button>
                </Show>
                <button class="ps-btn flex-none cursor-pointer text-[11px] leading-[1.55] text-ink-faint enabled:hover:text-ink" disabled={busy()} onClick={() => setEditing(null)}>cancel</button>
              </Show>
            </div>
          )}
        </For>
      </div>
    </Show>
  );
}
