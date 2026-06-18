import { createSignal, onCleanup, onMount, For, Show, type JSX } from "solid-js";
import { createStore, produce } from "solid-js/store";
import type { FileDiff } from "./types";

// ChatPanel — "chat about this file", with Claude's answer streaming in token-by-token.
// A right-side drawer scoped to ONE file on ONE branch: the diff is the opening context,
// then it's a normal back-and-forth. POSTs /chat and reads the Server-Sent-Events the
// server proxies off a headless, read-only `claude -p`. Multi-turn is client-held: we keep
// the session_id from the first `done` and send it back as `resume`, so follow-ups stay on
// the same thread without re-sending the diff.
//
// EventSource only speaks GET, and we need a JSON POST body — so we read the SSE frames off
// the fetch response stream by hand (split on the blank-line frame boundary).
interface Msg {
  role: "you" | "claude";
  text: string;
}

export default function ChatPanel(props: { file: FileDiff; branch: string; onClose: () => void }) {
  const [msgs, setMsgs] = createStore<Msg[]>([]);
  const [pending, setPending] = createStore<string[]>([]); // queued while a turn streams
  const [input, setInput] = createSignal("");
  const [streaming, setStreaming] = createSignal(false);
  const [status, setStatus] = createSignal<string | null>(null);
  const [error, setError] = createSignal<string | null>(null);
  const [session, setSession] = createSignal<string>("");
  let scroller: HTMLDivElement | undefined;
  let inputEl: HTMLTextAreaElement | undefined;

  const pin = () => scroller && (scroller.scrollTop = scroller.scrollHeight);

  // stop the in-flight turn: abort the fetch (closes the stream → the server SIGKILLs the
  // headless claude), keep whatever streamed so far, then let the queue drain as normal.
  let abort: AbortController | null = null;
  const stop = () => abort?.abort();

  // You can fire off a message any time — even while Claude is still answering. `submit` just
  // enqueues; `pump` drains the queue one turn at a time. So a mid-stream message shows as
  // "queued" and auto-sends the instant the current turn ends — turns stay ordered, and each
  // resumes the same session thread.
  const submit = () => {
    const q = input().trim();
    if (!q) {
      return;
    }
    setInput("");
    setPending(pending.length, q);
    void pump();
  };

  const pump = async () => {
    if (streaming() || !pending.length) {
      return;
    }
    const q = pending[0];
    setPending(produce((p) => p.shift())); // dequeue synchronously, before any await
    await runTurn(q);
    void pump(); // chain the next queued message, if any
  };

  const runTurn = async (q: string) => {
    setError(null);
    setMsgs(msgs.length, { role: "you", text: q });
    const idx = msgs.length;
    setMsgs(idx, { role: "claude", text: "" });
    setStreaming(true);
    setStatus("starting");
    pin();
    const ctrl = new AbortController();
    abort = ctrl;
    try {
      const res = await fetch("/chat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        signal: ctrl.signal,
        body: JSON.stringify({
          branch: props.branch,
          path: props.file.path,
          patch: session() ? undefined : props.file.patch, // diff only seeds turn one
          question: q,
          resume: session() || undefined,
        }),
      });
      if (!res.ok || !res.body) {
        throw new Error(`/chat → ${res.status}`);
      }
      const reader = res.body.getReader();
      const dec = new TextDecoder();
      let buf = "";
      // The answer is "done" when the `done` frame lands — NOT when the HTTP stream finally
      // closes (the headless claude can take a beat to tear down after its last token). Freeing
      // the UI on `done` is why the input stops hanging; we then cancel the reader, which closes
      // the connection and lets the server SIGKILL the lingering claude instead of waiting on it.
      let finished = false;
      for (;;) {
        const { done, value } = await reader.read();
        if (done) {
          break;
        }
        buf += dec.decode(value, { stream: true });
        let nl: number;
        // each SSE frame ends in a blank line; a frame is "event: x\ndata: {…}"
        while ((nl = buf.indexOf("\n\n")) >= 0) {
          const frame = buf.slice(0, nl);
          buf = buf.slice(nl + 2);
          let event = "message";
          let data = "";
          for (const ln of frame.split("\n")) {
            if (ln.startsWith("event:")) {
              event = ln.slice(6).trim();
            } else if (ln.startsWith("data:")) {
              data += ln.slice(5).trim();
            }
          }
          if (!data) {
            continue;
          }
          const payload = JSON.parse(data);
          if (event === "token") {
            setStatus(null);
            setMsgs(idx, "text", (t) => t + (payload.t || ""));
            pin();
          } else if (event === "status") {
            setStatus(payload.s);
          } else if (event === "done") {
            if (payload.session_id) {
              setSession(payload.session_id);
            }
            finished = true;
          } else if (event === "error") {
            setError(payload.err || "stream error");
          }
        }
        if (finished) {
          await reader.cancel().catch(() => {});
          break;
        }
      }
    } catch (e) {
      // an aborted fetch is a user-initiated stop, not a failure — leave the partial answer be
      if (!ctrl.signal.aborted) {
        setError(e instanceof Error ? e.message : String(e));
      }
    } finally {
      setStreaming(false);
      setStatus(null);
      abort = null;
      // mark a stopped-before-any-token turn so it doesn't read as an empty answer or an error
      if (ctrl.signal.aborted) {
        if (!msgs[idx]?.text) {
          setMsgs(idx, "text", "⏹ stopped");
        }
      } else if (!msgs[idx]?.text && !error()) {
        setError("no response — the headless claude produced nothing");
      }
      inputEl?.focus();
    }
  };

  const onKey = (e: KeyboardEvent) => {
    if (e.key === "Escape") {
      props.onClose();
    }
  };
  onMount(() => {
    window.addEventListener("keydown", onKey);
    inputEl?.focus();
  });
  onCleanup(() => window.removeEventListener("keydown", onKey));

  const seg = (p: string): JSX.Element => {
    const i = p.lastIndexOf("/");
    return i < 0 ? <b>{p}</b> : [<span class="cp-dir">{p.slice(0, i + 1)}</span>, <b>{p.slice(i + 1)}</b>];
  };

  return (
    <>
      <style>{CSS}</style>
      <div class="cp-scrim" onClick={props.onClose} />
      <aside class="cp" role="dialog" aria-label="chat about this file">
        <header class="cp-head">
          <div class="cp-title">
            <span class="cp-mark">✦</span>
            <span class="cp-path">{seg(props.file.path)}</span>
          </div>
          <div class="cp-sub">
            <span class="cp-branch">{props.branch}</span>
            <button class="cp-x" title="close (esc)" onClick={props.onClose}>×</button>
          </div>
        </header>

        <div class="cp-body" ref={scroller}>
          <Show when={!msgs.length}>
            <p class="cp-empty">
              Ask anything about this diff — what it does, whether it's correct, what you'd
              change. Claude reads the diff and can look at related code (read-only).
            </p>
          </Show>
          <For each={msgs}>
            {(m, i) => (
              <div class="cp-turn" classList={{ you: m.role === "you", claude: m.role === "claude" }}>
                <span class="cp-who">{m.role}</span>
                <div class="cp-text">
                  {m.text}
                  <Show when={streaming() && m.role === "claude" && i() === msgs.length - 1}>
                    <span class="cp-caret" />
                  </Show>
                </div>
              </div>
            )}
          </For>
          <Show when={streaming() || status()}>
            <div class="cp-status">
              <span>{status() || "responding"}…</span>
              <Show when={streaming()}>
                <button class="cp-stop" title="stop responding" onClick={stop}>◼ stop</button>
              </Show>
            </div>
          </Show>
          {/* messages you sent while a turn was streaming — they auto-send in order */}
          <For each={pending}>
            {(p, i) => (
              <div class="cp-turn you queued">
                <span class="cp-who">queued</span>
                <div class="cp-text">
                  <span>{p}</span>
                  <button
                    class="cp-unqueue"
                    title="remove from queue"
                    onClick={() => setPending(produce((arr) => arr.splice(i(), 1)))}
                  >
                    ×
                  </button>
                </div>
              </div>
            )}
          </For>
          <Show when={error()}>
            <div class="cp-err">{error()}</div>
          </Show>
        </div>

        <footer class="cp-foot">
          {/* always sends — a message fired mid-stream queues and auto-sends when the turn ends */}
          <textarea
            class="cp-input"
            ref={inputEl}
            rows={2}
            placeholder={streaming() ? "Claude is responding — ⏎ to queue your next question…" : "ask about this file — ⏎ to send, ⇧⏎ for a newline"}
            value={input()}
            onInput={(e) => setInput(e.currentTarget.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                submit();
              }
            }}
          />
          <button class="cp-send" disabled={!input().trim()} onClick={submit}>
            {streaming() ? "queue ✦" : "send ✦"}
          </button>
        </footer>
      </aside>
    </>
  );
}

