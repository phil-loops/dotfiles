// The review packet in the words column: the PR body as a contract a reviewer checks the diff
// against. Intent and Not-in-this-PR are short line lists, How-to-read a list the model drafts per
// tree; Where-this-sits and Verified are generated and read-only. The preview is the server's own
// render of the unsaved draft — the exact markdown the compare link will carry.
//
// After the PR exists the same data answers two questions without writing to GitHub: has the
// forest moved past the body's "Where this sits" (copy the updated body, paste it on GitHub), and
// what did the john-hankles bot dispute, placed under the claim it disputes.
import { createMemo, createSignal, For, Index, Show, type JSX } from "solid-js";
import { createQuery, keepPreviousData, useQueryClient } from "@tanstack/solid-query";
import { withRepo, canMutate } from "./provider";
import { postStatus } from "./actions";
import { renderMarkdown } from "./markdown";
import {
  claimHint, findingsByClaim, normalizeHand, staleLabel, verdictLabel, MAX_CLAIMS,
  type Hand, type Packet, type Review,
} from "./packetModel";

const LABEL = "text-[10px] uppercase tracking-[0.11em] text-ink-faint";
const FIELD = "w-full resize-none border-0 bg-transparent p-0 font-mono outline-none [field-sizing:content] placeholder:text-ink-faint/70";
const LINK = "cursor-pointer border-0 bg-transparent p-0 font-mono text-[10px] text-ink-faint underline-offset-2 hover:text-ink-dim hover:underline disabled:cursor-default disabled:opacity-40";

export const packetUrl = (branch: string, extra = "") => withRepo("/packet?branch=" + encodeURIComponent(branch) + extra);

export function usePacket(branch: () => string, opts: { guide?: () => boolean; enabled?: () => boolean } = {}) {
  return createQuery(() => ({
    queryKey: ["packet", branch(), !!opts.guide?.()],
    queryFn: () => fetch(packetUrl(branch(), opts.guide?.() ? "&guide=auto" : "")).then((r) => r.json() as Promise<Packet>),
    enabled: !!branch() && (opts.enabled?.() ?? true),
    placeholderData: keepPreviousData,
    refetchInterval: (q) => (q.state.data?.guide?.state === "running" ? 2500 : false),
  }));
}

/** An editable list of one-line entries: ↵ adds a line below, ⌫ on an empty line removes it. */
function LineList(props: {
  lines: string[];
  onChange: (lines: string[]) => void;
  marker: (i: number) => string;
  placeholder: string;
  add: string;
  max?: number;
  hint?: (line: string) => string | null;
  readOnly?: boolean;
  class?: string;
}) {
  let box: HTMLOListElement | undefined;
  const [focus, setFocus] = createSignal<number | null>(null);
  const focusAt = (i: number) => queueMicrotask(() => box?.querySelectorAll<HTMLTextAreaElement>("textarea")[i]?.focus());
  const set = (i: number, v: string) => props.onChange(props.lines.map((x, j) => (j === i ? v : x)));
  const insert = (i: number) => { props.onChange([...props.lines.slice(0, i), "", ...props.lines.slice(i)]); focusAt(i); };
  const remove = (i: number) => { props.onChange(props.lines.filter((_, j) => j !== i)); focusAt(Math.max(0, i - 1)); };
  const full = () => props.max != null && props.lines.length >= props.max;
  return (
    <div>
      <ol ref={box} class="m-0 flex list-none flex-col gap-[2px] p-0">
        <Index each={props.lines}>
          {(line, i) => {
            const hint = () => (focus() === i || line().trim() ? props.hint?.(line()) ?? null : null);
            return (
              <li class="group/ln">
                <div class="flex items-baseline gap-[7px]">
                  <span class="w-[12px] flex-none text-right text-[10.5px] text-ink-faint">{props.marker(i)}</span>
                  <textarea
                    class={`${FIELD} pk-line min-w-0 flex-1 text-[11.5px] leading-[1.5] text-ink ${props.class ?? ""}`}
                    rows={1}
                    value={line()}
                    spellcheck={true}
                    readOnly={props.readOnly}
                    placeholder={props.placeholder}
                    onFocus={() => setFocus(i)}
                    onBlur={() => setFocus((f) => (f === i ? null : f))}
                    onInput={(e) => set(i, e.currentTarget.value.replace(/\n/g, " "))}
                    onKeyDown={(e) => {
                      if (e.key === "Enter" && !e.metaKey && !e.ctrlKey) {
                        e.preventDefault();
                        if (!full()) insert(i + 1);
                      } else if (e.key === "Escape") {
                        e.preventDefault();
                        e.currentTarget.blur();
                      } else if (e.key === "Backspace" && !line() && props.lines.length > 0) {
                        e.preventDefault();
                        remove(i);
                      }
                    }}
                  />
                  <Show when={!props.readOnly}>
                    <button
                      tabIndex={-1}
                      class="flex-none cursor-pointer border-0 bg-transparent p-0 text-[11px] text-ink-faint opacity-0 group-hover/ln:opacity-100 hover:text-del"
                      title="drop this line"
                      onClick={() => remove(i)}
                    >×</button>
                  </Show>
                </div>
                <Show when={hint() && (focus() === i || !!line().trim())}>
                  <p class="pk-hint m-0 mt-[2px] ml-[19px] w-fit rounded-[4px] border border-dashed border-ember/40 px-[6px] py-[1px] text-[10.5px] leading-[1.5] text-ember">{hint()}</p>
                </Show>
              </li>
            );
          }}
        </Index>
      </ol>
      <Show when={!props.readOnly && !full()}>
        <button class={`${LINK} mt-[3px] ml-[19px] no-underline`} onClick={() => insert(props.lines.length)}>+ {props.add}</button>
      </Show>
    </div>
  );
}

