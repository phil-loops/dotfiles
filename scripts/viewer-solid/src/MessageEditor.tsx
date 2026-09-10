// The commit-message editor — where every prep motion lands: the ONE outgoing commit's subject
// and body, editable before the push. Saving rewrites only that unpushed commit (server-verified);
// the tree, the author and the gates verdict are untouched.
//
// Split out of NodeActions with the push door: a hook for the state the header still reads
// (whether it is open, what the draft says) and a component for the box itself.
import { createSignal } from "solid-js";
import { Show } from "solid-js";
import { createMutation } from "@tanstack/solid-query";
import { withRepo } from "./provider";
import { post } from "./actions";
import { PlanStepsEditor } from "./PlanStepsEditor";

const FIX_SHAPE = "cursor-pointer rounded-[5px] border bg-transparent px-[9px] py-[3px] text-[12px] leading-[1.55] opacity-90 enabled:hover:opacity-100 disabled:cursor-default disabled:opacity-50";
const EDITOR_CLOSE = "cursor-pointer text-[11px] leading-[1.55] text-ink-faint";

export function useMessageEditor(d: {
  branch: () => string;
  setDone: (s: string | null) => void;
  refresh: () => void;
  close: () => void;
}) {
  const [subject, setSubject] = createSignal("");
  const [body, setBody] = createSignal("");
  const saveMsg = createMutation(() => ({
    mutationFn: () =>
      post<{ ok?: boolean; err?: string }>("/prep-message", {
        branch: d.branch(), subject: subject(), body: body(),
      }),
    onSuccess: (r) => {
      if (!r.ok) {
        d.setDone(`✗ ${r.err || "couldn't save the message"}`);
        return;
      }
      d.setDone("✓ message saved");
      d.close();
      d.refresh();
    },
    onError: (e) => d.setDone(`✗ ${(e as Error).message || "couldn't save the message"}`),
  }));

  // the opt-in claude pass — prep commits with a mechanical message so it never waits
  // on a model; this button is the only thing that asks claude to voice it
  const draftMsg = createMutation(() => ({
    mutationFn: () =>
      post<{ ok?: boolean; err?: string; subject?: string; body?: string }>("/draft-message", {
        branch: d.branch(),
      }),
    onSuccess: (r) => {
      if (!r.ok || !r.subject) {
        d.setDone(`✗ ${r.err || "couldn't draft the message"}`);
        return;
      }
      setSubject(r.subject);
      setBody(r.body ?? "");
    },
    onError: (e) => d.setDone(`✗ ${(e as Error).message || "couldn't draft the message"}`),
  }));

  // recompute this branch's forest-plan block from stack config and fold it into the body,
  // replacing any stale plan already there. Free — no model call, just where-it-fits facts.
  const planFill = createMutation(() => ({
    mutationFn: () =>
      fetch(withRepo("/plan-section") + "?branch=" + encodeURIComponent(d.branch())).then((r) =>
        r.text(),
      ),
    onSuccess: (section) => {
      const s = section.trim();
      if (!s) {
        d.setDone("✗ no plan — this branch isn't in a project");
        return;
      }
      const lines = body().split("\n");
      const cut = lines.findIndex((l) => l.startsWith("Part of "));
      const prose = (cut === -1 ? body() : lines.slice(0, cut).join("\n")).replace(/\s+$/, "");
      setBody(prose ? `${prose}\n\n${s}` : s);
    },
    onError: (e) => d.setDone(`✗ ${(e as Error).message || "couldn't recompute the plan"}`),
  }));
  return { subject, setSubject, body, setBody, saveMsg, draftMsg, planFill };
}

export type MessageEditorState = ReturnType<typeof useMessageEditor>;

export function MessageEditor(props: {
  ed: MessageEditorState;
  branch: () => string;
  routedNotes: () => string[];
  onClose: () => void;
  onPlanSaved: () => void;
}) {
  const ed = props.ed;
  return (
<div class="nh-editor mt-1 flex basis-full flex-col gap-[7px] rounded-[9px] border border-solid border-gold-deep bg-gold-wash px-[14px] py-3">
          <Show when={props.routedNotes().length}>
            <div class="nh-editor-routed text-[11px] italic text-patina">{props.routedNotes().join(" · ")}</div>
          </Show>
          <input
            class="nh-editor-subject border-x-0 border-t-0 border-b border-rule bg-transparent px-[1px] py-[3px] font-display text-[17px] font-semibold italic text-ink outline-none focus:border-b-gold-leaf"
            value={ed.subject()}
            placeholder="subject — the one line the team reads in history"
            onInput={(e) => ed.setSubject(e.currentTarget.value)}
          />
          {/* each step's line writes its OWN branch's durable story — so a story survives this
              branch's merge, instead of being frozen as text in this one commit's plan block */}
          <PlanStepsEditor branch={props.branch()} onSaved={props.onPlanSaved} />
          <textarea
            class="nh-editor-body resize-y border-0 bg-transparent p-[1px] font-mono text-[12px] leading-[1.55] text-ink-dim outline-none"
            value={ed.body()}
            placeholder="body — what ships and why"
            rows={5}
            onInput={(e) => ed.setBody(e.currentTarget.value)}
          />
          <div class="nh-editor-row flex items-center gap-[10px]">
            <button
              class={`nh-fix nh-editor-save ${FIX_SHAPE} border-gold-deep text-gold-leaf`}
              disabled={ed.saveMsg.isPending || !ed.subject().trim()}
              onClick={() => ed.saveMsg.mutate()}
            >
              {ed.saveMsg.isPending ? "saving…" : "save message"}
            </button>
            <button
              class={`nh-editor-close ${EDITOR_CLOSE}`}
              disabled={ed.planFill.isPending}
              title="recompute this branch's forest-plan block from the stack config (free — no model call)"
              onClick={() => ed.planFill.mutate()}
            >
              {ed.planFill.isPending ? "…" : "↻ plan"}
            </button>
            <button
              class={`nh-editor-close ${EDITOR_CLOSE}`}
              disabled={ed.draftMsg.isPending}
              title="ask claude to draft the message in your voice from the outgoing diff"
              onClick={() => ed.draftMsg.mutate()}
            >
              {ed.draftMsg.isPending ? "voicing…" : "✦ voice"}
            </button>
            <button class={`nh-editor-close ${EDITOR_CLOSE}`} onClick={() => props.onClose()}>
              close
            </button>
          </div>
        </div>
  );
}