// Self-contained, scoped under .cp-* — rides the viewer's gold/ember dark palette and IBM
// Plex Mono without touching index.css.
const CSS = `
.cp-scrim { position: fixed; inset: 0; z-index: 60; background: rgba(8,7,6,.45); animation: cp-fade 120ms ease-out; }
.cp {
  position: fixed; top: 0; right: 0; bottom: 0; z-index: 61;
  width: min(540px, 92vw); display: flex; flex-direction: column;
  background: var(--raised, #1b1815); border-left: 1px solid var(--line, #3a332b);
  box-shadow: -16px 0 48px rgba(0,0,0,.5);
  font-family: "IBM Plex Mono", ui-monospace, monospace; color: var(--ink, #e9e2d4);
  animation: cp-slide 160ms cubic-bezier(.2,.7,.2,1);
}
@keyframes cp-fade { from { opacity: 0; } to { opacity: 1; } }
@keyframes cp-slide { from { transform: translateX(18px); opacity: .4; } to { transform: none; opacity: 1; } }
@media (prefers-reduced-motion: reduce) { .cp, .cp-scrim { animation: none; } }

.cp-head { padding: 14px 16px 12px; border-bottom: 1px solid var(--line, #3a332b); }
.cp-title { display: flex; align-items: baseline; gap: 8px; font-size: 13px; }
.cp-mark { color: var(--gold, #e0ad4e); }
.cp-path { word-break: break-all; }
.cp-path .cp-dir { color: var(--faint, #6f675a); }
.cp-sub { display: flex; align-items: center; justify-content: space-between; margin-top: 7px; }
.cp-branch {
  font-size: 11px; color: var(--patina, #8a9a6b); border: 1px solid var(--patina, #8a9a6b);
  border-radius: 4px; padding: 1px 7px; opacity: .85;
}
.cp-x { border: 0; background: transparent; color: var(--faint, #6f675a); font-size: 20px; line-height: 1; cursor: pointer; padding: 0 2px; }
.cp-x:hover { color: var(--ink, #e9e2d4); }

.cp-body { flex: 1; overflow-y: auto; padding: 16px; display: flex; flex-direction: column; gap: 16px; }
.cp-empty { color: var(--dim, #a89e8c); font-size: 12.5px; line-height: 1.6; margin: 4px 0 0; }
.cp-turn { display: flex; flex-direction: column; gap: 5px; }
.cp-who { font-size: 10px; letter-spacing: .08em; text-transform: uppercase; color: var(--faint, #6f675a); }
.cp-turn.you .cp-who { color: var(--patina, #8a9a6b); }
.cp-turn.claude .cp-who { color: var(--gold, #e0ad4e); }
.cp-text { font-size: 13px; line-height: 1.65; white-space: pre-wrap; word-break: break-word; }
.cp-turn.you .cp-text { color: var(--dim, #cabfa8); }
.cp-turn.queued { opacity: .55; }
.cp-turn.queued .cp-who::after { content: " · waiting"; color: var(--faint, #6f675a); }
.cp-caret { display: inline-block; width: 7px; height: 14px; margin-left: 1px; vertical-align: text-bottom;
  background: var(--gold, #e0ad4e); animation: cp-blink 1s step-end infinite; }
@keyframes cp-blink { 50% { opacity: 0; } }
.cp-status { font-size: 11.5px; color: var(--faint, #6f675a); font-style: italic; display: flex; align-items: center; gap: 10px; }
.cp-stop {
  font: inherit; font-style: normal; font-size: 11px; cursor: pointer;
  color: var(--ember, #d36a36); background: transparent;
  border: 1px solid var(--ember, #d36a36); border-radius: 5px; padding: 1px 8px;
}
.cp-stop:hover { background: rgba(211,106,54,.12); }
.cp-unqueue {
  border: 0; background: transparent; color: var(--faint, #6f675a);
  font-size: 14px; line-height: 1; cursor: pointer; padding: 0 2px; margin-left: 6px;
  vertical-align: middle;
}
.cp-unqueue:hover { color: var(--ember, #d36a36); }
.cp-err { font-size: 12px; color: var(--ember, #d36a36); }

.cp-foot { display: flex; gap: 8px; padding: 12px 16px 14px; border-top: 1px solid var(--line, #3a332b); align-items: flex-end; }
.cp-input {
  flex: 1; resize: none; box-sizing: border-box; font: inherit; font-size: 12.5px; line-height: 1.5;
  background: var(--bg, #100e0c); color: var(--ink, #e9e2d4);
  border: 1px solid var(--line, #3a332b); border-radius: 7px; padding: 8px 10px; outline: none;
}
.cp-input:focus { border-color: var(--gold, #e0ad4e); }
.cp-send {
  background: var(--gold, #e0ad4e); color: #1a160f; border: 0; border-radius: 7px;
  padding: 8px 14px; font: inherit; font-weight: 600; cursor: pointer; white-space: nowrap;
}
.cp-send:disabled { opacity: .5; cursor: default; }
`;
