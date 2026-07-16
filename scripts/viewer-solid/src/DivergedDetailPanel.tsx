import { Show, Switch, Match, For } from "solid-js";

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
};

// The ⇄ diverged chip's inspect panel: what the divergence IS, in the PR's frame — each side's
// commits (patch-id twins flagged), a containment verdict, and origin's review diff now vs after push.
export function DivergedDetailPanel(props: { data: DivergedDetail | undefined }) {
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
                </Show>
              </Show>
            </div>
  );
}
