import { createSignal, onCleanup, onMount, For, Show, type JSX } from "solid-js";
import { createStore, produce } from "solid-js/store";
import type { FileDiff } from "./types";
import { appendMsg, setMsgText, setSession, setActiveTurn, clearActiveTurn, thread, clearThread, chatModel, setChatModel, CHAT_MODELS } from "./chatStore";
import { renderMarkdown } from "./markdown";

// ChatPanel — "chat about this file", with Claude's answer streaming in token-by-token.
// A right-side drawer scoped to ONE file on ONE branch: the diff is the opening context,
// then it's a normal back-and-forth. POSTs /chat and reads the Server-Sent-Events the
// server proxies off a headless, read-only `claude -p`. Multi-turn is client-held: we keep
// the session_id from the first `done` and send it back as `resume`, so follow-ups stay on
// the same thread without re-sending the diff.
//
// EventSource only speaks GET, and we need a JSON POST body — so we read the SSE frames off
// the fetch response stream by hand (split on the blank-line frame boundary).
//
// History (msgs) and the resume session-id live in the module-level chatStore keyed by
// branch+path, not in this component — so closing the drawer or reloading the page no longer
// wipes the conversation. `msgs`/`session` below are just reactive views onto that thread.
// `file` null → chat about the whole branch (the server computes its parent…branch diff). The
// store thread is keyed by path, so branch chats live under the "" key, distinct from any file.
export default function ChatPanel(props: { file: FileDiff | null; branch: string; onClose: () => void }) {
  const path = () => props.file?.path ?? "";
  const msgs = () => thread(props.branch, path()).msgs;
  const session = () => thread(props.branch, path()).session;
  const [pending, setPending] = createStore<string[]>([]); // queued while a turn streams
  const [input, setInput] = createSignal("");
  const [streaming, setStreaming] = createSignal(false);
  const [status, setStatus] = createSignal<string | null>(null);
  const [error, setError] = createSignal<string | null>(null);
  let scroller: HTMLDivElement | undefined;
  let inputEl: HTMLTextAreaElement | undefined;

  // Sticky-bottom auto-scroll: follow new tokens only while the user is parked at the bottom.
  // The moment they scroll up to read back, stop yanking them down; resume once they return.
  let stick = true;
  const onScroll = () => {
    if (!scroller) {
      return;
    }
    stick = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 48;
  };
  const pin = () => {
    if (stick && scroller) {
      scroller.scrollTop = scroller.scrollHeight;
    }
  };

  // The turn now runs as a server-side job, decoupled from this connection. So:
  //   • STOP must tell the server to kill it (disconnecting alone would leave it running).
  //   • closing the drawer just drops our subscriber — the job keeps going, and reopening
  //     re-attaches (see onMount/onCleanup). `unmounting` distinguishes the two: an
  //     unmount-abort keeps the activeTurn for reattach; a stop-abort ends it.
  let abort: AbortController | null = null;
  let curTurn = "";
  let unmounting = false;
  const stop = () => {
    if (curTurn) {
      void fetch("/chat-stop", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ turn: curTurn }),
      });
    }
    abort?.abort();
  };

  // ── pop out: hand this chat's headless session to an interactive claude in tmux ──
  // The thread already carries a resume session-id; `claude --resume` continues the same
  // conversation in a real terminal (now able to edit/run, not just read). Bonus: pick which
  // tmux window to drop it into — a fresh window, or split an existing one into a new pane.
  const [popoutOpen, setPopoutOpen] = createSignal(false);
  const [targets, setTargets] = createStore<{ target: string; name: string; panes: number }[]>([]);
  const [popoutMsg, setPopoutMsg] = createSignal<string | null>(null);
  const togglePopout = async () => {
    if (popoutOpen()) {
      setPopoutOpen(false);
      return;
    }
    setPopoutMsg(null);
    setPopoutOpen(true);
    try {
      const r = await fetch("/tmux-targets").then((res) => res.json());
      setTargets(Array.isArray(r) ? r : []);
    } catch {
      setTargets([]);
    }
  };
  const popOut = async (target: string) => {
    setPopoutOpen(false);
    setPopoutMsg("opening…");
    try {
      const r = await fetch("/chat-popout", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ session: session(), branch: props.branch, target }),
      }).then((res) => res.json());
      setPopoutMsg(r.ok ? "✦ opened in tmux" : r.err || "couldn’t open");
    } catch {
      setPopoutMsg("couldn’t reach the server");
    }
    setTimeout(() => setPopoutMsg(null), 4000);
  };

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

  // Read the SSE stream off a /chat response into thread msg[idx]. `reset` (used when
  // re-attaching to an in-flight job, which replays from the top) rebuilds the message from
  // scratch — but LAZILY, on the first token, so re-attaching to a "gone" job (no replay)
  // doesn't wipe the partial we already had. Returns the terminal outcome.
  const consumeStream = async (
    res: Response,
    branch: string,
    path: string,
    idx: number,
    reset: boolean,
  ): Promise<"done" | "gone" | "error"> => {
    const reader = res.body!.getReader();
    const dec = new TextDecoder();
    let buf = "";
    let outcome: "done" | "gone" | "error" = "done";
    let didReset = false;
    let finished = false;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }
      buf += dec.decode(value, { stream: true });
      let nl: number;
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
          continue; // keepalive comment / empty frame
        }
        const payload = JSON.parse(data);
        if (event === "session") {
          // persist the resume id the moment the server reports it — so even a cut-short turn
          // (server reaped, job evicted) is still continuable via --resume.
          if (payload.session_id) {
            setSession(branch, path, payload.session_id);
          }
        } else if (event === "token") {
          setStatus(null);
          if (reset && !didReset) {
            setMsgText(branch, path, idx, () => ""); // first replayed token → rebuild from scratch
            didReset = true;
          }
          setMsgText(branch, path, idx, (t) => t + (payload.t || ""));
          pin();
        } else if (event === "status") {
          setStatus(payload.s);
        } else if (event === "done") {
          if (payload.session_id) {
            setSession(branch, path, payload.session_id);
          }
          finished = true;
        } else if (event === "gone") {
          outcome = "gone"; // the job no longer exists — partial stays; --resume can continue it
          finished = true;
        } else if (event === "error") {
          setError(payload.err || "stream error");
          outcome = "error";
          finished = true;
        }
      }
      if (finished) {
        await reader.cancel().catch(() => {});
        break;
      }
    }
    return outcome;
  };

  // Shared teardown. A stop or a normal end clears the activeTurn; an UNMOUNT abort keeps it,
  // because the server job is still running and reopening should re-attach to it.
  const finishTurn = (branch: string, path: string, idx: number, ctrl: AbortController) => {
    setStreaming(false);
    setStatus(null);
    abort = null;
    curTurn = "";
    if (ctrl.signal.aborted && unmounting) {
      return; // drawer closed mid-answer — leave activeTurn set so reopening re-attaches
    }
    clearActiveTurn(branch, path);
    const answered = thread(branch, path).msgs[idx]?.text;
    if (ctrl.signal.aborted) {
      if (!answered) {
        setMsgText(branch, path, idx, () => "⏹ stopped");
      }
    } else if (!answered && !error()) {
      setError("no response — the headless claude produced nothing");
    }
    inputEl?.focus();
  };

  const runTurn = async (q: string) => {
    // Pin the thread for the whole turn: streaming writes must land on the file we started on,
    // even if the user switches files mid-stream (props would otherwise move out from under us).
    const branch = props.branch;
    const path = props.file?.path ?? "";
    const patch = props.file?.patch; // undefined for a branch chat → server computes the diff
    const resume = session();
    const turn = crypto.randomUUID(); // the server keys the job by this; a reload re-attaches to it
    setError(null);
    appendMsg(branch, path, { role: "you", text: q });
    const idx = appendMsg(branch, path, { role: "claude", text: "" });
    setActiveTurn(branch, path, turn, idx); // persist NOW so a reload mid-answer can re-attach
    curTurn = turn;
    setStreaming(true);
    setStatus("starting");
    stick = true; // a just-sent message should pull the view to the bottom
    pin();
    const ctrl = new AbortController();
    abort = ctrl;
    try {
      const res = await fetch("/chat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        signal: ctrl.signal,
        body: JSON.stringify({
          branch,
          turn,
          path: path || undefined,
          patch: resume ? undefined : patch, // diff only seeds turn one
          question: q,
          resume: resume || undefined,
          model: chatModel(),
        }),
      });
      if (!res.ok || !res.body) {
        throw new Error(`/chat → ${res.status}`);
      }
      await consumeStream(res, branch, path, idx, false);
    } catch (e) {
      if (!ctrl.signal.aborted) {
        setError(e instanceof Error ? e.message : String(e));
      }
    } finally {
      finishTurn(branch, path, idx, ctrl);
    }
  };

  // Re-attach to a still-running turn (reopened drawer / reloaded page): replay its buffer, then
  // live-tail to the end. No question — a body without one tells the server "reconnect, don't start".
  const reattach = async (branch: string, path: string, turn: string, idx: number) => {
    setError(null);
    curTurn = turn;
    setStreaming(true);
    setStatus("reconnecting");
    stick = true;
    pin();
    const ctrl = new AbortController();
    abort = ctrl;
    try {
      const res = await fetch("/chat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        signal: ctrl.signal,
        body: JSON.stringify({ branch, turn, path: path || undefined }),
      });
      if (!res.ok || !res.body) {
        throw new Error(`/chat → ${res.status}`);
      }
      await consumeStream(res, branch, path, idx, true);
    } catch (e) {
      if (!ctrl.signal.aborted) {
        setError(e instanceof Error ? e.message : String(e));
      }
    } finally {
      finishTurn(branch, path, idx, ctrl);
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
    pin(); // reopened with restored history — drop to the latest turn
    // reopened (or reloaded) while a turn was still cooking? re-attach to its server job.
    const at = thread(props.branch, path()).activeTurn;
    if (at && !streaming()) {
      void reattach(props.branch, path(), at.id, at.idx);
    }
  });
  onCleanup(() => {
    window.removeEventListener("keydown", onKey);
    // drop our subscriber, but DON'T kill the job — it keeps running server-side and reopening
    // re-attaches. `unmounting` tells finishTurn to keep the activeTurn for that reattach.
    unmounting = true;
    abort?.abort();
  });

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
            <span class="cp-path">
              {props.file ? seg(props.file.path) : <b>whole branch</b>}
            </span>
          </div>
          <div class="cp-sub">
            <div class="cp-models" role="group" aria-label="chat model">
              <For each={CHAT_MODELS}>
                {(m) => (
                  <button
                    class="cp-model"
                    classList={{ on: chatModel() === m }}
                    title={`claude ${m} — used when a chat starts. A running thread stays on the model it began with; hit "new chat" to switch.`}
                    onClick={() => setChatModel(m)}
                  >
                    {m}
                  </button>
                )}
              </For>
            </div>
            <div class="cp-sub-right">
              <Show when={session()}>
                <div class="cp-popout-wrap">
                  <button
                    class="cp-popout"
                    classList={{ on: popoutOpen() }}
                    title="pop this chat out into an interactive Claude Code session in tmux — resumes the same thread, now able to edit/run"
                    onClick={togglePopout}
                  >
                    ⤢ pop out
                  </button>
                  <Show when={popoutOpen()}>
                    <div class="cp-popout-menu">
                      <div class="cp-popout-head">open in…</div>
                      <button class="cp-popout-item" onClick={() => popOut("new")}>
                        ＋ new window
                      </button>
                      <For each={targets}>
                        {(t) => (
                          <button class="cp-popout-item" onClick={() => popOut(t.target)}>
                            <span class="cp-popout-target">{t.target}</span>
                            <span class="cp-popout-name">{t.name}</span>
                          </button>
                        )}
                      </For>
                      <Show when={!targets.length}>
                        <div class="cp-popout-empty">no tmux windows — opens a new one</div>
                      </Show>
                    </div>
                  </Show>
                </div>
              </Show>
              <Show when={popoutMsg()}>
                <span class="cp-popout-msg">{popoutMsg()}</span>
              </Show>
              <Show when={msgs().length}>
                <button
                  class="cp-new"
                  title="start a fresh chat — clears this thread so the next message opens a new session (the only way to switch an existing thread to a different model)"
                  disabled={streaming()}
                  onClick={() => clearThread(props.branch, path())}
                >
                  ＋ new chat
                </button>
              </Show>
              <span class="cp-branch">{props.branch}</span>
              <button class="cp-x" title="close (esc)" onClick={props.onClose}>×</button>
            </div>
          </div>
        </header>

        <div class="cp-body" ref={scroller} onScroll={onScroll}>
          <Show when={!msgs().length}>
            <p class="cp-empty">
              {props.file
                ? "Ask anything about this diff — what it does, whether it's correct, what you'd change."
                : "Ask anything about this whole branch — what it does, whether it hangs together, what you'd change."}
              {" "}Claude reads the diff and can look at related code (read-only).
            </p>
          </Show>
          <For each={msgs()}>
            {(m, i) => (
              <div class="cp-turn" classList={{ you: m.role === "you", claude: m.role === "claude" }}>
                <span class="cp-who">{m.role}</span>
                <div class="cp-text">
                  <Show when={m.role === "claude"} fallback={m.text}>
                    <div class="cp-md" innerHTML={renderMarkdown(m.text)} />
                  </Show>
                  <Show when={streaming() && m.role === "claude" && i() === msgs().length - 1}>
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
.cp-sub { display: flex; align-items: center; justify-content: space-between; gap: 10px; margin-top: 9px; }
.cp-sub-right { display: flex; align-items: center; gap: 6px; }
.cp-models { display: flex; gap: 2px; }
.cp-model {
  font: inherit; font-size: 10.5px; letter-spacing: .02em; cursor: pointer;
  color: var(--faint, #6f675a); background: transparent;
  border: 1px solid transparent; border-radius: 5px; padding: 2px 8px;
}
.cp-model:hover { color: var(--dim, #a89e8c); }
.cp-model.on { color: var(--gold, #e0ad4e); border-color: var(--gold, #e0ad4e); background: rgba(224,173,78,.08); }
.cp-branch {
  font-size: 11px; color: var(--patina, #8a9a6b); border: 1px solid var(--patina, #8a9a6b);
  border-radius: 4px; padding: 1px 7px; opacity: .85;
}
.cp-x { border: 0; background: transparent; color: var(--faint, #6f675a); font-size: 20px; line-height: 1; cursor: pointer; padding: 0 2px; }
.cp-x:hover { color: var(--ink, #e9e2d4); }
.cp-new {
  font: inherit; font-size: 10.5px; cursor: pointer; white-space: nowrap;
  color: var(--patina, #8a9a6b); background: transparent;
  border: 1px solid var(--patina, #8a9a6b); border-radius: 5px; padding: 2px 8px; opacity: .85;
}
.cp-new:hover:not(:disabled) { opacity: 1; }
.cp-new:disabled { opacity: .4; cursor: default; }

.cp-popout-wrap { position: relative; }
.cp-popout {
  font: inherit; font-size: 10.5px; cursor: pointer; white-space: nowrap;
  color: var(--gold, #e0ad4e); background: transparent;
  border: 1px solid var(--gold, #e0ad4e); border-radius: 5px; padding: 2px 8px; opacity: .85;
}
.cp-popout:hover, .cp-popout.on { opacity: 1; background: rgba(224,173,78,.1); }
.cp-popout-menu {
  position: absolute; top: calc(100% + 6px); right: 0; z-index: 62; width: 220px;
  padding: 5px; border-radius: 8px; border: 1px solid var(--line, #3a332b);
  background: var(--raised, #1b1815); box-shadow: 0 12px 32px rgba(0,0,0,.5);
  display: flex; flex-direction: column; gap: 1px; cursor: default; text-align: left;
}
.cp-popout-head { font-size: 9.5px; letter-spacing: .08em; text-transform: uppercase; color: var(--faint, #6f675a); padding: 4px 8px 5px; }
.cp-popout-item {
  display: flex; align-items: baseline; gap: 8px; width: 100%;
  font: inherit; font-size: 11.5px; text-align: left; cursor: pointer;
  color: var(--ink, #e9e2d4); background: transparent; border: 0; border-radius: 5px; padding: 6px 8px;
}
.cp-popout-item:hover { background: var(--panel, #221e1a); }
.cp-popout-target { color: var(--patina, #8a9a6b); flex: none; }
.cp-popout-name { color: var(--faint, #6f675a); font-size: 10.5px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.cp-popout-empty { font-size: 10.5px; color: var(--faint, #6f675a); padding: 4px 8px 6px; font-style: italic; }
.cp-popout-msg { font-size: 10.5px; color: var(--gold, #e0ad4e); white-space: nowrap; }

.cp-body { flex: 1; overflow-y: auto; padding: 16px; display: flex; flex-direction: column; gap: 16px; }
.cp-empty { color: var(--dim, #a89e8c); font-size: 12.5px; line-height: 1.6; margin: 4px 0 0; }
.cp-turn { display: flex; flex-direction: column; gap: 5px; }
.cp-who { font-size: 10px; letter-spacing: .08em; text-transform: uppercase; color: var(--faint, #6f675a); }
.cp-turn.you .cp-who { color: var(--patina, #8a9a6b); }
.cp-turn.claude .cp-who { color: var(--gold, #e0ad4e); }
.cp-text { font-size: 13px; line-height: 1.65; white-space: pre-wrap; word-break: break-word; }
.cp-turn.you .cp-text { color: var(--dim, #cabfa8); }
.cp-md { white-space: normal; }
.cp-md > :first-child { margin-top: 0; }
.cp-md > :last-child { margin-bottom: 0; }
.cp-md p { margin: 0 0 10px; }
.cp-md ul, .cp-md ol { margin: 0 0 10px; padding-left: 22px; }
.cp-md li { margin: 2px 0; }
.cp-md h1, .cp-md h2, .cp-md h3, .cp-md h4 { margin: 14px 0 8px; font-size: 13.5px; line-height: 1.3; color: var(--ink, #e9e2d4); }
.cp-md a { color: var(--gold, #e0ad4e); }
.cp-md blockquote { margin: 0 0 10px; padding-left: 12px; border-left: 2px solid var(--line, #3a332b); color: var(--dim, #a89e8c); }
.cp-md hr { border: 0; border-top: 1px solid var(--line, #3a332b); margin: 14px 0; }
.cp-md code { font-family: inherit; font-size: 12px; background: rgba(224,173,78,.12); color: var(--gold, #e0ad4e); padding: 1px 5px; border-radius: 4px; }
.cp-md .cp-pre { margin: 0 0 10px; padding: 10px 12px; background: var(--bg, #100e0c); border: 1px solid var(--line, #3a332b); border-radius: 7px; overflow-x: auto; }
.cp-md .cp-pre code { font-size: 12px; background: none; color: inherit; padding: 0; border-radius: 0; }
.cp-md table { border-collapse: collapse; margin: 0 0 10px; font-size: 12px; }
.cp-md th, .cp-md td { border: 1px solid var(--line, #3a332b); padding: 4px 8px; text-align: left; }
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
