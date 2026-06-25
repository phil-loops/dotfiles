import { createSignal, createEffect, onCleanup, Show, For, type Accessor } from "solid-js";
import type { DiffSelection } from "./useDiffSelection";
import { chatModel, setChatModel, CHAT_MODELS } from "./chatStore";
import { track } from "./track";

// AskClaudeChip — the floating "ask Claude" affordance that appears when you sweep-select
// text in a diff (see ../design-select-to-claude.md). Sweep → chip floats by the selection →
// optional one-line instruction → send. branch + file paths ride along silently.
//
// The floating-toolbar trap: focusing the input / clicking a button collapses the native
// text selection → selection() goes null → the chip would vanish before we can send. So we
// SNAPSHOT selection() into `snap` the moment it's non-null and send the snapshot. We only
// drop `snap` on an explicit dismiss (send, Esc, ×, or a click that starts elsewhere).
export default function AskClaudeChip(props: {
  selection: Accessor<DiffSelection | null>;
  branch: Accessor<string>;
  onClear?: () => void;
}) {
  const [snap, setSnap] = createSignal<DiffSelection | null>(null);
  const [pos, setPos] = createSignal({ x: 16, y: 16 });
  const [instruction, setInstruction] = createSignal("");
  const [sending, setSending] = createSignal(false);
  const [sent, setSent] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);
  let chipEl: HTMLDivElement | undefined;

  // Capture the live selection (and its on-screen rect) before any focus collapses it.
  createEffect(() => {
    const cur = props.selection();
    if (!cur) {
      return; // keep the snapshot — a collapse from focusing our own input is expected
    }
    setSnap(cur);
    setError(null);
    const s = window.getSelection();
    if (s && s.rangeCount) {
      const rect = s.getRangeAt(s.rangeCount - 1).getBoundingClientRect();
      if (rect && (rect.width || rect.height)) {
        const W = 340;
        setPos({
          x: Math.max(8, Math.min(rect.left, window.innerWidth - W - 8)),
          y: rect.bottom + 8,
        });
      }
    }
  });

  const reset = () => {
    setSnap(null);
    setInstruction("");
    setSending(false);
    setSent(false);
    setError(null);
  };
  // Full dismiss: also drop the native selection (after send / Esc / ×).
  const dismiss = () => {
    props.onClear?.();
    reset();
  };

  const send = async () => {
    const s = snap();
    const branch = props.branch?.();
    if (!s || !branch || sending()) {
      return;
    }
    setSending(true);
    setError(null);
    try {
      const r = await fetch("/claude", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          branch,
          selections: s.files,
          instruction: instruction().trim(),
          model: chatModel(),
        }),
      });
      if (!r.ok) {
        throw new Error(`/claude → ${r.status}`);
      }
      const { sessionId } = (await r.json().catch(() => ({}))) as { sessionId?: string };
      track("claude", { branch, sessionId }); // link this launch to its mineable transcript
      setSent(true);
      setTimeout(dismiss, 900); // brief "sent ✦" flash, then clear
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setSending(false);
    }
  };

  // Esc dismisses; a mousedown that starts outside the chip drops the snapshot (a new
  // selection re-arms it via the effect; an empty click just hides it). We DON'T touch the
  // native selection here — the click itself will reset it.
  const onKey = (e: KeyboardEvent) => {
    if (e.key === "Escape" && snap()) {
      dismiss();
    }
  };
  const onDocDown = (e: MouseEvent) => {
    if (snap() && chipEl && !chipEl.contains(e.target as Node)) {
      reset();
    }
  };
  window.addEventListener("keydown", onKey);
  document.addEventListener("mousedown", onDocDown);
  onCleanup(() => {
    window.removeEventListener("keydown", onKey);
    document.removeEventListener("mousedown", onDocDown);
  });

  const summary = () => {
    const s = snap();
    if (!s) {
      return "";
    }
    const l = `${s.lineCount} line${s.lineCount === 1 ? "" : "s"}`;
    const f = `${s.fileCount} file${s.fileCount === 1 ? "" : "s"}`;
    return `${l} · ${f}`;
  };

  return (
    <>
      <style>{CHIP_CSS}</style>
      <Show when={snap()}>
        <div
          class="dsc-chip"
          classList={{ sent: sent() }}
          ref={chipEl}
          style={{ left: `${pos().x}px`, top: `${pos().y}px` }}
        >
          <div class="dsc-head">
            <span class="dsc-mark">✦</span>
            <span class="dsc-summary">{summary()}</span>
            <button
              class="dsc-x"
              title="dismiss (esc)"
              onMouseDown={(e) => e.preventDefault()}
              onClick={dismiss}
            >
              ×
            </button>
          </div>
          <input
            class="dsc-input"
            placeholder="what should Claude do? (optional)"
            autofocus
            value={instruction()}
            disabled={sending() || sent()}
            onInput={(e) => setInstruction(e.currentTarget.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                send();
              } else if (e.key === "Escape") {
                e.preventDefault();
                dismiss();
              }
            }}
          />
          <Show when={error()}>
            <div class="dsc-err">{error()}</div>
          </Show>
          <div class="dsc-foot">
            <div class="dsc-models" role="group" aria-label="model">
              <For each={CHAT_MODELS}>
                {(m) => (
                  <button
                    class="dsc-model"
                    classList={{ on: chatModel() === m }}
                    title={`launch this session with claude ${m}`}
                    disabled={sending() || sent()}
                    onMouseDown={(e) => e.preventDefault()}
                    onClick={() => setChatModel(m)}
                  >
                    {m}
                  </button>
                )}
              </For>
            </div>
            <button
              class="dsc-send"
              disabled={sending() || sent()}
              onMouseDown={(e) => e.preventDefault()}
              onClick={send}
            >
              {sent() ? "sent ✦" : sending() ? "starting…" : "ask Claude ✦"}
            </button>
          </div>
        </div>
      </Show>
    </>
  );
}

