import { createSignal, Show, onMount, onCleanup } from "solid-js";
import { Portal } from "solid-js/web";
import { useQueryClient } from "@tanstack/solid-query";
import { canMutate, withRepo } from "./provider";
import { normalizeTicket } from "./ticket";

// The forest⇄Linear tie point (was a bare window.prompt). Same portal mechanics as
// SessionPicker — an in-place absolute pop gets clipped/out-stacked by the sticky header.
export function TicketChip(props: { project: string; ticket?: string }) {
  const [open, setOpen] = createSignal(false);
  return (
    <span class="sp-anchor relative inline-flex">
      <button
        class="fo-ticket cursor-pointer rounded-[6px] border border-transparent bg-transparent px-[4px] py-[1px] font-mono text-[11px] text-ink-faint hover:border-rule hover:text-ink-dim"
        title={props.ticket
          ? `Linear ${props.ticket.toUpperCase()} — commit scopes read type(${props.ticket}):; click to change`
          : "tie this forest to a Linear ticket — commit scopes become type(loo-####):"}
        onClick={() => canMutate && setOpen((v) => !v)}
      >
        {props.ticket ?? "＋ ticket"}
      </button>
      <Show when={open()}>
        <TicketPop project={props.project} ticket={props.ticket} onClose={() => setOpen(false)} />
      </Show>
    </span>
  );
}

function TicketPop(props: { project: string; ticket?: string; onClose: () => void }) {
  const qc = useQueryClient();
  const [draft, setDraft] = createSignal(props.ticket?.toUpperCase() ?? "LOO-");
  const [busy, setBusy] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);
  const [pos, setPos] = createSignal<{ top: number; left: number } | null>(null);
  let marker: HTMLSpanElement | undefined;
  let el: HTMLDivElement | undefined;
  let inputEl: HTMLInputElement | undefined;
  const away = (e: MouseEvent) => {
    if (el && !el.contains(e.target as Node)) {
      props.onClose();
    }
  };
  const key = (e: KeyboardEvent) => {
    if (e.key === "Escape") {
      e.stopPropagation();
      props.onClose();
    }
  };
  const drift = (e: Event) => {
    // fixed positioning doesn't track a scrolling anchor — close instead of floating away
    if (!el || !el.contains(e.target as Node)) {
      props.onClose();
    }
  };
  onMount(() => {
    const anchor = marker?.parentElement;
    if (anchor) {
      const r = anchor.getBoundingClientRect();
      setPos({ top: r.bottom + 6, left: r.left });
    }
    // capture phase, registered after the opening click's mousedown already fired — so the
    // very next press anywhere outside dismisses, even on stopPropagation-happy targets.
    document.addEventListener("mousedown", away, true);
    document.addEventListener("keydown", key, true);
    document.addEventListener("scroll", drift, true);
    window.addEventListener("resize", drift);
    requestAnimationFrame(() => inputEl?.focus());
  });
  onCleanup(() => {
    document.removeEventListener("mousedown", away, true);
    document.removeEventListener("keydown", key, true);
    document.removeEventListener("scroll", drift, true);
    window.removeEventListener("resize", drift);
  });
  const save = async () => {
    const t = normalizeTicket(draft());
    if (t === null) {
      setError("must look like LOO-1234");
      return;
    }
    if (t === (props.ticket?.toUpperCase() ?? "")) {
      props.onClose();
      return;
    }
    setBusy(true);
    try {
      const r = await fetch(withRepo("/ticket"), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ project: props.project, ticket: t }),
      });
      if (r.ok) {
        qc.invalidateQueries({ queryKey: ["model"] });
        props.onClose();
        return;
      }
      const e = (await r.json().catch(() => null)) as { error?: string } | null;
      setError(e?.error ?? "ticket save failed");
    } catch {
      setError("ticket save failed");
    } finally {
      setBusy(false);
    }
  };
  return (
    <>
      <span ref={marker} class="hidden" aria-hidden="true" />
      <Show when={pos()}>
        {(p) => (
          <Portal>
            <div
              class="ticket-pop fixed z-[62] flex w-[260px] cursor-default flex-col gap-[6px] rounded-lg border border-[#3a332b] bg-[#1b1815] p-[8px] text-left text-[11.5px] normal-case not-italic shadow-[0_12px_32px_rgba(0,0,0,.5)] [letter-spacing:normal]"
              style={{ top: `${p().top}px`, left: `${p().left}px` }}
              ref={el}
            >
              <div class="tk-head px-1 text-[9.5px] tracking-[.08em] uppercase text-[#6f675a]">Linear ticket — blank clears</div>
              <input
                class="tk-input min-w-0 rounded-[5px] border border-gold-deep bg-vellum-raise px-[7px] py-[4px] font-mono text-[12.5px] text-ink outline-none"
                value={draft()}
                disabled={busy()}
                spellcheck={false}
                onInput={(e) => {
                  setDraft(e.currentTarget.value);
                  setError(null);
                }}
                onKeyDown={(e) => {
                  if (e.key === "Enter") save();
                }}
                ref={inputEl}
              />
              <Show when={error()}>
                <div class="tk-error px-1 text-[10.5px] text-del">{error()}</div>
              </Show>
              <div class="flex items-center gap-2 px-1">
                <button class="tk-save flex-none cursor-pointer text-[11px] leading-[1.55] text-gold-leaf enabled:hover:text-ink" disabled={busy()} onClick={save}>save</button>
                <button class="tk-cancel flex-none cursor-pointer text-[11px] leading-[1.55] text-ink-faint enabled:hover:text-ink" disabled={busy()} onClick={() => props.onClose()}>cancel</button>
                <span class="tk-hint ml-auto text-[10px] whitespace-nowrap text-[#6f675a]">↵ save · esc close</span>
              </div>
            </div>
          </Portal>
        )}
      </Show>
    </>
  );
}
