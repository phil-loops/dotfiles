// The Hearth — the home ledger's live-activity strip. The ledger records what's
// BLESSED; the Hearth records what's IN MOTION: a restack walking the forest, a
// conflict handed to Claude. It polls /restack-status and renders nothing when idle.
//
// Its real job is the alarm: the day this was written, two restack drivers raced one
// worktree and three resolvers piled on one conflict — invisible until someone ran
// `ps`. A boolean `running` can't see that; the server now returns the driver LIST, and
// when it's longer than one the strip goes hot and names the race.
import { createQuery } from "@tanstack/solid-query";
import { createSignal, Show, For } from "solid-js";
import { provider, canMutate } from "./provider";
import type { RestackStatus } from "./types";

const leaf = (s?: string): string => (s || "").split("/").pop() ?? "";

// The Hearth's ember is the ledger's warm del tone (#c87a55), deliberately NOT the global
// ember token; the hot hue (#e2643a) appears ONLY on a tangle so its rarity is its alarm.
const BTN =
  "hearth-btn cursor-pointer rounded-md border border-[#e2643a] bg-transparent px-[13px] py-[7px] font-mono text-[12px] text-[#e2643a] hover:bg-[rgba(226,100,58,0.12)] disabled:cursor-default disabled:opacity-50";
const ERR = "hearth-err ml-[10px] self-center text-[11px] text-[#e2643a]";
const ROW =
  "arow flex items-center gap-3 border-b border-dashed border-[rgba(226,100,58,0.15)] py-[6px] text-[12px] last:border-b-0";

const post = (url: string, body: unknown): Promise<{ ok?: boolean; err?: string }> =>
  fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  }).then((r) => r.json());

