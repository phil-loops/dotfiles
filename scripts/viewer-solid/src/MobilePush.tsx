import { createSignal, createMemo, Show, For } from "solid-js";
import { createQuery } from "@tanstack/solid-query";
import { useViewerLocation, forestKey, Link } from "./router";
import { provider } from "./provider";
import { fetchJSON } from "./api";
import "./MobilePush.css";

// The "prepare to push" card: one branch — squash unpushed → voiced subject → run gates
// (auto-rebasing onto fresh main when that's what's stale) → and, once every guard is
// green, THE origin push (phase 1 of retiring GitHub Desktop; design doc in
// ~/daily-log/2026-07-02-deprecate-gh-desktop/). The button is the only way that push
// fires — a human finger, never Claude — and the server re-verifies every guard anyway.
// A red gate is a clean "needs the laptop" stop, not fixable here.

interface PrepResult {
  ok: boolean;
  n?: number;
  header?: string;
  voiced?: boolean;
  force?: boolean;
  sha?: string;
  formatted?: number;
  err?: string;
}
interface Gate {
  name: string;
  ok: boolean;
  ms: number;
  summary: string;
  fixed?: boolean;
}
interface GatesResult {
  ok: boolean;
  gates: Gate[];
  note?: string;
  err?: string;
}
interface PushPreview {
  ok: boolean;
  outgoing: number;
  ff: boolean;
  originExists: boolean;
  gatesGreen: boolean;
  web: string;
  reasons: string[];
  wards: { k: string; label: string; ok: boolean; why: string }[];
  commits: { sha: string; subject: string; date: string }[];
  ageDays: number;
  fork: { sha: string; date: string };
  mainSince: number;
  deployCritical: string[];
  files: { path: string; add: number; del: number }[];
  moreFiles: number;
  commit?: { sha: string; subject: string; body: string } | null;
}
interface PushOriginResult {
  ok: boolean;
  web?: string;
  out?: string;
  err?: string;
}
type StepKey = "squash" | "gates";
type StepState = "idle" | "run" | "ok" | "fail";

async function post<T>(path: string, branch: string): Promise<T> {
  const r = await fetch(path, { method: "POST", body: JSON.stringify({ branch }) });
  return (await r.json()) as T;
}

