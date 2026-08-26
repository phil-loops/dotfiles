import { Show, Switch, Match, For, createSignal } from "solid-js";
import { withRepo } from "./provider";

export type ForceScope = {
  eligible: boolean;
  guards: { k: string; label: string; ok: boolean }[];
  lease: string;
  prNumber: number | null;
  prUrl: string | null;
};

export type DivergedDetail = {
  ok: boolean;
  err?: string;
  upstream?: string;
  trunk?: string;
  ahead?: { sha: string; subject: string; matched: boolean; fromMain: boolean }[];
  behind?: { sha: string; subject: string; matched: boolean }[];
  containment?: "rebase" | "contained" | "clean-extra" | "overlap";
  overlap?: string[];
  prNow?: string;
  prAfter?: string;
  prFiles?: { path: string; status: "same" | "changed" | "enters" | "leaves"; now: string | null; after: string | null }[];
  forceScope?: ForceScope;
};

// The ⇄ diverged chip's inspect panel: what the divergence IS, in the PR's frame — each side's
// commits (patch-id twins flagged), a containment verdict, and origin's review diff now vs after push.
export function DivergedDetailPanel(props: { data: DivergedDetail | undefined; branch?: string }) {
  // scoped force — the ONE sanctioned force-with-lease: a stacked DRAFT nobody has reviewed
  // or commented on. Two clicks (arm, then confirm) and the server re-verifies every guard
  // plus the lease before anything moves; git itself refuses if origin moved meanwhile.
  const [armed, setArmed] = createSignal(false);
  const [forcing, setForcing] = createSignal(false);
  const [forceDone, setForceDone] = createSignal<string | null>(null);
  let disarmTimer: ReturnType<typeof setTimeout> | undefined;
  const arm = () => {
    setArmed(true);
    clearTimeout(disarmTimer);
    disarmTimer = setTimeout(() => setArmed(false), 6000);
  };
  const runForce = async () => {
    const scope = props.data?.forceScope;
    if (!props.branch || !scope) return;
    setArmed(false);
    setForcing(true);
    try {
      const r = await fetch(withRepo("/force-origin"), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ branch: props.branch, lease: scope.lease }),
      });
      const j = (await r.json()) as { ok?: boolean; err?: string; web?: string };
      setForceDone(j.ok ? "✓ replaced — origin now carries exactly your local history" : `✗ ${j.err || "force refused"}`);
    } catch (e) {
      setForceDone(`✗ ${(e as Error).message || "force failed"}`);
    } finally {
      setForcing(false);
    }
  };
  return (
            <div class="nh-diverged-detail mt-[6px] mb-[2px] rounded-[8px] border border-[color:var(--line,#444)] px-3 py-[10px] text-[12.5px] leading-[1.55]">
              <Show when={props.data} fallback={<span>reading both sides…</span>}>
                <Show when={props.data!.ok} fallback={<span>✗ {props.data!.err}</span>}>
                  <div class="mb-[6px]">
                    <Switch>
                      <Match when={props.data!.containment === "rebase"}>
                        <span>
                          only a local rebase — every pushed-head commit is patch-identical to a local one, so the PR's
                          content already matches. Nothing to push; leave origin alone.
                        </span>
                      </Match>
                      <Match when={props.data!.containment === "contained"}>
                        <span>
                          local already contains everything the pushed head has (a squash/rework absorbed it). If the PR
                          diff below changed, update it ADDITIVELY — a commit on top of the pushed head; an open PR's
                          history is shared, never force-push it.
                        </span>
                      </Match>
                      <Match when={props.data!.containment === "clean-extra"}>
                        <span>
                          ⚠ the pushed head has work local lacks (it would merge cleanly) — bring it into local first
                          (reconcile), then update the PR additively if anything remains.
                        </span>
                      </Match>
                      <Match when={props.data!.containment === "overlap"}>
                        <span>
                          local reworked what the pushed head has ({(props.data!.overlap ?? []).join(", ")}) —
                          update the PR ADDITIVELY: one commit on top of the pushed head carrying the rework (reconcile
                          drafts exactly that; an open PR's history is shared, never force-push it).
                        </span>
                      </Match>
                    </Switch>
                    <div class="opacity-75">
                      PR diff on origin today: {props.data!.prNow || "empty"} → after carrying local's content:{" "}
                      {props.data!.prAfter || "empty"}
                    </div>
                  </div>
                  <div class="flex flex-wrap gap-6">
                    <div>
                      <div class="opacity-65">only local ({(props.data!.ahead ?? []).length}↑)</div>
                      <For each={props.data!.ahead}>
                        {(c) => (
                          <div>
                            <code>{c.sha}</code> {c.subject}{" "}
                            <span class="opacity-60">
                              {c.matched ? "≡ rewritten twin" : c.fromMain ? "↳ main advance (restack)" : "◆ new work"}
                            </span>
                          </div>
                        )}
                      </For>
                    </div>
                    <div>
                      <div class="opacity-65">only pushed head ({(props.data!.behind ?? []).length}↓)</div>
                      <For each={props.data!.behind}>
                        {(c) => (
                          <div>
                            <code>{c.sha}</code> {c.subject}{" "}
                            <span class="opacity-60">{c.matched ? "≡ rewritten twin" : "◆ no local twin"}</span>
                          </div>
                        )}
                      </For>
                    </div>
                    <Show when={(props.data!.prFiles ?? []).length > 0}>
                      <div>
                        <div class="opacity-65">
                          the PR's diff, file by file (now → after an additive update)
                        </div>
                        <For each={props.data!.prFiles}>
                          {(f) => (
                            <div>
                              <code>{f.path}</code>{" "}
                              <span class="opacity-60">
                                <Switch>
                                  <Match when={f.status === "same"}>{f.now} · unchanged</Match>
                                  <Match when={f.status === "changed"}>
                                    {f.now} → {f.after}
                                  </Match>
                                  <Match when={f.status === "enters"}>＋ enters the PR ({f.after})</Match>
                                  <Match when={f.status === "leaves"}>－ leaves the PR (was {f.now})</Match>
                                </Switch>
                              </span>
                            </div>
                          )}
                        </For>
                      </div>
                    </Show>
                  </div>
                  <Show when={props.data!.forceScope && props.branch}>
                    <div class="mt-[10px] border-t border-[color:var(--line,#444)] pt-[8px]">
                      <div class="opacity-65">⚑ scoped force — replace the pushed history</div>
                      <div class="mt-[2px]">
                        <For each={props.data!.forceScope!.guards}>
                          {(g) => (
                            <span class="mr-3">
                              {g.ok ? "✓" : "✗"} {g.label}
                            </span>
                          )}
                        </For>
                        <span class="opacity-60">lease {props.data!.forceScope!.lease.slice(0, 9)}</span>
                      </div>
                      <div class="mt-[4px] opacity-80">
                        This discards the {(props.data!.behind ?? []).length} pushed commit
                        {(props.data!.behind ?? []).length === 1 ? "" : "s"} above and replaces{" "}
                        {props.data!.forceScope!.prNumber ? `PR #${props.data!.forceScope!.prNumber}` : "the branch"} with
                        your {(props.data!.ahead ?? []).length} local commit
                        {(props.data!.ahead ?? []).length === 1 ? "" : "s"}; the PR's diff becomes{" "}
                        {props.data!.prAfter || "empty"}. Lease-guarded: refuses if origin moves first.
                      </div>
                      <Show
                        when={props.data!.forceScope!.eligible}
                        fallback={
                          <div class="mt-[4px] opacity-60">
                            out of scope — force is only offered while the PR is a draft nobody has reviewed or
                            commented on, with gates green. Use the additive vehicle instead.
                          </div>
                        }
                      >
                        <button
                          class="mt-[6px] cursor-pointer rounded-[6px] border border-rule bg-transparent px-[9px] py-[3px] text-[11.5px] text-ink-faint hover:bg-vellum-edge hover:text-ink disabled:cursor-default disabled:opacity-40"
                          disabled={forcing() || !!forceDone()}
                          onClick={() => (armed() ? runForce() : arm())}
                        >
                          {forcing()
                            ? "forcing…"
                            : armed()
                              ? `⚠ click again: force-with-lease replace origin/${props.branch}`
                              : "⚑ force-with-lease…"}
                        </button>
                      </Show>
                      <Show when={forceDone()}>
                        <div class="mt-[4px]">{forceDone()}</div>
                      </Show>
                    </div>
                  </Show>
                </Show>
              </Show>
            </div>
  );
}
