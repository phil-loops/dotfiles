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
      <div class="plan-steps">
        <div class="plan-steps-head">forest steps — edit a line to set that branch's durable story</div>
        <For each={data()!.steps}>
          {(s) => (
            <div class="plan-step" classList={{ me: s.me, landed: s.landed }}>
              <span class="ps-n">{s.n}</span>
              <Show
                when={editing() === s.branch}
                fallback={
                  <button
                    class="ps-line"
                    disabled={s.landed}
                    title={s.landed ? "already merged — its line is its PR" : `edit — writes ${s.branch}'s durable story`}
                    onClick={() => begin(s)}
                  >
                    <span class="ps-job" classList={{ overridden: !!s.story }}>{s.job}</span>
                    <span class="ps-tail">
                      {s.me ? <span class="ps-me">this branch</span> : null}
                      <span class="ps-branch">{s.branch}</span>
                    </span>
                  </button>
                }
              >
                <input
                  ref={inputEl}
                  class="ps-input"
                  value={draft()}
                  disabled={busy()}
                  onInput={(e) => setDraft(e.currentTarget.value)}
                  onKeyDown={(e) => {
                    if (e.key === "Enter") commit(s.branch, draft().trim());
                    if (e.key === "Escape") setEditing(null);
                  }}
                />
                <button class="ps-btn ps-save" disabled={busy()} onClick={() => commit(s.branch, draft().trim())}>save</button>
                <Show when={s.story}>
                  <button class="ps-btn" disabled={busy()} title="clear the override — revert to the commit-subject line" onClick={() => commit(s.branch, "")}>reset</button>
                </Show>
                <button class="ps-btn" disabled={busy()} onClick={() => setEditing(null)}>cancel</button>
              </Show>
            </div>
          )}
        </For>
      </div>
    </Show>
  );
}