export function Hearth() {
  const q = createQuery<RestackStatus>(() => ({
    queryKey: ["hearth-status"],
    queryFn: () => provider.restackStatus(),
    refetchInterval: 2000,
    enabled: canMutate, // a baked static snapshot has no live engine to watch
  }));

  const s = () => q.data;
  const drivers = () => s()?.drivers ?? [];
  const resolvers = () => s()?.resolvers ?? 0;
  const active = () => {
    const d = s();
    return !!d && (d.running || d.paused || drivers().length > 0);
  };
  // a batch ("all") driver runs its per-project children REENTRANTLY under one shared lock —
  // 1 batch + ≤1 worker is the normal batch shape, NOT a race. A real tangle is ≥2 batch runs,
  // ≥2 independent single-project workers, or ≥2 resolvers piled on one conflict.
  const tangle = () => {
    const batch = drivers().filter((d) => d.mode === "all").length;
    const workers = drivers().length - batch;
    return batch > 1 || workers > 1 || resolvers() > 1;
  };

  const [aborting, setAborting] = createSignal(false);
  const [abortErr, setAbortErr] = createSignal<string | null>(null);
  const abort = () => {
    const project = s()?.project || drivers()[0]?.project || "";
    setAborting(true);
    setAbortErr(null);
    post("/restack-abort", { project })
      .then((r) => {
        // /restack-abort only clears a PARKED conflict — it refuses while a restack process is
        // still churning. Surface that instead of failing silently.
        if (!r?.ok) setAbortErr(r?.err || "couldn’t abort — a restack is still running");
      })
      .catch(() => setAbortErr("abort failed — server unreachable"))
      .finally(() => {
        setAborting(false);
        void q.refetch();
      });
  };

  const [stopping, setStopping] = createSignal(false);
  const stop = () => {
    setStopping(true);
    setAbortErr(null);
    post("/restack-stop", {})
      .then((r) => {
        if (!r?.ok) setAbortErr(r?.err || "couldn’t stop the restack");
      })
      .catch(() => setAbortErr("stop failed — server unreachable"))
      .finally(() => {
        setStopping(false);
        void q.refetch();
      });
  };

  const alarmMsg = () => {
    const n = drivers().length;
    return n > 1
      ? `${n} restack drivers are live — they’re racing one worktree.`
      : "Duplicate resolvers are on one conflict.";
  };

  return (
    <Show when={active()}>
      <div class="hearth-root mt-[2px] mb-[18px]">
        <Show
          when={tangle()}
          fallback={
            <div
              class="hearth flex items-center gap-3 rounded-[7px] border border-rule border-l-2 border-l-del px-[14px] py-[9px]"
              classList={{
                "is-running": !!s()?.running,
                "is-parked bg-[rgba(200,122,85,0.1)]": !!s()?.paused && !s()?.running,
                "bg-[linear-gradient(90deg,rgba(200,122,85,0.1),transparent_70%)]": !(s()?.paused && !s()?.running),
              }}
            >
              <span
                class="sig h-[7px] w-[7px] flex-none rounded-full bg-del"
                classList={{ "animate-hearth-breathe motion-reduce:animate-none": !!s()?.running }}
              />
              <Show
                when={s()?.paused && !s()?.running}
                fallback={
                  <>
                    <span class="lede font-display text-[16px] italic text-[#f0d3b6]">Restacking {s()?.project}</span>
                    <span class="meta text-[11px] tracking-[0.04em] text-ink-dim">
                      <Show when={s()?.current} fallback={<>starting the walk…</>}>
                        <Show when={s()?.total}>
                          node {s()?.done != null ? s()!.done! + 1 : 1} of {s()?.total} ·{" "}
                        </Show>
                        rebasing <b class="font-medium text-ink">{leaf(s()!.current!)}</b>
                      </Show>
                    </span>
                  </>
                }
              >
                <span class="lede font-display text-[16px] italic text-[#f0d3b6]">
                  Parked at {leaf(s()?.current || s()?.project || "")}
                </span>
                <span class="meta text-[11px] tracking-[0.04em] text-ink-dim">
                  {s()?.reason || "needs a hand — hand it to Claude or abort"}
                </span>
              </Show>
              <span class="count ml-auto text-[10px] uppercase tracking-[0.16em] text-ink-faint">
                {drivers().length || (s()?.running ? 1 : 0)} driver
                {(drivers().length || 1) === 1 ? "" : "s"}
                <Show when={resolvers() > 0}> · claude resolving</Show>
              </span>
              <Show when={canMutate && s()?.running}>
                <button class={BTN} disabled={stopping()} onClick={stop}>
                  {stopping() ? "stopping…" : "■ stop"}
                </button>
              </Show>
              <Show when={abortErr()}>
                <span class={ERR}>{abortErr()}</span>
              </Show>
            </div>
          }
        >
          <div class="hearth-alarm animate-hearth-alarm-pulse overflow-hidden rounded-lg border border-[#e2643a] bg-[rgba(226,100,58,0.12)] motion-reduce:animate-none">
            <div class="bar flex items-center gap-3 border-b border-[rgba(226,100,58,0.22)] px-4 py-3">
              <span class="sig text-[15px] text-[#e2643a]">◆◆</span>
              <span class="msg font-display text-[17px] italic text-[#f4c3aa]">{alarmMsg()}</span>
              <Show when={canMutate}>
                <span class="act ml-auto">
                  <button class={BTN} disabled={aborting()} onClick={abort}>
                    {aborting() ? "aborting…" : "Abort the race"}
                  </button>
                  <Show when={abortErr()}>
                    <span class={ERR}>{abortErr()}</span>
                  </Show>
                </span>
              </Show>
            </div>
            <div class="rows px-4 pt-[6px] pb-3">
              <For each={drivers()}>
                {(d, i) => (
                  <div
                    class={ROW}
                    classList={{ first: i() === 0 }}
                  >
                    <span
                      class="pid min-w-[96px]"
                      classList={{ "text-ink-dim": i() === 0, "text-[#e2643a]": i() !== 0 }}
                    >
                      pid {d.pid}
                    </span>
                    <span class="desc text-ink-dim">
                      driving <b class="font-medium text-ink">{d.project || d.mode}</b>
                      {d.mode !== "start" && d.project ? ` · ${d.mode}` : ""}
                    </span>
                    <span class="age ml-auto text-ink-faint">{d.etime ? `${d.etime} in` : ""}</span>
                  </div>
                )}
              </For>
              <Show when={resolvers() > 1}>
                <div class={ROW}>
                  <span class="pid min-w-[96px] text-[#e2643a]">claude ×{resolvers()}</span>
                  <span class="desc text-ink-dim">
                    <b class="font-medium text-ink">{resolvers()}</b> resolvers spawned on the same conflict
                  </span>
                </div>
              </Show>
            </div>
          </div>
        </Show>
      </div>
    </Show>
  );
}
