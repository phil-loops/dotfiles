// The Activity dock — a read-only census of everything the viewer set in motion: chat
// jobs, restacks walking a forest, and fired claudes editing in worktrees. The Hearth
// alarms on restack *tangles* at home; this is the always-available list of live work,
// including fired claudes, which nothing else in the viewer surfaces. Polls /processes.
import { createQuery } from "@tanstack/solid-query";
import { createSignal, Show, For } from "solid-js";
import "./Activity.css";

type Proc = {
  kind: "chat" | "restack" | "claude";
  id: string;
  label: string;
  target: string;
  status: string;
  detail: string;
  done: boolean;
  ok?: boolean | null;
  age: string;
  project?: string;
  repo?: string;
};

const GLYPH: Record<string, string> = { chat: "✦", restack: "⟳", claude: "◆" };

export function Activity() {
  const q = createQuery<Proc[]>(() => ({
    queryKey: ["processes"],
    queryFn: () => fetch("/processes").then((r) => r.json() as Promise<Proc[]>),
    refetchInterval: 3000,
  }));
  const procs = () => q.data ?? [];
  const running = () => procs().filter((p) => !p.done).length;
  const [open, setOpen] = createSignal(true);

  return (
    <Show when={procs().length > 0}>
      <div class="activity-root">
        <button class="activity-head" onClick={() => setOpen(!open())}>
          <span class="sig" classList={{ hot: running() > 0 }} />
          <span class="lede">Activity</span>
          <span class="count">
            {running() > 0 ? `${running()} running` : "idle"}
          </span>
        </button>
        <Show when={open()}>
          <div class="activity-list">
            <For each={procs()}>
              {(p) => (
                <div class="activity-row" classList={{ done: p.done, bad: p.ok === false }}>
                  <span class="glyph" data-kind={p.kind}>{GLYPH[p.kind] ?? "•"}</span>
                  <span class="label" title={`${p.kind} · ${p.target}`}>{p.label}</span>
                  <span class="status">{p.status}</span>
                  <Show when={p.kind === "chat"}>
                    <span class="detail">{p.detail}</span>
                  </Show>
                  <span class="age">{p.age}</span>
                </div>
              )}
            </For>
          </div>
        </Show>
      </div>
    </Show>
  );
}