export default function MobilePush() {
  const { location } = useViewerLocation();
  const branch = createMemo(() => forestKey(location()));

  const commits = createQuery(() => ({
    queryKey: ["commits", branch()],
    queryFn: () => provider.commits(branch()),
  }));

  const [running, setRunning] = createSignal(false);
  const [active, setActive] = createSignal<StepKey | null>(null);
  const [prep, setPrep] = createSignal<PrepResult | null>(null);
  const [gates, setGates] = createSignal<GatesResult | null>(null);

  const started = createMemo(() => !!(prep() || gates()));
  const done = createMemo(() => !!(prep()?.ok && !prep()!.force && gates()?.ok));

  // the origin door — read-only guard verdict + the one outgoing commit. The server owns
  // this verdict (and recomputes it on the actual push); the card only renders it.
  const preview = createQuery(() => ({
    queryKey: ["push-preview", branch()],
    queryFn: () => fetchJSON<PushPreview>("/push-preview?branch=" + encodeURIComponent(branch())),
    enabled: !!branch(),
  }));
  const [armed, setArmed] = createSignal(false);
  const [pushing, setPushing] = createSignal(false);
  const [pushed, setPushed] = createSignal<PushOriginResult | null>(null);
  let disarmTimer: ReturnType<typeof setTimeout> | undefined;

  const originClick = async () => {
    if (!armed()) {
      setArmed(true);
      clearTimeout(disarmTimer);
      disarmTimer = setTimeout(() => setArmed(false), 6000);
      return;
    }
    clearTimeout(disarmTimer);
    setArmed(false);
    setPushing(true);
    setPushed(await post<PushOriginResult>("/push-origin", branch()));
    setPushing(false);
    preview.refetch();
    commits.refetch();
  };

  // why the chain stopped short of a clean local state — what the laptop is needed for.
  const blocked = createMemo(() => {
    if (prep()?.force) {
      return "This branch diverged from its remote. Sort it out on the laptop.";
    }
    if (prep() && !prep()!.ok) {
      return prep()!.err || "Couldn't prepare the branch.";
    }
    if (gates() && !gates()!.ok) {
      return "A gate failed — you can't fix code here. Open it on the laptop, then run again.";
    }
    return null;
  });

  const stepState = (key: StepKey): StepState => {
    if (active() === key) {
      return "run";
    }
    if (key === "squash") {
      if (!prep()) {
        return "idle";
      }
      return prep()!.ok && !prep()!.force ? "ok" : "fail";
    }
    if (!gates()) {
      return "idle";
    }
    return gates()!.ok ? "ok" : "fail";
  };

  const runAll = async () => {
    setRunning(true);
    setPrep(null);
    setGates(null);

    setActive("squash");
    const p = await post<PrepResult>("/prep", branch());
    setPrep(p);
    commits.refetch();
    if (!p.ok || p.force) {
      setActive(null);
      setRunning(false);
      return;
    }

    setActive("gates");
    setGates(await post<GatesResult>("/gates", branch()));
    commits.refetch();
    preview.refetch();
    setActive(null);
    setRunning(false);
  };

  const ctaLabel = createMemo(() => {
    if (active() === "squash") {
      return "Squashing…";
    }
    if (active() === "gates") {
      return "Running gates…";
    }
    return started() ? "Run again" : "Get it ready";
  });

  return (
    <div class="mp-wrap">
      <header class="mp-head">
        <Link to={{ kind: "home", tab: "work" }} class="mp-back" title="home">
          ‹
        </Link>
        <div class="mp-title">
          <div class="mp-label">prepare to push</div>
          <div class="mp-branch">{branch()}</div>
        </div>
      </header>

      <div class="mp-state">
        <Show when={!commits.isLoading} fallback={<span class="mp-dim">reading branch…</span>}>
          <Show
            when={(commits.data?.length ?? 0) > 0}
            fallback={<span class="mp-dim">nothing unpushed to squash</span>}
          >
            <span class="mp-state-n">{commits.data?.length}</span>
            <span class="mp-dim">
              {commits.data?.length === 1 ? "commit" : "commits"} to squash
            </span>
          </Show>
        </Show>
      </div>

      <Show when={done()} fallback={
        <button class="mp-cta" disabled={running()} onClick={runAll}>
          <span class="mp-cta-mark">{running() ? "" : "▸"}</span>
          {ctaLabel()}
        </button>
      }>
        <div class="mp-earned">
          {pushed()?.ok ? "pushed — the team has it" : "ready for the origin door below"}
          <div class="mp-confetti" aria-hidden="true">
            <For each={Array.from({ length: 24 })}>{(_, i) => <i style={confettiStyle(i())} />}</For>
          </div>
        </div>
      </Show>

      <Show when={started()}>
        <ol class="mp-rail">
          <Step n={1} state={stepState("squash")} name="squash">
            <Show when={prep()}>
              {(p) => (
                <Show when={p().ok} fallback={<span class="mp-detail-bad">{p().err}</span>}>
                  <span class="mp-detail">
                    {p().n} → one commit
                    <Show
                      when={p().voiced}
                      fallback={<em class="mp-flag">mechanical message</em>}
                    >
                      <em class="mp-flag mp-flag-on">voiced subject</em>
                    </Show>
                    <Show when={p().formatted}>
                      <em class="mp-flag mp-flag-on">formatted {p().formatted}</em>
                    </Show>
                  </span>
                </Show>
              )}
            </Show>
          </Step>

          <Step n={2} state={stepState("gates")} name="gates">
            <Show when={gates()}>
              {(g) => (
                <Show
                  when={g().gates.length}
                  fallback={<span class="mp-detail">{g().note ?? "no gates configured"}</span>}
                >
                  <ul class="mp-gatelist">
                    <For each={g().gates}>
                      {(gate) => (
                        <li>
                          <span class={gate.ok ? "mp-gate-ok" : "mp-gate-no"}>
                            {gate.ok ? "✓" : "✗"}
                          </span>
                          <span class="mp-gate-name">{gate.name}</span>
                          <Show when={gate.fixed}>
                            <em class="mp-flag mp-flag-on">auto-fixed</em>
                          </Show>
                          <span class="mp-dim">{gate.ms}ms</span>
                          <Show when={!gate.ok}>
                            <pre class="mp-gate-out">{gate.summary}</pre>
                          </Show>
                        </li>
                      )}
                    </For>
                  </ul>
                </Show>
              )}
            </Show>
          </Step>
        </ol>
      </Show>

      <Show when={blocked()}>
        <div class="mp-blocked">{blocked()}</div>
      </Show>

      {/* the origin door — the ONE place this tooling touches shared history, rendered as
          the crossing it is: everything that came before (your outgoing commits) on the
          left, everything main did since you forked on the right, converging on the sealed
          commit behind six wards. The server owns the verdict and re-verifies it on the
          push; this section only renders it. PRs are authored on github.com, never here. */}
      <Show when={preview.data && (preview.data!.outgoing > 0 || pushed())}>
        <section class="mp-origin">
          <div class="mp-origin-head">
            origin — shared with the team
            <span class="mp-origin-sub">
              {(preview.data?.web.match(/github\.com\/([^/]+\/[^/]+)\//) || [])[1] ?? ""}
            </span>
          </div>

          <div class="mp-cross">
            <div class="mp-cross-col">
              <div class="mp-cross-title">yours · since {preview.data?.fork.date}</div>
              <div class="mp-cross-n">
                <b>{preview.data?.outgoing}</b>
                {preview.data?.outgoing === 1 ? " commit" : " commits"}
                <Show when={(preview.data?.ageDays ?? 0) > 0}>
                  {" · "}{preview.data?.ageDays}{preview.data?.ageDays === 1 ? " day" : " days"}
                </Show>
              </div>
              <ul class="mp-cross-list">
                <For each={preview.data?.commits}>
                  {(c) => (
                    <li>
                      <span class="mp-cross-date">{c.date}</span>
                      {c.subject}
                    </li>
                  )}
                </For>
                <Show when={(preview.data?.outgoing ?? 0) > 8}>
                  <li class="mp-cross-more">+ {(preview.data?.outgoing ?? 0) - 8} more</li>
                </Show>
              </ul>
            </div>
            <div class="mp-cross-col mp-cross-right">
              <div class="mp-cross-title">main · since you forked</div>
              <div class="mp-cross-n">
                <b>{preview.data?.mainSince}</b> commits landed
              </div>
              <Show
                when={preview.data?.deployCritical.length}
                fallback={<div class="mp-cross-ok">deploy watch clear</div>}
              >
                <div class="mp-cross-warn">
                  {preview.data?.deployCritical.length} deploy-watched{" "}
                  {preview.data?.deployCritical.length === 1 ? "file" : "files"} you lack
                </div>
              </Show>
            </div>
          </div>
          <div class="mp-converge" aria-hidden="true">
            <i /><span>⌄</span><i />
          </div>

          <div class="mp-seal">
            <Show
              when={preview.data?.commit}
              fallback={
                <div class="mp-seal-pending">
                  prep seals {preview.data?.outgoing} commits into one voiced commit
                </div>
              }
            >
              {(c) => (
                <>
                  <div class="mp-seal-subject">{c().subject}</div>
                  <Show when={c().body}>
                    <pre class="mp-seal-body">{c().body}</pre>
                  </Show>
                </>
              )}
            </Show>
            <ul class="mp-files">
              <For each={preview.data?.files}>
                {(f) => (
                  <li>
                    <span class="mp-file-path">{f.path}</span>
                    <span class="mp-file-add">+{f.add}</span>
                    <span class="mp-file-del">−{f.del}</span>
                  </li>
                )}
              </For>
              <Show when={preview.data?.moreFiles}>
                <li class="mp-cross-more">+ {preview.data?.moreFiles} more files</li>
              </Show>
            </ul>
          </div>

          <ul class="mp-wards">
            <For each={preview.data?.wards}>
              {(w, i) => (
                <li class="mp-ward" classList={{ lit: w.ok }} style={{ "--i": String(i()) }}>
                  <span class="mp-ward-seal">{w.ok ? "◆" : "◇"}</span>
                  <span class="mp-ward-label">{w.label}</span>
                </li>
              )}
            </For>
          </ul>
          <Show when={!preview.data?.ok && !pushed()?.ok}>
            <ul class="mp-origin-reasons">
              <For each={preview.data?.reasons}>{(r) => <li>✗ {r}</li>}</For>
            </ul>
          </Show>

          <Show
            when={!pushed()?.ok}
            fallback={
              <div class="mp-origin-done">
                ✓ pushed to origin —{" "}
                <a href={pushed()!.web} target="_blank" rel="noreferrer">
                  open on github.com
                </a>{" "}
                <span class="mp-dim">(PRs are authored there, never here)</span>
              </div>
            }
          >
            <button
              class="mp-origin-btn"
              classList={{ armed: armed() }}
              disabled={!preview.data?.ok || pushing()}
              onClick={originClick}
            >
              {pushing() ? "pushing…" : armed() ? "confirm: push to origin" : "⤴ push to origin"}
            </button>
            <Show when={pushed() && !pushed()!.ok}>
              <div class="mp-blocked">{pushed()!.err || "push refused"}</div>
            </Show>
          </Show>
        </section>
      </Show>
    </div>
  );
}

function Step(props: { n: number; state: StepState; name: string; children?: any }) {
  return (
    <li class="mp-step" data-state={props.state}>
      <span class="mp-step-dot">
        <Show when={props.state === "ok"}>✓</Show>
        <Show when={props.state === "fail"}>✗</Show>
      </span>
      <div class="mp-step-body">
        <div class="mp-step-name">
          <span class="mp-step-n">{props.n}</span>
          {props.name}
        </div>
        {props.children}
      </div>
    </li>
  );
}

// deterministic spread so each piece flies a different direction/colour (no Math.random
// at module load; index-derived is stable across re-renders).
function confettiStyle(i: number): Record<string, string> {
  const colors = ["#ff5c8a", "#ffd24c", "#4cd4ff", "#7cff8a", "#c08cff"];
  const left = (i * 37) % 100;
  const delay = (i % 8) * 60;
  const dur = 900 + (i % 5) * 160;
  return {
    left: `${left}%`,
    background: colors[i % colors.length],
    "animation-delay": `${delay}ms`,
    "animation-duration": `${dur}ms`,
  };
}
