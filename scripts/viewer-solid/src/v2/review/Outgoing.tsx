// The Commits tab with no commit selected: exactly what's about to leave the machine for this
// branch, read top to bottom — one push (first push and follow-ups alike), each gate's state on this
// exact tip, the "done in" replies that ride the push, the PR text a first push creates, then the
// change itself commit by commit, oldest first: each unpushed commit's message and its own diff.
import { createEffect, createResource, createSignal, For, Match, onCleanup, onMount, Show, Switch } from "solid-js";
import Commits from "../Commits";
import { gateRows, type GateRow, type Progress } from "../gates";
import { model } from "../model";
import { keyOf } from "../registry";
import { bind, runOf } from "../runner";
import { pushRoute } from "../commands/branch";
import { leaf } from "../ship";
import { list, view, world } from "../store";
import { getJSON } from "../sync";
import type { Thread } from "../types";
import { armed, now } from "../ui";
import { parsePatch } from "./diff";
import { FOLD_OVER, diffs, isFolded, loadDiff } from "./inline";
import InlineDiff from "./InlineDiff";
import { atRepoPath, page as pg, short } from "./page";
import { withFix } from "./Thread";

const MARK: Record<GateRow["state"], string> = { queued: "·", running: "◌", green: "✓", waived: "↷", red: "✗", stopped: "■" };
const secs = (ms: number | null) => (ms == null ? "" : ms >= 60000 ? `${Math.floor(ms / 60000)}m ${Math.round((ms % 60000) / 1000)}s` : `${(ms / 1000).toFixed(1)}s`);

/** The push, as a live status rather than a button beside grey text: readied, pushing (and for
 *  how long), on origin, done — with the PR and where the replies stand — or the reason it failed
 *  and a retry. Driven by the runner's own record of the push (runOf). */
function PushStatus(props: { count: number }) {
  const id = () => pg.id();
  const v = () => model.branchView(id());
  const run = () => runOf("branch.push.confirm", id());
  const [sent, setSent] = createSignal(0);
  const [tick, setTick] = createSignal(Date.now());
  createEffect(() => {
    const r = run();
    if (r?.state === "sending" && !sent()) setSent(props.count);
    if (r?.state !== "sending" && r?.state !== "landing") return;
    const t = window.setInterval(() => setTick(Date.now()), 250);
    onCleanup(() => clearInterval(t));
  });
  const label = () => {
    const r = pushRoute(id());
    if (r === "branch.gates.run") return v()?.b.gates === "red" ? "re-run the gates" : "run the gates";
    if (r === "branch.gates.wait") return "gates running…";
    return armed() === id() ? `${keyOf("review.push")} again to push` : `push ${props.count}`;
  };
  const secs = () => `${((((run()?.t1 ?? tick()) - (run()?.t0 ?? tick())) / 1000)).toFixed(1)}s`;
  const replies = () => {
    const rs = pg.items().filter((i) => i.kind === "reply" && (i.waitsFor.length || i.fixFor));
    const n = (st: string) => rs.filter((i) => i.state === st).length;
    return [n("sending") && `${n("sending")} sending`, n("waiting") && `${n("waiting")} waiting`, rs.some((i) => i.err) && "1 held back — see below"]
      .filter(Boolean)
      .join(", ");
  };
  // a finished push stays on screen until there's something new to push
  const live = () => run() && (run()!.state !== "done" || !props.count);
  return (
    <div class="mt-2 text-[12.5px]">
      <Show
        when={live()}
        fallback={
          <Show when={props.count}>
            <button class="rv-btn rv-btn-gold" disabled={!pushRoute(id())} onClick={bind("review.push", id())}>
              {label()} <kbd>{keyOf("review.push")}</kbd>
            </button>
            <Show when={!pushRoute(id())}>
              <span class="ml-3 text-ink-faint">nothing to push</span>
            </Show>
          </Show>
        }
      >
        <Switch>
          <Match when={run()!.state === "sending"}>
            <span class="text-gold-leaf animate-breathe">◌ pushing · {secs()}</span>
          </Match>
          <Match when={run()!.state === "landing"}>
            <span class="text-patina">✓ pushed</span> <span class="text-ink-faint">· {secs()}</span>
          </Match>
          <Match when={run()!.state === "done"}>
            <span class="text-patina">✓ {sent()} commit{sent() === 1 ? "" : "s"} on </span>
            <Show when={v()?.pr} fallback={<span class="text-patina">origin</span>}>
              <a class="text-gold-leaf" href={v()!.pr!.url} target="_blank" rel="noreferrer">
                #{v()!.pr!.number}
              </a>
            </Show>
            <span class="text-ink-faint"> · {secs()}{replies() ? ` · replies: ${replies()}` : ""}</span>
          </Match>
          <Match when={run()!.state === "failed"}>
            <span class="text-ember">✗ {run()!.err}</span>{" "}
            <button class="rv-quietbtn" onClick={bind("review.push", id())}>
              retry
            </button>
          </Match>
        </Switch>
      </Show>
    </div>
  );
}

