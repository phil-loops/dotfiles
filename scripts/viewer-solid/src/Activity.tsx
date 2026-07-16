// The Activity dock — a read-only census of everything the viewer set in motion: chat
// jobs, restacks walking a forest, and fired claudes editing in worktrees. The Hearth
// alarms on restack *tangles* at home; this is the always-available list of live work,
// including fired claudes, which nothing else in the viewer surfaces. Polls /processes.
// Dev-server previews don't list inline — they collapse to one launcher that opens the
// Servers drawer (health, connections, restart/kill/log live there, not as dock rows).
//
// Styling: Tailwind utilities against the ledger @theme. Ember marks work-in-motion,
// mirroring the Hearth; gold is never spent here (blessed only).
import { createQuery } from "@tanstack/solid-query";
import { createSignal, Show, For } from "solid-js";
import { openServers } from "./ServersDrawer";

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
const GLYPH_TINT: Record<string, string> = { chat: "text-patina", claude: "text-ink", preview: "text-patina" };
// state precedence for a row's glyph: broken > at-rest > the kind's own tint > ember default
const glyphTint = (p: Proc) =>
  p.ok === false ? "text-del"
  : p.done || p.working === false ? "text-ink-faint"
  : GLYPH_TINT[p.kind] ?? "text-ember";

const ROW = "flex items-baseline gap-2 border-b border-[rgba(44,37,23,0.5)] px-3 py-1.5 text-[12px] last:border-b-0";

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
      <div
        class="fixed bottom-3.5 left-3.5 z-40 max-w-[calc(100vw-28px)] overflow-hidden border border-rule bg-vellum-raise font-mono"
        classList={{
          "w-[300px] rounded-lg shadow-[0_10px_30px_rgba(0,0,0,0.4)]": open(),
          "w-auto rounded-full shadow-[0_4px_14px_rgba(0,0,0,0.3)]": !open(),
        }}
      >
        <button
          class="activity-head flex w-full cursor-pointer items-center text-left leading-[1.55] text-ink"
          classList={{
            "gap-[9px] border-l-2 border-l-ember bg-[linear-gradient(90deg,var(--color-ember-wash),transparent_70%)] px-3 py-[9px]": open(),
            "gap-[7px] bg-vellum-raise py-1.5 pr-3 pl-[11px]": !open(),
          }}
          onClick={() => setOpen(!open())}
          title={open() ? "collapse" : `${running()} background ${running() === 1 ? "process" : "processes"} running — click to expand`}
        >
          <span
            class="h-[7px] w-[7px] flex-none rounded-full"
            classList={{
              "bg-ink-faint": running() === 0,
              "bg-ember animate-breathe motion-reduce:animate-none": running() > 0,
            }}
          />
          <Show when={open()}>
            <span class="font-display text-[15px] italic text-[#f0d3b6]">Activity</span>
          </Show>
          <span
            classList={{
              "ml-auto text-[11px] tracking-[0.04em] text-ink-dim": open(),
              "text-[12px] text-ink tabular-nums": !open(),
            }}
          >
            {open() ? (running() > 0 ? `${running()} running` : "idle") : running() > 0 ? running() : ""}
          </span>
        </button>
        <Show when={open()}>
          <div class="max-h-[44vh] overflow-auto border-t border-rule">
            {/* dev servers → one launcher into the Servers drawer, never inline rows. One pip per
                server; "listening" is all the dock knows — real health is probed in the drawer. */}
            <Show when={previews().length > 0}>
              <button
                class={`activity-row launcher ${ROW} group w-full cursor-pointer text-left leading-[1.55] transition-colors duration-[120ms] hover:bg-vellum-edge`}
                onClick={() => openServers()}
                title="open the Servers panel — which branch each server runs, real health, restart · kill · log"
              >
                <span class="flex-none text-[12px] text-patina">▷</span>
                <span class="truncate text-ink">{previews().length} dev {previews().length === 1 ? "server" : "servers"}</span>
                <span class="inline-flex flex-none items-center gap-1">
                  <For each={previews()}>
                    {(p) => (
                      <span
                        class="h-1.5 w-1.5 rounded-full border"
                        classList={{
                          "border-patina bg-patina": p.status === "up",
                          "border-ink-faint bg-transparent": p.status !== "up",
                        }}
                        title={`${p.label} — ${p.status}`}
                      />
                    )}
                  </For>
                </span>
                <span class="flex-none text-[10px] uppercase tracking-[0.06em] text-ink-dim">{serversUp()} listening</span>
                <span class="ml-auto flex-none text-ink-faint transition-colors duration-[120ms] group-hover:text-ink">›</span>
              </button>
            </Show>
            <For each={rows()}>
              {(p) => (
                <div
                  class={`activity-row ${ROW}`}
                  classList={{ "opacity-55": p.done, "opacity-50": !p.done && p.working === false }}
                >
                  <span class={`flex-none text-[12px] ${glyphTint(p)}`}>{GLYPH[p.kind] ?? "•"}</span>
                  <span class="truncate text-ink" title={`${p.kind} · ${p.target}`}>{p.label}</span>
                  <Show when={(p.count ?? 1) > 1}>
                    <span class="flex-none text-[10px] text-ember tabular-nums" title="two agents on one branch — probable duplicate spawn">×{p.count}</span>
                  </Show>
                  <span class="flex-none text-[10px] uppercase tracking-[0.06em] text-ink-dim">{p.status}</span>
                  <Show when={p.kind === "chat"}>
                    <span class="flex-none text-ink-faint">{p.detail}</span>
                  </Show>
                  <span class="ml-auto flex-none text-ink-faint">{p.age}</span>
                </div>
              )}
            </For>
          </div>
        </Show>
      </div>
    </Show>
  );
}
