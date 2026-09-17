import { createResource, For, Show, createEffect } from "solid-js";
import { withRepo } from "./provider";
import { openStorySheet, storySheetOpen } from "./StorySheet";

// ── the node page's forest-steps strip ──────────────────────────────────────────────────────
// A READ of the forest plan while you write the commit message: every step in merge order, the
// effective line, this branch marked. It no longer edits — a one-line input squeezed into the
// message box truncated every story it was meant to author. Clicking a line opens the story
// sheet (StorySheet, mounted in App) focused on that step.
type Step = { n: number; branch: string; job: string; story: string; landed: boolean; me: boolean };

export function PlanStepsEditor(props: { branch: string; onSaved?: () => void }) {
  const [data, { refetch }] = createResource(
    () => props.branch,
    (b) => fetch(withRepo("/plan-steps") + "?branch=" + encodeURIComponent(b))
      .then((r) => r.json() as Promise<{ project: string | null; steps: Step[] }>),
  );

  // the sheet writes stories straight to their branches; when it closes, re-read the plan so
  // these lines (and the commit body's plan block) show what was just written
  let wasOpen = false;
  createEffect(() => {
    const open = storySheetOpen();
    if (wasOpen && !open) {
      void refetch();
      props.onSaved?.();
    }
    wasOpen = open;
  });

  return (
    <Show when={(data()?.steps?.length ?? 0) > 0}>
      <div class="plan-steps flex flex-col gap-[2px] border-b border-rule py-[4px]">
        <div class="plan-steps-head flex items-baseline gap-[10px] px-[1px] pt-[2px] pb-[5px] text-[10px] uppercase tracking-[0.07em] text-ink-faint">
          <span>forest steps — click a line to write that branch's durable story</span>
          <button
            class="ml-auto cursor-pointer border-0 bg-transparent p-0 text-[10px] normal-case tracking-normal text-gold-leaf hover:text-ink"
            title="open every branch's story at once — blank boxes, each branch's commits to read the point off"
            onClick={() => openStorySheet(props.branch)}
          >✎ stories ⤢</button>
        </div>
        <For each={data()!.steps}>
          {(s) => (
            <div class={`plan-step flex min-h-[26px] items-center gap-[8px] ${s.landed ? "landed opacity-50" : ""} ${s.me ? "me" : ""}`}>
              <span class={`ps-n min-w-[14px] flex-none text-right font-mono text-[11px] ${s.me ? "text-ember" : "text-gold-leaf"}`}>{s.n}</span>
              <button
                class="ps-line flex min-w-0 flex-1 cursor-pointer items-baseline gap-[10px] rounded-[5px] px-[6px] py-[3px] text-left leading-[1.55] text-ink-dim enabled:hover:bg-gold-wash enabled:hover:text-ink disabled:cursor-default"
                disabled={s.landed}
                title={s.landed ? "already merged — its line is its PR" : `write ${s.branch}'s story`}
                onClick={() => openStorySheet(props.branch, s.branch)}
              >
                <span class={`ps-job min-w-0 flex-1 overflow-hidden text-ellipsis whitespace-nowrap text-[12.5px] ${s.story ? "overridden text-gold-leaf" : ""}`}>{s.job}</span>
                <span class="ps-tail flex flex-none items-baseline gap-[8px]">
                  {s.me ? <span class="ps-me text-[9.5px] uppercase tracking-[0.06em] text-ember">this branch</span> : null}
                  <span class="ps-branch font-mono text-[10px] text-ink-faint">{s.branch}</span>
                </span>
              </button>
            </div>
          )}
        </For>
      </div>
    </Show>
  );
}
