import { createResource, createSignal, Show, onCleanup } from "solid-js";
import { withRepo } from "./provider";
import { useViewerLocation, withNode } from "./router";
import { StoriesEditor } from "./StoriesEditor";

// Which branch's forest the sheet is open over, and which row it lands on. Module scope for the
// same reason overviewView is: the sheet opens from the node page's steps strip, from ⌘K, from
// anywhere — and it is mounted ONCE in App, not inside whatever surface asked for it. It used to
// live inside the commit-message editor, which gated story-writing behind having an outgoing
// commit and opening that editor first.
type SheetTarget = { branch: string; focus?: string };

const [storySheet, setStorySheet] = createSignal<SheetTarget | null>(null);

export const openStorySheet = (branch: string, focus?: string) => setStorySheet({ branch, focus });
export const closeStorySheet = () => setStorySheet(null);
export const storySheetOpen = () => !!storySheet();

// The story editor as a sheet over whatever you were looking at: every branch of the forest in
// merge order, blank boxes, each branch's commits to read the point off. Mounted once in App and
// opened by module signal (the node page's steps strip, ⌘K), so writing a story never depends on
// a branch having outgoing work or on the commit-message editor being open.
export function StorySheet() {
  const { location, navigate } = useViewerLocation();
  const [data] = createResource(
    () => storySheet()?.branch,
    (b) => fetch(withRepo("/plan-steps") + "?branch=" + encodeURIComponent(b))
      .then((r) => r.json() as Promise<{ project: string | null }>),
  );

  // esc closes the sheet — except inside a story box, where esc reverts that line (StoriesEditor)
  const onKey = (e: KeyboardEvent) => {
    if (e.key === "Escape" && storySheet() && !(e.target as HTMLElement)?.closest(".stories-input")) {
      e.stopPropagation();
      closeStorySheet();
    }
  };
  window.addEventListener("keydown", onKey);
  onCleanup(() => window.removeEventListener("keydown", onKey));

  return (
    <Show when={storySheet()}>
      {(sheet) => (
        <div
          class="stories-backdrop fixed inset-0 z-[120] flex items-center justify-center overflow-hidden bg-[rgba(8,6,3,0.9)] px-[16px] py-[24px] backdrop-blur-[2px]"
          onClick={closeStorySheet}
        >
          <div
            class="stories-sheet flex h-[min(90vh,1000px)] w-full max-w-[1320px] flex-col overflow-hidden rounded-[12px] border border-rule bg-vellum-night shadow-[0_18px_50px_rgba(0,0,0,0.55)]"
            onClick={(e) => e.stopPropagation()}
          >
            <header class="flex flex-none items-baseline gap-[10px] border-x-0 border-t-0 border-b border-solid border-rule px-[18px] py-[12px] font-mono">
              <span class="text-[13px] text-ink">✎ stories</span>
              <span class="text-[10.5px] text-ink-faint">each line is that branch's own — durable past its merge</span>
              <button
                class="ml-auto cursor-pointer border-0 bg-transparent p-0 text-[11px] text-ink-faint hover:text-ink"
                title="close (esc)"
                onClick={closeStorySheet}
              >close ✕</button>
            </header>
            <div class="flex min-h-0 flex-1 flex-col">
            <Show
              when={data()?.project}
              fallback={<p class="px-[18px] py-[22px] font-mono text-[12px] italic text-ink-faint">{data.loading ? "reading the forest…" : "this branch isn't in a forest — no plan to tell"}</p>}
            >
              <StoriesEditor
                project={data()!.project!}
                branch={sheet().branch}
                here={sheet().branch}
                focus={sheet().focus ?? sheet().branch}
                onPick={(b) => { closeStorySheet(); navigate(withNode(location(), b)); }}
              />
            </Show>
            </div>
          </div>
        </div>
      )}
    </Show>
  );
}
