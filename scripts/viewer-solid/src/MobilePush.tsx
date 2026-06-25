import { createSignal, createMemo, Show, For } from "solid-js";
import { createQuery } from "@tanstack/solid-query";
import { useViewerLocation, forestKey, Link } from "./router";
import { provider } from "./provider";
import "./MobilePush.css";

// The mobile "prepare to push" card: one branch, the part of the git workflow that's
// actually better on a phone — squash unpushed → voiced subject → run gates → push.
// All decisions, almost no typing. Code-level failures (a red gate) are a clean
// "needs the laptop" stop, not something you fix from here.

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

  const [busy, setBusy] = createSignal<"" | "prep" | "gates" | "push">("");
  const [prep, setPrep] = createSignal<PrepResult | null>(null);
  const [gates, setGates] = createSignal<GatesResult | null>(null);
  const [pushed, setPushed] = createSignal<PushResult | null>(null);

  // gates pass and the prep didn't flag a force-push → the one safe path to push.
  const canPush = createMemo(() => !!gates()?.ok && !prep()?.force && !pushed()?.ok);

  const runPrep = async () => {
    setBusy("prep");
    setGates(null);
    setPushed(null);
    setPrep(await post<PrepResult>("/prep", branch()));
    setBusy("");
    commits.refetch();
  };
  const runGates = async () => {
    setBusy("gates");
    setPushed(null);
    setGates(await post<GatesResult>("/gates", branch()));
    setBusy("");
  };
  const runPush = async () => {
    setBusy("push");
    setPushed(await post<PushResult>("/push", branch()));
    setBusy("");
  };

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

      <section class="mp-card">
        <div class="mp-card-h">commits not yet squashed</div>
        <Show when={!commits.isLoading} fallback={<div class="mp-dim">loading…</div>}>
          <Show when={(commits.data?.length ?? 0) > 0} fallback={<div class="mp-dim">none</div>}>
            <ul class="mp-commits">
              <For each={commits.data}>
                {(c) => (
                  <li>
                    <code>{c.sha}</code> <span>{c.subject}</span>
                  </li>
                )}
              </For>
            </ul>
          </Show>
        </Show>
      </section>

      <button class="mp-btn mp-primary" disabled={busy() !== ""} onClick={runPrep}>
        {busy() === "prep" ? "squashing…" : "1 · Prepare (squash unpushed)"}
      </button>

      <Show when={prep()}>
        {(p) => (
          <section class="mp-card" classList={{ "mp-bad": !p().ok }}>
            <Show when={p().ok} fallback={<div class="mp-err">{p().err}</div>}>
              <div class="mp-card-h">
                squashed {p().n} → one commit{" "}
                <Show when={p().voiced} fallback={<span class="mp-tag mp-warn">mechanical msg</span>}>
                  <span class="mp-tag">voiced</span>
                </Show>
                <Show when={p().formatted}>
                  <span class="mp-tag">oxfmt {p().formatted}</span>
                </Show>
              </div>
              <div class="mp-subject">{p().header}</div>
              <Show when={p().force}>
                <div class="mp-err">
                  ⚠ this branch diverged from its remote — needs a force-push. Do it on the laptop.
                </div>
              </Show>
            </Show>
          </section>
        )}
      </Show>

      <Show when={prep()?.ok}>
        <button class="mp-btn" disabled={busy() !== ""} onClick={runGates}>
          {busy() === "gates" ? "running gates…" : "2 · Run gates"}
        </button>
      </Show>

      <Show when={gates()}>
        {(g) => (
          <section class="mp-card" classList={{ "mp-bad": !g().ok }}>
            <Show when={g().gates.length} fallback={<div class="mp-dim">{g().note ?? "no gates"}</div>}>
              <ul class="mp-gates">
                <For each={g().gates}>
                  {(gate) => (
                    <li>
                      <span class={gate.ok ? "mp-pass" : "mp-fail"}>{gate.ok ? "✓" : "✗"}</span>
                      <span class="mp-gate-name">{gate.name}</span>
                      <span class="mp-dim">{gate.ms}ms</span>
                      <Show when={!gate.ok}>
                        <pre class="mp-summary">{gate.summary}</pre>
                      </Show>
                    </li>
                  )}
                </For>
              </ul>
            </Show>
            <Show when={!g().ok}>
              <div class="mp-err">blocked — a gate failed. This needs the laptop; you can't fix code here.</div>
            </Show>
          </section>
        )}
      </Show>

      <Show when={gates()}>
        <button class="mp-btn mp-go" disabled={!canPush() || busy() !== ""} onClick={runPush}>
          {busy() === "push" ? "pushing…" : "3 · Push"}
        </button>
      </Show>

      <Show when={pushed()}>
        {(r) => (
          <section class="mp-card" classList={{ "mp-bad": !r().ok }}>
            <Show
              when={r().ok}
              fallback={<div class="mp-err">{r().err || "push failed"}</div>}
            >
              <div class="mp-done">🎉 pushed to {r().remote}</div>
              <div class="mp-confetti" aria-hidden="true">
                <For each={Array.from({ length: 24 })}>{(_, i) => <i style={confettiStyle(i())} />}</For>
              </div>
            </Show>
          </section>
        )}
      </Show>
    </div>
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
