import { For, Show } from "solid-js";
import type { ForestModel } from "./types";
import { leaf } from "./shared";

// Where this forest's work carries on somewhere else. stack-forest stops its descent at a child
// tagged into another project, so without this the map simply ends and a reviewer has no way to
// tell that a deferred strand exists — or where it hangs off. Quiet by design: one line, present
// only when there IS a continuation, and it reads as a pointer rather than an action.
export function ContinuesStrip(props: {
  model: () => ForestModel | undefined;
  onOpen: (project: string) => void;
}) {
  const rows = () => props.model()?.continues ?? [];
  return (
    <Show when={rows().length}>
      <div class="flex flex-wrap items-center gap-x-3 gap-y-1.5 px-6 pb-1 pt-3 font-mono text-[11.5px] text-ink-faint">
        <For each={rows()}>
          {(row) => (
            <button
              type="button"
              class="cursor-pointer rounded-[7px] border border-dashed border-rule bg-transparent px-2.5 py-1 text-ink-dim transition-colors hover:border-gold-deep hover:text-gold-leaf"
              title={row.branches.map(leaf).join(", ")}
              onClick={() => props.onOpen(row.project)}
            >
              continues in <b class="font-medium">{row.project}</b> ⇢ {row.branches.length}{" "}
              {row.branches.length === 1 ? "branch" : "branches"} off {leaf(row.from)}
            </button>
          )}
        </For>
      </div>
    </Show>
  );
}
