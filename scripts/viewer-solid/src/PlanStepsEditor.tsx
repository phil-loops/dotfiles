import { createSignal, createResource, For, Show, onCleanup } from "solid-js";
import { withRepo } from "./provider";
import { useViewerLocation, withNode } from "./router";
import { StoriesEditor } from "./StoriesEditor";

// ── the node page's forest-steps strip, and the story editor it opens ───────────────────────
// The strip is a READ of the forest plan while you write the commit message: every step in merge
// order, the effective line, this branch marked. It no longer edits — a one-line input squeezed
// into the message box truncated every story it was meant to author. Clicking a line opens the
// real editor (the same one the forest's ✎ stories face uses) over the page, focused on that
// step: full-width wrapping boxes that start blank, each branch's commits to read the point off,
// and the 15s undo.
//
// Editing a line writes that step's OWN branch (stack-branch.<b>.story), so the wording is
// durable — it renders on every branch's plan AND survives after this branch merges, instead of
// being frozen as text in one sibling's commit body.
type Step = { n: number; branch: string; job: string; story: string; landed: boolean; me: boolean };

export function PlanStepsEditor(props: { branch: string; onSaved?: () => void }) {
  const { location, navigate } = useViewerLocation();
  const [data, { refetch }] = createResource(
    () => props.branch,
    (b) => fetch(withRepo("/plan-steps") + "?branch=" + encodeURIComponent(b))
      .then((r) => r.json() as Promise<{ project: string | null; steps: Step[] }>),
  );
  // which step the editor opens focused on — "" while closed
  const [open, setOpen] = createSignal<string | null>(null);

  const close = () => {
    setOpen(null);
    void refetch();
    props.onSaved?.();
  };
  const onKey = (e: KeyboardEvent) => {
    if (e.key === "Escape" && open() && !(e.target as HTMLElement)?.closest(".stories-input")) close();
  };
  window.addEventListener("keydown", onKey);
  onCleanup(() => window.removeEventListener("keydown", onKey));

  return (
    <>
      <Show when={(data()?.steps?.length ?? 0) > 0}>
        <div class="plan-steps flex flex-col gap-[2px] border-b border-rule py-[4px]">
          <div class="plan-steps-head flex items-baseline gap-[10px] px-[1px] pt-[2px] pb-[5px] text-[10px] uppercase tracking-[0.07em] text-ink-faint">
            <span>forest steps — click a line to write that branch's durable story</span>
            <button
              class="ml-auto cursor-pointer border-0 bg-transparent p-0 text-[10px] normal-case tracking-normal text-gold-leaf hover:text-ink"
              title="open every branch's story at once — blank boxes, each branch's commits to read the point off"
              onClick={() => setOpen(props.branch)}
            >✎ stories ⤢</button>
          </div>
          <For each={data()!.steps}>
            {(s) => (
              <div class={`plan-step flex min-h-[26px] items-center gap-[8px] ${s.landed ? "landed opacity-50" : ""} ${s.me ? "me" : ""}`}>
                <span class={`ps-n min-w-[14px] flex-none text-right font-mono text-[11px] ${s.me ? "text-ember" : "text-gold-leaf"}`}>{s.n}</span>
                <button
                  class="ps-line flex flex-1 cursor-pointer items-baseline gap-[10px] rounded-[5px] px-[6px] py-[3px] text-left leading-[1.55] text-ink-dim min-w-0 enabled:hover:bg-gold-wash enabled:hover:text-ink disabled:cursor-default"
                  disabled={s.landed}
                  title={s.landed ? "already merged — its line is its PR" : `write ${s.branch}'s story`}
                  onClick={() => setOpen(s.branch)}
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

      <Show when={open() && data()?.project}>
        <div
          class="stories-backdrop fixed inset-0 z-[120] flex justify-center overflow-y-auto bg-[rgba(8,6,3,0.9)] backdrop-blur-[2px] py-[28px] px-[16px]"
          onClick={close}
        >
          <div
            class="stories-sheet h-fit w-full max-w-[940px] rounded-[12px] border border-rule bg-vellum-night shadow-[0_18px_50px_rgba(0,0,0,0.55)]"
            onClick={(e) => e.stopPropagation()}
          >
            <header class="flex items-baseline gap-[10px] border-x-0 border-t-0 border-b border-solid border-rule px-[18px] py-[12px] font-mono">
              <span class="text-[13px] text-ink">✎ stories</span>
              <span class="text-[10.5px] text-ink-faint">each line is that branch's own — durable past this branch's merge</span>
              <button
                class="ml-auto cursor-pointer border-0 bg-transparent p-0 text-[11px] text-ink-faint hover:text-ink"
                title="close (esc)"
                onClick={close}
              >close ✕</button>
            </header>
            <StoriesEditor
              project={data()!.project!}
              branch={props.branch}
              here={props.branch}
              focus={open()!}
              onPick={(b) => { close(); navigate(withNode(location(), b)); }}
            />
          </div>
        </div>
      </Show>
    </>
  );
}