function Part(props: { label: string; aside?: JSX.Element; children: JSX.Element }) {
  return (
    <div class="pk-part mt-[12px]" data-part={props.label}>
      <div class="mb-[5px] flex items-baseline gap-[8px]"><span class={LABEL}>{props.label}</span><span class="ml-auto flex items-baseline gap-[8px]">{props.aside}</span></div>
      {props.children}
    </div>
  );
}

const Generated = (props: { lines: string[] }) => (
  <div class="pk-generated rounded-[5px] bg-[rgba(255,255,255,0.015)] px-[8px] py-[5px] text-[11px] leading-[1.6] text-ink-dim">
    <For each={props.lines}>
      {(ln) => {
        const text = ln.replace(/^- /, "");
        const me = text.includes("**this PR**");
        return ln.trim()
          ? <div class={`whitespace-pre-wrap ${me ? "text-gold-leaf" : ""}`}>{text.replace(/\*\*/g, "")}</div>
          : <div class="h-[6px]" />;
      }}
    </For>
  </div>
);

/** The packet editor: lives under the PR title in "lands on main as" until the PR exists. */
export function PacketEditor(props: {
  branch: () => string;
  title: () => string;
  hand: () => Hand;
  setHand: (h: Hand) => void;
  label: () => boolean;
  setLabel: (on: boolean) => void;
  packet: () => Packet | undefined;
  refetch: () => void;
}) {
  const qc = useQueryClient();
  const [mode, setMode] = createSignal<"write" | "preview">("write");
  const p = () => props.packet();
  const s = () => p()?.sections;
  const intent = () => props.hand().intent ?? s()?.intentSeed ?? [];
  const read = () => props.hand().read ?? s()?.readGenerated ?? [];
  const patch = (x: Partial<Hand>) => props.setHand({ ...props.hand(), ...x });
  const draftKey = createMemo(() => JSON.stringify(normalizeHand(props.hand())));
  const preview = createQuery(() => ({
    queryKey: ["packet-preview", props.branch(), draftKey()],
    queryFn: () => fetch(packetUrl(props.branch(), "&hand=" + encodeURIComponent(draftKey()))).then((r) => r.json() as Promise<Packet>),
    enabled: mode() === "preview" && !!props.branch(),
    placeholderData: keepPreviousData,
  }));
  const [drafting, setDrafting] = createSignal(false);
  const redraft = async () => {
    setDrafting(true);
    try {
      await postStatus("/packet-guide", { branch: props.branch() });
      void qc.invalidateQueries({ queryKey: ["packet", props.branch()] });
      props.refetch();
    } finally {
      setDrafting(false);
    }
  };
  const guide = () => p()?.guide.state ?? "none";
  const readNote = () => {
    if (props.hand().read !== null) return "edited";
    if (guide() === "running") return "drafting with sonnet…";
    if (s()?.readSource === "model") return `✦ sonnet · tree ${p()!.tree.slice(0, 7)}`;
    if (guide() === "failed") return "by layer — the model draft failed";
    return "by layer";
  };

  return (
    <div class="pk-editor mt-[10px] border-x-0 border-b-0 border-t border-dashed border-rule pt-[8px]">
      <div class="flex items-baseline gap-[10px]">
        <span class={LABEL}>review packet</span>
        <span class="flex items-baseline gap-[2px] text-[10.5px]">
          <For each={["write", "preview"] as const}>
            {(m) => (
              <button
                class={`pk-mode cursor-pointer rounded-[4px] border-0 bg-transparent px-[5px] py-0 font-mono text-[10.5px] ${mode() === m ? "bg-gold-wash text-gold-leaf" : "text-ink-faint hover:text-ink-dim"}`}
                onClick={() => setMode(m)}
              >{m}</button>
            )}
          </For>
        </span>
        <button
          class={`pk-label ml-auto cursor-pointer border-0 bg-transparent p-0 font-mono text-[10.5px] ${props.label() ? "text-patina" : "text-ink-faint"} hover:text-ink`}
          title={props.label()
            ? `the compare link asks GitHub to label the PR ${p()?.labelName ?? "ai-code-review"} — the bot reviews once, checking the diff against Intent`
            : "no review label — the bot won't check this PR's claims"}
          disabled={!canMutate}
          onClick={() => props.setLabel(!props.label())}
        >{props.label() ? "◉" : "○"} {p()?.labelName ?? "ai-code-review"}</button>
      </div>

      <Show when={p()} fallback={<p class="m-0 mt-[8px] text-[11px] italic text-ink-faint">drafting the packet…</p>}>
        <Show when={mode() === "write"} fallback={
          <div class="pk-preview mt-[10px] rounded-[6px] border border-solid border-rule bg-vellum-night px-[14px] py-[12px]">
            <div class="mb-[10px] border-x-0 border-t-0 border-b border-solid border-rule pb-[8px] font-[system-ui] text-[15px] font-semibold leading-[1.35] text-ink">{props.title()}</div>
            <Show when={preview.data?.ok} fallback={<p class="m-0 text-[11px] italic text-ink-faint">rendering…</p>}>
              <div class="packet-md" innerHTML={renderMarkdown(preview.data!.packetBody)} />
            </Show>
          </div>
        }>
          <textarea
            class={`${FIELD} pk-lead mt-[8px] text-[11.5px] leading-[1.55] text-ink-dim`}
            rows={1}
            value={props.hand().lead}
            placeholder="your words on top — optional"
            onInput={(e) => patch({ lead: e.currentTarget.value })}
          />

          <Part
            label="intent"
            aside={<>
              <span class="text-[10px] text-ink-faint">{props.hand().intent === null ? "seeded" : "claims the diff must hold"}</span>
              <Show when={props.hand().intent !== null}><button class={LINK} onClick={() => patch({ intent: null })}>↺ reseed</button></Show>
            </>}
          >
            <LineList
              lines={intent()}
              onChange={(lines) => patch({ intent: lines })}
              marker={(i) => `${i + 1}`}
              placeholder="a statement the diff confirms or contradicts"
              add="claim"
              max={MAX_CLAIMS}
              hint={claimHint}
            />
          </Part>

          <Part label="not in this PR">
            <Show when={s()!.notDerived.length}>
              <ul class="m-0 mb-[2px] list-none p-0">
                <For each={s()!.notDerived}>
                  {(n) => <li class="flex gap-[7px] text-[11px] leading-[1.55] text-ink-faint"><span class="w-[12px] flex-none text-right">·</span><span>{n}</span></li>}
                </For>
              </ul>
            </Show>
            <LineList
              lines={props.hand().not}
              onChange={(lines) => patch({ not: lines })}
              marker={() => "·"}
              placeholder="something a reviewer might expect here"
              add="exclusion"
            />
          </Part>

          <Show when={s()!.where.length}>
            <Part label="where this sits" aside={<span class="text-[10px] text-ink-faint">from the forest</span>}>
              <Generated lines={s()!.where} />
            </Part>
          </Show>

          <Part
            label="how to read it"
            aside={<>
              <span class={`text-[10px] ${guide() === "running" && props.hand().read === null ? "animate-breathe text-gold-leaf" : "text-ink-faint"}`}>{readNote()}</span>
              <Show when={props.hand().read !== null}><button class={LINK} onClick={() => patch({ read: null })}>↺ use the draft</button></Show>
              <Show when={props.hand().read === null && guide() !== "running" && canMutate}>
                <button class={LINK} disabled={drafting()} title="draft the reading order with sonnet for this exact tree" onClick={() => void redraft()}>
                  {s()!.readSource === "model" ? "↻ redraft" : "✦ draft"}
                </button>
              </Show>
            </>}
          >
            <LineList
              lines={read()}
              onChange={(lines) => patch({ read: lines })}
              marker={(i) => `${i + 1}`}
              placeholder="`path` — what to look for"
              add="file"
              class="text-ink-dim"
            />
          </Part>

          <Show when={s()!.verified.length}>
            <Part label="verified" aside={<span class="text-[10px] text-ink-faint">facts only</span>}>
              <Generated lines={s()!.verified.map((v) => "✓ " + v)} />
            </Part>
          </Show>
        </Show>
      </Show>
    </div>
  );
}

