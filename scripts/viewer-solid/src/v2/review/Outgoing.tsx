// The Commits tab with no commit selected: exactly what's about to leave the machine for this
// branch, read top to bottom — one push (first push and follow-ups alike), each gate's state on this
// exact tip, the "done in" replies that ride the push, the PR text a first push creates, then the
// change itself commit by commit, oldest first: each unpushed commit's message and its own diff.
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
import { parsePatch } from "./diff";
import { FOLD_OVER, diffs, isFolded, loadDiff } from "./inline";
import InlineDiff from "./InlineDiff";
import { atRepoPath, page as pg, short } from "./page";
import { withFix } from "./Thread";

const MARK: Record<GateRow["state"], string> = { queued: "·", running: "◌", green: "✓", red: "✗", stopped: "■" };
const secs = (ms: number | null) => (ms == null ? "" : ms >= 60000 ? `${Math.floor(ms / 60000)}m ${Math.round((ms % 60000) / 1000)}s` : `${(ms / 1000).toFixed(1)}s`);

export default function Outgoing() {
  const v = () => model.branchView(pg.id());
  const b = () => v()?.b;
  onMount(() => void pg.loadHistory());
  const unpushed = () => (pg.history()?.rows ?? []).filter((c) => c.pushed === false);
  /** reading order: the oldest unpushed commit first */
  const story = () => [...unpushed()].reverse();
  createEffect(() => {
    const repo = b()?.repo;
    if (repo) for (const c of unpushed()) loadDiff((p) => atRepoPath(repo, p), c.sha);
  });
  const filesOf = (sha: string) => (diffs().get(sha) ?? []).map((f) => ({ ...parsePatch(f.path, f.patch || ""), add: f.add, del: f.del }));
  /** a commit's file is the tip's when no later outgoing commit touches it — then its lines are the tip's */
  const stable = (sha: string, path: string) => {
    const later = story().slice(story().findIndex((c) => c.sha === sha) + 1);
    return later.every((c) => diffs().has(c.sha) && !diffs().get(c.sha)!.some((f) => f.path === path));
  };
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

      <Show when={riding().length || unpushed().some((c) => addressedBy(c.sha).some(unanswered))}>
        <div class="rv-words-k">replies that ride the push</div>
        <For each={unpushed().flatMap((c) => addressedBy(c.sha).filter(unanswered).map((t) => ({ c, t })))}>
          {({ c, t }) => (
            <div class="mb-1 text-[12.5px]">
              <span class="text-ink-faint">{t.comments[0]?.author} on {t.path.split("/").pop()}:{t.local?.line ?? t.line} — addressed by {c.sha.slice(0, 7)}, nothing drafted · </span>
              <button class="rv-quietbtn" onClick={bind("review.address.reply", t.id)}>
                draft "done in {c.sha.slice(0, 7)}"
              </button>
            </div>
          )}
        </For>
        <For each={riding()}>
          {(it) => (
            <div class="mb-1 text-[12.5px]">
              <span class="text-ink">{withFix(it)}</span>
              <span class="text-ink-faint"> · {it.waitingFix ? "waits for a commit that addresses it" : it.err ? it.err : "into your pending review once the push lands"}</span>
            </div>
          )}
        </For>
      </Show>
      <Show when={story().length}>
        <div class="rv-words-k mt-4">the change, commit by commit</div>
        <For each={story()}>
          {(c) => {
            const files = () => filesOf(c.sha);
            const changed = () => files().reduce((n, f) => n + f.add + f.del, 0);
            return (
              <div class="mb-5">
                <div class="rv-commit-head">
                  <code class="text-gold-leaf">{c.sha.slice(0, 7)}</code> <span class="text-ink">{c.subject}</span>
                  <span class="text-ink-faint"> · {c.author} · {c.date}</span>
                  <Show when={c.body}>
                    <pre class="m-0 mt-1 whitespace-pre-wrap font-mono text-[12px] text-ink-dim">{c.body}</pre>
                  </Show>
                  <For each={addressedBy(c.sha)}>
                    {(t) => <div class="mt-1 text-[12px] text-gold-leaf">addresses {t.comments[0]?.author} on {t.path.split("/").pop()}:{t.local?.line ?? t.line}</div>}
                  </For>
                </div>
                <Show when={diffs().has(c.sha)} fallback={<p class="rv-quiet">reading its diff…</p>}>
                  <Show
                    when={!isFolded(c.sha, changed())}
                    fallback={
                      <button class="rv-hrow" onClick={bind("inline.fold", `${c.sha} ${changed()}`)}>
                        {files().length} file{files().length === 1 ? "" : "s"} · <span class="text-add">+{files().reduce((n, f) => n + f.add, 0)}</span>{" "}
                        <span class="text-del">−{files().reduce((n, f) => n + f.del, 0)}</span> · folded (over {FOLD_OVER} lines) — show it
                      </button>
                    }
                  >
                    <Show when={changed() > FOLD_OVER}>
                      <button class="rv-quietbtn mb-1" onClick={bind("inline.fold", `${c.sha} ${changed()}`)}>
                        fold it
                      </button>
                    </Show>
                    <For each={files()}>{(f) => <InlineDiff sha={c.sha} file={f} stable={stable(c.sha, f.path)} />}</For>
                  </Show>
                </Show>
              </div>
            );
          }}
        </For>
      </Show>
    </div>
  );
}