export default function Outgoing() {
  const v = () => model.branchView(pg.id());
  const b = () => v()?.b;
  onMount(() => void pg.loadHistory());
  // what origin lacks: the branch's own count is live; the list's marks catch up when it re-reads
  // a branch never pushed has no origin to compare with, so the server leaves `pushed` off its commits: all of them go
  const unpushed = () => (b()?.pushed === "synced" ? [] : (pg.history()?.rows ?? []).filter((c) => c.pushed === false || (b()?.pushed === "local" && c.pushed == null)));
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
    () => (b() ? `${b()!.repo}|${b()!.name}|${b()!.tip}|${b()!.gates}` : null),
    () => getJSON<Progress>(atRepoPath(b()!.repo, `/gates-progress?branch=${encodeURIComponent(b()!.name)}`)).catch(() => null),
  );
  createEffect(() => {
    if (!progress()?.running) return;
    const t = window.setTimeout(() => void refetch(), 2000);
    onCleanup(() => clearTimeout(t));
  });
  const rows = () => (now(), gateRows(progress(), Date.now() / 1000));
  /** the gates already skipped on this run — a second skip keeps them skipped */
  const skipped = () => rows().filter((r) => r.state === "waived" && r.summary?.endsWith("skipped by you")).map((r) => r.name);
  /** with no run log left, the verdict git config recorded for this tree */
  const recorded = () => {
    const g = b()?.gates;
    if (g === "green") return "✓ (recorded, no run log)";
    if (g === "red") return `red: ${b()!.redGates.join(", ") || "gates"} (recorded, no run log)`;
    if (g === "stale") return "stale — the tree changed since the last run";
    return "not run";
  };
  const logged = () => rows().length > 0 || progress.loading;

  return (
    <div class="rv-outgoing">
      <div class="rv-commit-head">
        <Show when={b()} fallback={<span class="text-ink-faint">not local</span>}>
          <span class="text-ink">
            {unpushed().length
              ? `${unpushed().length} to push`
              : "nothing to push"}
          </span>
          <span class="text-ink-faint">
            {" "}· {v()?.pr ? `onto #${v()!.pr!.number}` : "first push"} · <code>{short(b()!.tip)}</code> · gates {logged() ? (b()!.gates === "green" ? "✓" : b()!.gates) : recorded()}
          </span>
          <PushStatus count={unpushed().length} />
          <Show when={!v()?.pr && v()?.st.action === "pr" && world.entities.warm[b()?.repo ?? ""]?.prs}>
            <div class="mt-2">
              <button class="rv-btn rv-btn-gold" onClick={bind("review.finish", pg.id())}>
                open the PR ↗ <kbd>{keyOf("review.finish")}</kbd>
              </button>
            </div>
          </Show>
        </Show>
      </div>

      <Show when={logged()}>
        <div class="rv-words-k">gates</div>
      </Show>
      <Show when={rows().length} fallback={<Show when={progress.loading}><p class="rv-quiet">reading the gates…</p></Show>}>
        <ol class="m-0 mb-4 list-none p-0">
          <For each={rows()}>
            {(g) => (
              <li class="flex gap-3 py-0.5 text-[12.5px]">
                <span class="w-4" classList={{ "text-patina": g.state === "green", "text-ember": g.state === "red" || g.state === "stopped", "text-gold-leaf": g.state === "running", "text-ink-faint": g.state === "queued" }}>
                  {MARK[g.state]}
                </span>
                <span class="w-24 text-ink">{g.name}</span>
                <span class="w-24 text-ink-faint">{g.state === "stopped" ? "stopped" : g.state}</span>
                <span class="w-16 text-right text-ink-faint">{secs(g.ms)}</span>
                <span class="min-w-0 flex-1 truncate text-ink-faint" title={g.summary}>{g.summary}</span>
                <Show when={g.state === "red"}>
                  <button class="rv-quietbtn shrink-0" onClick={bind("branch.gates.skip", `${pg.id()} ${[...skipped(), g.name].join(",")}`)}>
                    skip
                  </button>
                </Show>
              </li>
            )}
          </For>
        </ol>
      </Show>

      <Show when={!v()?.pr && b()}>
        <Commits branchId={pg.id()} landing landingOnly />
      </Show>

      <Show when={riding().length || unpushed().some((c) => addressedBy(c.sha).some(unanswered))}>
        <div class="rv-words-k">replies</div>
        <For each={unpushed().flatMap((c) => addressedBy(c.sha).filter(unanswered).map((t) => ({ c, t })))}>
          {({ c, t }) => (
            <div class="mb-1 text-[12.5px]">
              <span class="text-ink-faint">{t.comments[0]?.author} on {t.path.split("/").pop()}:{t.local?.line ?? t.line} · </span>
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
              <span class="text-ink-faint"> · {it.waitingFix ? "waits for its fix" : it.err ? it.err : "after the push"}</span>
            </div>
          )}
        </For>
      </Show>
      <Show when={story().length}>
        <div class="rv-words-k mt-4">commits</div>
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
                <Show when={diffs().has(c.sha)} fallback={<p class="rv-quiet">…</p>}>
                  <Show
                    when={!isFolded(c.sha, changed())}
                    fallback={
                      <button class="rv-hrow" onClick={bind("inline.fold", `${c.sha} ${changed()}`)}>
                        {files().length} file{files().length === 1 ? "" : "s"} · <span class="text-add">+{files().reduce((n, f) => n + f.add, 0)}</span>{" "}
                        <span class="text-del">−{files().reduce((n, f) => n + f.del, 0)}</span> · show
                      </button>
                    }
                  >
                    <Show when={changed() > FOLD_OVER}>
                      <button class="rv-quietbtn mb-1" onClick={bind("inline.fold", `${c.sha} ${changed()}`)}>
                        fold
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
