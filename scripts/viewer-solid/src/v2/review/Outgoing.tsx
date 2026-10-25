// The review page's third tab: exactly what's about to leave the machine for this branch — the
// unpushed commits (↵ or a click opens one's own diff in the history), the threads each one
// addresses and the "done in" replies that ride the push, the PR text a first push creates, each
// gate's state on this exact tip, and one push for a first push and follow-ups alike.
import { createEffect, createResource, For, onCleanup, onMount, Show } from "solid-js";
import Commits from "../Commits";
import { gateRows, type GateRow, type Progress } from "../gates";
import { model } from "../model";
import { keyOf } from "../registry";
import { bind } from "../runner";
import { canPush, leaf } from "../ship";
import { list, view } from "../store";
import { getJSON } from "../sync";
import type { Thread } from "../types";
import { armed, now } from "../ui";
import { atRepoPath, page as pg, short } from "./page";
import { withFix } from "./Thread";

const MARK: Record<GateRow["state"], string> = { queued: "·", running: "◌", green: "✓", red: "✗", stopped: "■" };
const secs = (ms: number | null) => (ms == null ? "" : ms >= 60000 ? `${Math.floor(ms / 60000)}m ${Math.round((ms % 60000) / 1000)}s` : `${(ms / 1000).toFixed(1)}s`);

export default function Outgoing() {
  const v = () => model.branchView(pg.id());
  const b = () => v()?.b;
  onMount(() => void pg.loadHistory());
  const unpushed = () => (pg.history()?.rows ?? []).filter((c) => c.pushed === false);
  const threads = () => list("thread").filter((t) => t.repo === b()?.repo && t.branch === b()?.name) as Thread[];
  // /commits gives short shas, a thread's fixedBy full ones
  const addressedBy = (sha: string) => threads().filter((t) => t.fixedBy?.some((f) => f.sha.startsWith(sha)));
  const riding = () => pg.items().filter((i) => i.kind === "reply" && (i.waitsFor.length || i.fixFor));
  /** an addressed thread with no reply on its way yet — a trailer written by hand or by Claude */
  const unanswered = (t: Thread) => !riding().some((i) => i.fixFor?.toLowerCase() === t.comments[0]?.url?.toLowerCase());

  const [progress, { refetch }] = createResource(
    () => (b() ? `${b()!.repo}|${b()!.name}|${b()!.tip}` : null),
    () => getJSON<Progress>(atRepoPath(b()!.repo, `/gates-progress?branch=${encodeURIComponent(b()!.name)}`)).catch(() => null),
  );
  createEffect(() => {
    if (!progress()?.running) return;
    const t = window.setTimeout(() => void refetch(), 2000);
    onCleanup(() => clearTimeout(t));
  });
  const rows = () => (now(), gateRows(progress(), Date.now() / 1000));
  const pushable = () => !!v() && canPush(v()!.b, v()!.pr);

  return (
    <div class="rv-outgoing">
      <div class="rv-commit-head">
        <Show when={b()} fallback={<span class="text-ink-faint">this branch isn't local</span>}>
          <span class="text-ink">
            {unpushed().length
              ? `${unpushed().length} commit${unpushed().length === 1 ? "" : "s"} leave${unpushed().length === 1 ? "s" : ""} for origin/${leaf(b()!.name)}`
              : "nothing to push — origin has every commit"}
          </span>
          <span class="text-ink-faint">
            {" "}· {v()?.pr ? `follow-ups onto #${v()!.pr!.number}` : "a first push — then the PR"} · tip <code>{short(b()!.tip)}</code> · gates {b()!.gates} on it
          </span>
          <div class="mt-2">
            <button class="rv-btn rv-btn-gold" disabled={!pushable()} onClick={bind("review.push", pg.id())}>
              {armed() === pg.id() ? `${keyOf("review.push")} again sends it` : "Push"} <kbd>{keyOf("review.push")}</kbd>
            </button>
            <Show when={!pushable() && unpushed().length}>
              <span class="ml-3 text-[12px] text-ink-faint">{b()!.gates !== "green" ? "waits for the gates to go green on this tip" : "a push is in flight"}</span>
            </Show>
          </div>
        </Show>
      </div>

      <div class="rv-words-k">gates on this tip</div>
      <Show when={rows().length} fallback={<p class="rv-quiet">{progress.loading ? "reading the gates…" : "no gates run for this tip yet"}</p>}>
        <ol class="m-0 mb-4 list-none p-0">
          <For each={rows()}>
            {(g) => (
              <li class="flex gap-3 py-0.5 text-[12.5px]">
                <span class="w-4" classList={{ "text-patina": g.state === "green", "text-ember": g.state === "red" || g.state === "stopped", "text-gold-leaf": g.state === "running", "text-ink-faint": g.state === "queued" }}>
                  {MARK[g.state]}
                </span>
                <span class="w-24 text-ink">{g.name}</span>
                <span class="w-24 text-ink-faint">{g.state === "stopped" ? "stopped, no result" : g.state}</span>
                <span class="w-16 text-right text-ink-faint">{secs(g.ms)}</span>
                <span class="min-w-0 flex-1 truncate text-ink-faint">{g.summary}</span>
              </li>
            )}
          </For>
        </ol>
      </Show>

      <Show when={!v()?.pr && b()}>
        <Commits branchId={pg.id()} landing landingOnly />
      </Show>

      <div class="rv-words-k">commits that leave</div>
      <For each={unpushed()} fallback={<p class="rv-quiet">{pg.history() ? "none" : "reading the commits…"}</p>}>
        {(c) => (
          <div class="mb-3">
            <button class="rv-hrow" onClick={bind("history.select", c.sha)} title="its own diff, in the history">
              <span class="rv-hsub">
                <code class="text-gold-leaf">{c.sha.slice(0, 7)}</code> {c.subject}
              </span>
              <span class="rv-hmeta">{c.author} · {c.date} · opens its diff</span>
            </button>
            <Show when={c.body}>
              <pre class="m-0 ml-2 mt-1 whitespace-pre-wrap font-mono text-[12px] text-ink-dim">{c.body}</pre>
            </Show>
            <For each={addressedBy(c.sha)}>
              {(t) => (
                <div class="ml-2 mt-1 text-[12px] text-gold-leaf">
                  addresses {t.comments[0]?.author} on {t.path.split("/").pop()}:{t.local?.line ?? t.line}
                  <Show when={unanswered(t)}>
                    {" "}
                    <button class="rv-quietbtn" onClick={bind("review.address.reply", t.id)}>
                      draft "done in {c.sha.slice(0, 7)}"
                    </button>
                  </Show>
                </div>
              )}
            </For>
          </div>
        )}
      </For>

      <Show when={riding().length}>
        <div class="rv-words-k">replies that ride the push</div>
        <For each={riding()}>
          {(it) => (
            <div class="mb-1 text-[12.5px]">
              <span class="text-ink">{withFix(it)}</span>
              <span class="text-ink-faint"> · {it.waitingFix ? "waits for a commit that addresses it" : it.err ? it.err : "into your pending review once the push lands"}</span>
            </div>
          )}
        </For>
      </Show>
    </div>
  );
}