// Self-contained styling (no index.css edit) — matches the viewer's gold/ember dark theme
// and IBM Plex Mono body. Scoped under .dsc-* so it can't bleed into the rest of the app.
const CHIP_CSS = `
.dsc-chip {
  position: fixed;
  z-index: 50;
  width: 340px;
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 10px 12px;
  background: var(--raised, #1b1815);
  border: 1px solid var(--line, #3a332b);
  border-radius: 10px;
  box-shadow: 0 10px 30px rgba(0, 0, 0, 0.5);
  font-family: "IBM Plex Mono", ui-monospace, monospace;
  font-size: 12.5px;
  color: var(--ink, #e9e2d4);
  animation: dsc-rise 140ms ease-out;
}
.dsc-chip.sent { border-color: var(--gold, #e0ad4e); }
@keyframes dsc-rise { from { opacity: 0; transform: translateY(4px); } to { opacity: 1; transform: none; } }
.dsc-head { display: flex; align-items: center; gap: 8px; }
.dsc-mark { color: var(--gold, #e0ad4e); }
.dsc-summary { flex: 1; color: var(--dim, #a89e8c); }
.dsc-x {
  border: 0; background: transparent; color: var(--faint, #6f675a);
  font-size: 16px; line-height: 1; cursor: pointer; padding: 0 2px;
}
.dsc-x:hover { color: var(--ink, #e9e2d4); }
.dsc-input {
  width: 100%; box-sizing: border-box;
  background: var(--bg, #100e0c); color: var(--ink, #e9e2d4);
  border: 1px solid var(--line, #3a332b); border-radius: 6px;
  padding: 6px 8px; font: inherit; outline: none;
}
.dsc-input:focus { border-color: var(--gold, #e0ad4e); }
.dsc-err { color: var(--ember, #d36a36); font-size: 11.5px; }
.dsc-foot { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
.dsc-models { display: flex; gap: 2px; }
.dsc-model {
  font: inherit; font-size: 10.5px; cursor: pointer;
  color: var(--faint, #6f675a); background: transparent;
  border: 1px solid transparent; border-radius: 5px; padding: 2px 7px;
}
.dsc-model:hover:not(:disabled) { color: var(--dim, #a89e8c); }
.dsc-model.on { color: var(--gold, #e0ad4e); border-color: var(--gold, #e0ad4e); background: rgba(224,173,78,.08); }
.dsc-model:disabled { opacity: 0.5; cursor: default; }
.dsc-send {
  background: var(--gold, #e0ad4e); color: #1a160f;
  border: 0; border-radius: 6px; padding: 6px 12px;
  font: inherit; font-weight: 600; cursor: pointer;
}
.dsc-send:disabled { opacity: 0.6; cursor: default; }
`;
