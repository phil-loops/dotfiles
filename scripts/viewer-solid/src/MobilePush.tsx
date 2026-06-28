import { createSignal, createMemo, Show, For } from "solid-js";
import { createQuery } from "@tanstack/solid-query";
import { useViewerLocation, forestKey, Link } from "./router";
import { provider } from "./provider";
import "./MobilePush.css";

// The mobile "prepare to push" card: one branch, the part of the git workflow that's
// actually better on a phone — squash unpushed → voiced subject → run gates → push.
// One tap runs the whole chain; it stops with a reason the moment a step can't proceed.
// A red gate or a needed force-push is a clean "needs the laptop" stop, not fixable here.

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
interface PushResult {
  ok: boolean;
  remote?: string;
  out?: string;
  err?: string;
}

type StepKey = "squash" | "gates" | "push";
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
  const [pushed, setPushed] = createSignal<PushResult | null>(null);

  const started = createMemo(() => !!(prep() || gates() || pushed()));
  const done = createMemo(() => !!pushed()?.ok);

  // why the chain stopped short of a push — the one thing the laptop is needed for.
  const blocked = createMemo(() => {
    if (prep()?.force) {
      return "This branch diverged from its remote. Force-push from the laptop.";
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
    if (key === "gates") {
      if (!gates()) {
        return "idle";
      }
      return gates()!.ok ? "ok" : "fail";
    }
    if (!pushed()) {
      return "idle";
    }
    return pushed()!.ok ? "ok" : "fail";
  };

  const runAll = async () => {
    setRunning(true);
    setPrep(null);
    setGates(null);
    setPushed(null);

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
    const g = await post<GatesResult>("/gates", branch());
    setGates(g);
    if (!g.ok) {
      setActive(null);
      setRunning(false);
      return;
    }

    setActive("push");
    setPushed(await post<PushResult>("/push", branch()));
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
    if (active() === "push") {
      return "Pushing…";
    }
    return started() ? "Run again" : "Prepare & push";
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
              {commits.data?.length === 1 ? "commit" : "commits"} to squash and push
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
          pushed to {pushed()!.remote}
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

          <Step n={3} state={stepState("push")} name="push">
            <Show when={pushed() && !pushed()!.ok}>
              <span class="mp-detail-bad">{pushed()!.err || "push failed"}</span>
            </Show>
          </Step>
        </ol>
      </Show>

      <Show when={blocked()}>
        <div class="mp-blocked">{blocked()}</div>
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