const copy = async (text: string) => {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
};

/** Stale-since-publish + the bot's findings under the claims they dispute. Read-only. */
export function PacketReview(props: { review: Review; compact?: boolean }) {
  const [copied, setCopied] = createSignal<boolean | null>(null);
  const [open, setOpen] = createSignal(!props.compact);
  const groups = () => findingsByClaim(props.review);
  const verdict = () => verdictLabel(props.review);
  return (
    <div class="pk-review font-mono text-[11px]">
      <div class="flex flex-wrap items-baseline gap-x-[10px] gap-y-[3px]">
        <Show when={props.review.stale}>
          <span class="pk-stale text-gold-leaf" title="the forest moved since this PR body was published — its “Where this sits” is out of date">
            packet stale — {staleLabel(props.review)}
          </span>
          <button
            class={`${LINK} text-gold-leaf no-underline hover:underline`}
            title="the PR body as published, with only “Where this sits” brought up to date — paste it on GitHub"
            onClick={() => void copy(props.review.updatedBody).then(setCopied)}
          >{copied() === true ? "✓ copied" : copied() === false ? "copy failed" : "copy updated body"}</button>
          <a class={`${LINK} no-underline hover:underline`} href={props.review.url} target="_blank" rel="noopener">edit on GitHub ↗</a>
        </Show>
        <Show when={verdict()}>
          <Show
            when={props.review.findings.length}
            fallback={<span class="pk-held text-add" title="the john-hankles bot reviewed this PR against its Intent and left no open findings">✓ claims held</span>}
          >
            <button
              class="pk-findings cursor-pointer border-0 bg-transparent p-0 font-mono text-[11px] text-ember hover:text-ink"
              title="open john-hankles findings on this PR"
              onClick={() => setOpen((o) => !o)}
            >{open() ? "▾" : "▸"} {verdict()}</button>
          </Show>
        </Show>
      </div>
      <Show when={open() && props.review.findings.length}>
        <ol class="m-0 mt-[6px] flex list-none flex-col gap-[7px] p-0">
          <For each={groups()}>
            {(g) => (
              <li class="pk-claim">
                <div class={`text-[11px] leading-[1.5] ${g.claim === null ? "text-ink-faint" : "text-ink-dim"}`}>
                  {g.claim === null ? "not tied to a claim" : <><span class="text-ember">✗ claim {g.claim + 1}</span> {g.text}</>}
                </div>
                <For each={g.findings}>
                  {(f) => (
                    <a
                      class="mt-[3px] ml-[12px] block border-y-0 border-r-0 border-l-2 border-solid border-ember/40 pl-[8px] text-[11px] leading-[1.5] text-ink-dim no-underline hover:border-ember hover:text-ink"
                      href={f.url || props.review.url}
                      target="_blank"
                      rel="noopener"
                    >
                      <span class="text-ink-faint">{f.path}{f.line ? `:${f.line}` : ""}{f.outdated ? " · outdated" : ""}</span> {f.body}
                    </a>
                  )}
                </For>
              </li>
            )}
          </For>
        </ol>
      </Show>
    </div>
  );
}
