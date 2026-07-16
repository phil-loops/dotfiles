// The Activity dock — a read-only census of everything the viewer set in motion: chat
// jobs, restacks walking a forest, and fired claudes editing in worktrees. The Hearth
// alarms on restack *tangles* at home; this is the always-available list of live work,
// including fired claudes, which nothing else in the viewer surfaces. Polls /processes.
// Dev-server previews don't list inline — they collapse to one launcher that opens the
// Servers drawer (health, connections, restart/kill/log live there, not as dock rows).
import { createQuery } from "@tanstack/solid-query";
import { createSignal, Show, For } from "solid-js";
import { openServers } from "./ServersDrawer";
import "./Activity.css";

type Proc = {
  kind: "chat" | "restack" | "claude" | "preview";
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
  working?: boolean;
  count?: number;
  url?: string; // preview: the side-port dev server
  dir?: string; // preview: the worktree dir
};

const GLYPH: Record<string, string> = { chat: "✦", restack: "⟳", claude: "◆", preview: "▷" };

export function Activity() {
  const q = createQuery<Proc[]>(() => ({
    queryKey: ["processes"],
    queryFn: () => fetch("/processes").then((r) => r.json() as Promise<Proc[]>),
    refetchInterval: 3000,
  }));
  const procs = () => q.data ?? [];
  const previews = () => procs().filter((p) => p.kind === "preview");
  const other = () => procs().filter((p) => p.kind !== "preview");
  const serversUp = () => previews().filter((p) => p.status === "up").length;
  // the chip counts agents that are actually WORKING, not merely alive — a claude parked at its
  // prompt for hours shouldn't inflate the number (that was the "random shit"). Previews count too.
  const running = () => other().filter((p) => p.working !== false && !p.done).length + serversUp();
  // working first, then idle-but-alive, then done — the noisy stale rows sink to the bottom.
  const rows = () =>
    [...other()].sort(
      (a, b) =>
        Number(a.done) - Number(b.done) ||
        Number(b.working !== false) - Number(a.working !== false)
    );
  // Collapsed to a count chip by default — an always-expanded list over every route reads as
  // noise; the ambient "something's running" signal is worth one glance-able dot, the detail is
  // opt-in on click.
  const [open, setOpen] = createSignal(false);

  return (
    <Show when={procs().length > 0}>
      <div class="activity-root" classList={{ collapsed: !open() }}>
        <button
          class="activity-head"
          onClick={() => setOpen(!open())}
          title={open() ? "collapse" : `${running()} background ${running() === 1 ? "process" : "processes"} running — click to expand`}
        >
          <span class="sig" classList={{ hot: running() > 0 }} />
          <Show when={open()}>
            <span class="lede">Activity</span>
          </Show>
          <span class="count">
            {open() ? (running() > 0 ? `${running()} running` : "idle") : running() > 0 ? running() : ""}
          </span>
        </button>
        <Show when={open()}>
          <div class="activity-list">
            {/* dev servers → one launcher into the Servers drawer, never inline rows */}
            <Show when={previews().length > 0}>
              <button class="activity-row launcher" onClick={() => openServers()} title="open the Servers panel — health, connections, restart/kill/logs">
                <span class="glyph" data-kind="preview">▷</span>
                <span class="label">{previews().length} dev {previews().length === 1 ? "server" : "servers"}</span>
                <span class="status">{serversUp()} up</span>
                <span class="age">›</span>
              </button>
            </Show>
            <For each={rows()}>
              {(p) => (
                <div class="activity-row" classList={{ done: p.done, bad: p.ok === false, idle: p.working === false }}>
                  <span class="glyph" data-kind={p.kind}>{GLYPH[p.kind] ?? "•"}</span>
                  <span class="label" title={`${p.kind} · ${p.target}`}>{p.label}</span>
                  <Show when={(p.count ?? 1) > 1}>
                    <span class="mult" title="two agents on one branch — probable duplicate spawn">×{p.count}</span>
                  </Show>
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
