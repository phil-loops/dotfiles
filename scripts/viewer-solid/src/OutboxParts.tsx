// The outbox's shared row parts — gates and PR chips, and the landing title edited in place —
// used by the lanes and the launch sheet alike.
import { createEffect, createSignal, Match, Show, Switch } from "solid-js";
import { staleLabel, verdictLabel } from "./packetModel";
import { canMutate } from "./provider";
import type { OutboxActions } from "./outboxActions";
import type { OutboxNode } from "./outboxModel";

const CHIP = "inline-flex flex-none items-center gap-[5px] rounded-[6px] border px-[7px] py-px font-mono text-[10.5px] leading-[1.6] whitespace-nowrap";

export function GatesChip(props: { n: OutboxNode }) {
  return (
    <Switch>
      <Match when={props.n.gates === "green"}>
        <span class={`${CHIP} border-[#3c4a30] text-add`} title="gates green for this exact tree">● green</span>
      </Match>
      <Match when={props.n.gates === "red"}>
        <span class={`${CHIP} border-[#5a3424] text-del`} title={`red: ${props.n.redGates.join(", ") || "a gate failed"}`}>
          ✗ {props.n.redGates.join(" · ") || "red"}
        </span>
      </Match>
      <Match when={props.n.gates === "stale"}>
        <span class={`${CHIP} border-gold-deep text-gold-leaf`} title="green for an older tree — the edit since hasn't been gated">◌ stale</span>
      </Match>
      <Match when={props.n.gates === "running"}>
        <span class={`${CHIP} animate-breathe border-rule text-ink-dim motion-reduce:animate-none`}>… gating</span>
      </Match>
      <Match when={props.n.gates === "none"}>
        <span class={`${CHIP} border-rule text-ink-faint`} title="never gated — /push-ready runs them">○ ungated</span>
      </Match>
    </Switch>
  );
}

// An open PR's packet, in two chips: the forest moved past its "Where this sits" (copy the
// spliced body, paste it on GitHub — nothing here writes there), and the bot's verdict on Intent.
export function PacketChips(props: { n: OutboxNode; onCopied?: (ok: boolean) => void }) {
  const r = () => props.n.packet;
  const [copied, setCopied] = createSignal(false);
  const copy = async (e: MouseEvent) => {
    e.stopPropagation();
    let ok = false;
    try {
      await navigator.clipboard.writeText(r()!.updatedBody);
      ok = true;
    } catch { /* clipboard refused */ }
    setCopied(ok);
    props.onCopied?.(ok);
  };
  return (
    <Show when={r()}>
      {(rv) => (
        <>
          <Show when={rv().stale}>
            <span class={`${CHIP} ob-stale border-gold-deep text-gold-leaf`} title="the forest moved since this PR body was published — its “Where this sits” is out of date">
              packet stale — {staleLabel(rv())}
              <button class="cursor-pointer border-0 bg-transparent p-0 font-mono text-[10.5px] text-gold-leaf underline decoration-gold-deep underline-offset-2 hover:text-ink" title="the published body with only “Where this sits” brought up to date" onClick={(e) => void copy(e)}>
                {copied() ? "✓ copied" : "copy updated body"}
              </button>
              <a class="text-ink-dim no-underline hover:text-ink" href={rv().url} target="_blank" rel="noopener" onClick={(e) => e.stopPropagation()} title="edit the PR body on GitHub">edit ↗</a>
            </span>
          </Show>
          <Show when={verdictLabel(rv())}>
            <a
              class={`${CHIP} ob-verdict no-underline ${rv().findings.length ? "border-ember/40 text-ember" : "border-[#3c4a30] text-add"} hover:border-gold-leaf`}
              href={rv().url + (rv().findings.length ? "/files" : "")}
              target="_blank"
              rel="noopener"
              onClick={(e) => e.stopPropagation()}
              title={rv().findings.length ? rv().findings.map((f) => `${f.claim != null ? `claim ${f.claim + 1}: ` : ""}${f.body}`).join("\n\n") : "the john-hankles bot checked the diff against Intent and left no open findings"}
            >
              {rv().findings.length ? "✗ " : "✓ "}{verdictLabel(rv())}
            </a>
          </Show>
        </>
      )}
    </Show>
  );
}

export function PrChip(props: { n: OutboxNode }) {
  const pr = () => props.n.pr;
  return (
    <Show when={pr()} fallback={
      <span class={`${CHIP} border-transparent text-ink-faint`}>
        {props.n.pushed === "synced" ? "on origin · no PR" : props.n.pushed === "ahead" ? `↑${props.n.ahead} to push` : "local"}
      </span>
    }>
      {(p) => (
        <a
          class={`${CHIP} no-underline ${p().state === "MERGED" ? "border-gold-deep text-gold-deep" : p().review === "APPROVED" ? "border-[#3c4a30] text-add" : "border-[#33463f] text-patina"} hover:border-gold-leaf`}
          href={p().url}
          target="_blank"
          rel="noopener"
          onClick={(e) => e.stopPropagation()}
        >
          #{p().number}
          {p().state === "MERGED" ? " merged" : p().draft ? " draft" : p().review === "APPROVED" ? " ✓ approved" : " in review"}
        </a>
      )}
    </Show>
  );
}

// The landing title, editable in place: what squash-merges onto main, so the one string worth
// fixing before a push. Saves to branch.<b>.stack-pr-title; an emptied field falls back to the
// opening commit's subject.
export function LandingTitle(props: { n: OutboxNode; repo: string; actions: OutboxActions; editing: boolean; setEditing: (on: boolean) => void; class?: string }) {
  const editable = () => canMutate && !props.n.pr;
  let input: HTMLInputElement | undefined;
  createEffect(() => {
    if (props.editing) queueMicrotask(() => { input?.focus(); input?.select(); });
  });
  const save = () => {
    const v = input?.value.trim() ?? "";
    props.setEditing(false);
    if (v !== props.n.title) void props.actions.setTitle(props.repo, props.n.branch, v === props.n.subjects.at(-1) ? "" : v);
  };
  return (
    <Show when={props.editing && editable()} fallback={
      <span
        class={`min-w-0 overflow-hidden text-ellipsis whitespace-nowrap max-[640px]:whitespace-normal ${editable() ? "cursor-text decoration-gold-deep decoration-dotted underline-offset-4 hover:underline" : ""} ${props.class ?? ""}`}
        title={editable() ? `the PR title that will land — click (or e) to edit${props.n.titleSource === "saved" ? "" : " · from the opening commit"}` : props.n.title}
        onClick={(e) => { if (editable()) { e.stopPropagation(); props.setEditing(true); } }}
      >
        {props.n.title}
        <Show when={props.n.titleSource === "saved"}><span class="ml-[6px] align-[1px] font-mono text-[9px] tracking-[0.1em] text-gold-deep">SET</span></Show>
      </span>
    }>
      <input
        ref={input}
        class="min-w-0 flex-1 rounded-[5px] border border-gold-deep bg-vellum-night px-[6px] py-px font-display text-[15px] text-ink outline-none focus:border-gold-leaf"
        value={props.n.title}
        maxLength={120}
        onClick={(e) => e.stopPropagation()}
        onKeyDown={(e) => {
          e.stopPropagation();
          if (e.key === "Enter") save();
          if (e.key === "Escape") props.setEditing(false);
        }}
        onBlur={save}
      />
    </Show>
  );
}
