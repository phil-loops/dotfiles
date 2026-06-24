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
import "./Hearth.css";

const leaf = (s?: string): string => (s || "").split("/").pop() ?? "";

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
      <div class="hearth-root">
        <Show
          when={tangle()}
          fallback={
            <div
              class="hearth"
              classList={{ "is-running": !!s()?.running, "is-parked": !!s()?.paused && !s()?.running }}
            >
              <span class="sig" />
              <Show
                when={s()?.paused && !s()?.running}
                fallback={
                  <>
                    <span class="lede">Restacking {s()?.project}</span>
                    <span class="meta">
                      <Show when={s()?.current} fallback={<>starting the walk…</>}>
                        <Show when={s()?.total}>
                          node {s()?.done != null ? s()!.done! + 1 : 1} of {s()?.total} ·{" "}
                        </Show>
                        rebasing <b>{leaf(s()!.current!)}</b>
                      </Show>
                    </span>
                  </>
                }
              >
                <span class="lede">Parked at {leaf(s()?.current || s()?.project || "")}</span>
                <span class="meta">{s()?.reason || "needs a hand — hand it to Claude or abort"}</span>
              </Show>
              <span class="count">
                {drivers().length || (s()?.running ? 1 : 0)} driver
                {(drivers().length || 1) === 1 ? "" : "s"}
                <Show when={resolvers() > 0}> · claude resolving</Show>
              </span>
              <Show when={canMutate && s()?.running}>
                <button class="hearth-btn" disabled={stopping()} onClick={stop}>
                  {stopping() ? "stopping…" : "■ stop"}
                </button>
              </Show>
              <Show when={abortErr()}>
                <span class="hearth-err">{abortErr()}</span>
              </Show>
            </div>
          }
        >
          <div class="hearth-alarm">
            <div class="bar">
              <span class="sig">◆◆</span>
              <span class="msg">{alarmMsg()}</span>
              <Show when={canMutate}>
                <span class="act">
                  <button class="hearth-btn" disabled={aborting()} onClick={abort}>
                    {aborting() ? "aborting…" : "Abort the race"}
                  </button>
                  <Show when={abortErr()}>
                    <span class="hearth-err">{abortErr()}</span>
                  </Show>
                </span>
              </Show>
            </div>
            <div class="rows">
              <For each={drivers()}>
                {(d, i) => (
                  <div class="arow" classList={{ first: i() === 0 }}>
                    <span class="pid">pid {d.pid}</span>
                    <span class="desc">
                      driving <b>{d.project || d.mode}</b>
                      {d.mode !== "start" && d.project ? ` · ${d.mode}` : ""}
                    </span>
                    <span class="age">{d.etime ? `${d.etime} in` : ""}</span>
                  </div>
                )}
              </For>
              <Show when={resolvers() > 1}>
                <div class="arow">
                  <span class="pid">claude ×{resolvers()}</span>
                  <span class="desc">
                    <b>{resolvers()}</b> resolvers spawned on the same conflict
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
