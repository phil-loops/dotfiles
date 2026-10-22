// The archive: forests dropped from both focus and the workbench. Hidden everywhere else (forests
// page, outbox, pregates) — nothing deleted; restoring puts a forest back on the workbench.
import { createQuery, useQueryClient } from "@tanstack/solid-query";
import { createSignal, For, Show } from "solid-js";
import { canMutate } from "./provider";
import { setProjectState } from "./projectState";

type Archived = { project: string; repo: string; branches: number; lastCommit: number };

const ago = (unix: number): string => {
  if (!unix) return "no branches left";
  const d = Math.floor((Date.now() / 1000 - unix) / 86400);
  return d < 1 ? "today" : d === 1 ? "1 day ago" : `${d} days ago`;
};

export function ArchiveFold() {
  const qc = useQueryClient();
  const [open, setOpen] = createSignal(false);
  const q = createQuery(() => ({
    queryKey: ["archived"],
    queryFn: () => fetch("/archived").then((r) => r.json() as Promise<Archived[]>),
    enabled: open(),
  }));
  const count = createQuery(() => ({
    queryKey: ["archived-count"],
    queryFn: () => fetch("/archived").then((r) => r.json() as Promise<Archived[]>).then((a) => a.length),
    staleTime: 60_000,
  }));
  const restore = (a: Archived) =>
    void setProjectState(a.repo, a.project, "workbench").then(() => {
      qc.invalidateQueries({ queryKey: ["archived"] });
      qc.invalidateQueries({ queryKey: ["archived-count"] });
      qc.invalidateQueries({ queryKey: ["projects"] });
    });
  return (
    <Show when={(count.data ?? 0) > 0}>
      <button
        class="forest-archive mt-[18px] block w-full cursor-pointer px-1 pt-[9px] pb-[5px] text-left text-[11px] leading-[1.55] tracking-[0.03em] text-ink-faint hover:text-ink-dim"
        onClick={() => setOpen((v) => !v)}
      >
        {open() ? "▾" : "▸"} archive · {count.data}
      </button>
      <Show when={open()}>
        <ul class="m-0 mt-[4px] list-none p-0">
          <For each={q.data ?? []}>
            {(a) => (
              <li class="group flex items-baseline gap-[10px] px-1 py-[3px] font-mono text-[11.5px]">
                <span class="min-w-0 flex-1 truncate text-ink-dim">{a.project}</span>
                <Show when={a.repo && a.repo !== "loops"}><span class="text-[10px] uppercase text-ink-faint">{a.repo}</span></Show>
                <span class="text-[10.5px] text-ink-faint">{ago(a.lastCommit)}</span>
                <Show when={canMutate}>
                  <button
                    class="cursor-pointer border-0 bg-transparent p-0 text-[10.5px] text-ink-faint opacity-0 group-hover:opacity-100 hover:text-gold-leaf"
                    title="back on the workbench"
                    onClick={() => restore(a)}
                  >restore</button>
                </Show>
              </li>
            )}
          </For>
        </ul>
      </Show>
    </Show>
  );
}
