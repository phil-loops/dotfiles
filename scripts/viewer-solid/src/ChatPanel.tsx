import { createEffect, on, onCleanup, onMount, createSignal, For, Show, type JSX } from "solid-js";
import { createStore, produce } from "solid-js/store";
import type { FileDiff } from "./types";
import { thread, clearThread, chatModel, setChatModel, CHAT_MODELS } from "./chatStore";
import { runtime, send, stop as runnerStop, unqueue, setViewingThread, clearViewingThread, ensureWatching } from "./chatRunner";
import { renderMarkdown } from "./markdown";

// ChatPanel — "chat about this file", with Claude's answer streaming in token-by-token.
// A right-side drawer scoped to ONE file on ONE branch: the diff is the opening context, then
// it's a normal back-and-forth, talking to a headless, read-only `claude -p`.
//
// This component is now just a VIEW: the streaming engine lives in chatRunner (module scope), so
// the turn keeps running — and the badges keep updating — even when this drawer is closed. msgs +
// session come from chatStore; the live run state (streaming/status/error/queue) from the runner.
// `file` null → chat about the whole branch (the server computes its parent…branch diff). The
// store thread is keyed by path, so branch chats live under the "" key, distinct from any file.
export default function ChatPanel(props: { file: FileDiff | null; branch: string; onClose: () => void }) {
  const path = () => props.file?.path ?? "";
  const msgs = () => thread(props.branch, path()).msgs;
  const session = () => thread(props.branch, path()).session;
  const rt = () => runtime(props.branch, path());
  const streaming = () => rt().streaming;
  const status = () => rt().status;
  const error = () => rt().error;
  const pending = () => rt().queue;
  const [input, setInput] = createSignal("");
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

  const stop = () => runnerStop(props.branch, path());

  // ── minimize: shrink to a corner pill instead of closing ──
  // Close already keeps the turn running (the engine lives in chatRunner at module scope), but it
  // drops you back to the file list with only a small badge. Minimize keeps the chat one click away
  // — a docked pill, no scrim, page fully interactive — and flips to "done ✓" when the turn settles,
  // so you can fire a question and ignore it until Claude's finished.
  const [minimized, setMinimized] = createSignal(false);
  const [finished, setFinished] = createSignal(false);
  const restore = () => {
    setMinimized(false);
    setFinished(false);
  };
  // While minimized, remember the moment the turn ends so the pill can say "done ✓".
  createEffect(on(streaming, (s, prev) => {
    if (prev && !s && minimized()) {
      setFinished(true);
    }
  }));

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

  // ── attached images: drop or paste a screenshot, we upload it to a temp file claude can Read ──
  // Each carries a blob URL for the live thumbnail + the server path that rides with the message.
  type Att = { id: number; name: string; path: string; url: string; uploading: boolean };
  const [atts, setAtts] = createStore<Att[]>([]);
  const [dragOver, setDragOver] = createSignal(false);
  let attSeq = 0;

  const toB64 = (buf: ArrayBuffer): string => {
    const bytes = new Uint8Array(buf);
    let bin = "";
    for (let i = 0; i < bytes.length; i += 0x8000) {
      bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    }
    return btoa(bin);
  };
  const dropAtt = (id: number) => {
    const it = atts.find((a) => a.id === id);
    if (it) {
      URL.revokeObjectURL(it.url);
    }
    setAtts(produce((list) => {
      const i = list.findIndex((a) => a.id === id);
      if (i >= 0) {
        list.splice(i, 1);
      }
    }));
  };
  const addImage = async (file: File) => {
    const id = ++attSeq;
    const name = file.name || "pasted.png";
    setAtts(produce((list) => {
      list.push({ id, name, path: "", url: URL.createObjectURL(file), uploading: true });
    }));
    try {
      const r = await fetch("/chat-attach", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name, dataB64: toB64(await file.arrayBuffer()) }),
      }).then((res) => res.json());
      if (r.ok && r.path) {
        setAtts(produce((list) => {
          const it = list.find((a) => a.id === id);
          if (it) {
            it.path = r.path;
            it.uploading = false;
          }
        }));
      } else {
        dropAtt(id);
      }
    } catch {
      dropAtt(id);
    }
  };
  const takeImages = (files: FileList | null | undefined): boolean => {
    let took = false;
    for (const f of files ?? []) {
      if (f.type.startsWith("image/")) {
        void addImage(f);
        took = true;
      }
    }
    return took;
  };

  // Fire a message any time — even while Claude is still answering: the runner queues it and
  // auto-sends in order when the current turn ends. A just-sent message should yank the view down.
  const submit = () => {
    const q = input().trim();
    const ready = atts.filter((a) => a.path && !a.uploading);
    if (!q && !ready.length) {
      return;
    }
    setInput("");
    atts.forEach((a) => URL.revokeObjectURL(a.url));
    setAtts([]);
    stick = true;
    send(props.branch, path(), {
      q: q || "Take a look at the attached screenshot(s).",
      patch: props.file?.patch,
      model: chatModel(),
      attachments: ready.map((a) => ({ name: a.name, path: a.path })),
    });
    pin();
    inputEl?.focus();
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
    setViewingThread(props.branch, path()); // mark open (clears the "done, go look" marker)
    ensureWatching(props.branch, path()); // reloaded mid-answer? re-attach to the server job
  });
  onCleanup(() => {
    window.removeEventListener("keydown", onKey);
    atts.forEach((a) => URL.revokeObjectURL(a.url)); // un-sent previews: free their blob URLs
    // Just stop viewing — the runner keeps the turn going at module scope, so the answer finishes
    // and the badges update even with the drawer closed. (No abort: that's what used to strand it.)
    clearViewingThread(props.branch, path());
  });

  // The streaming engine lives in the runner now and can't reach into this component to scroll, so
  // follow the growing answer here: re-pin whenever the last message's text changes (a new token).
  createEffect(on(() => msgs().at(-1)?.text, () => pin()));

  const seg = (p: string): JSX.Element => {
    const i = p.lastIndexOf("/");
    return i < 0 ? <b>{p}</b> : [<span class="cp-dir">{p.slice(0, i + 1)}</span>, <b>{p.slice(i + 1)}</b>];
  };

  return (
    <>
      <style>{CSS}</style>
      <div class="cp-scrim" classList={{ "cp-hidden": minimized() }} onClick={props.onClose} />
      <aside
        class="cp"
        classList={{ "cp-hidden": minimized(), "cp-drag": dragOver() }}
        role="dialog"
        aria-label="chat about this file"
        onDragOver={(e) => {
          if (e.dataTransfer?.types.includes("Files")) {
            e.preventDefault();
            setDragOver(true);
          }
        }}
        onDragLeave={(e) => {
          if (!e.relatedTarget || !e.currentTarget.contains(e.relatedTarget as Node)) {
            setDragOver(false);
          }
        }}
        onDrop={(e) => {
          e.preventDefault();
          setDragOver(false);
          takeImages(e.dataTransfer?.files);
        }}
      >
        <Show when={dragOver()}>
          <div class="cp-drop">⤓ drop image to attach</div>
        </Show>
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
              <button class="cp-min" title="minimize — shrink to a corner pill; the chat keeps running and tells you when it's done" onClick={() => setMinimized(true)}>▁</button>
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
                <Show when={m.attachments?.length}>
                  <div class="cp-att-row">
                    <For each={m.attachments}>
                      {(a) => <span class="cp-att-chip">🖼 {a.name}</span>}
                    </For>
                  </div>
                </Show>
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
          <For each={pending()}>
            {(p, i) => (
              <div class="cp-turn you queued">
                <span class="cp-who">queued</span>
                <div class="cp-text">
                  <span>{p.q}</span>
                  <button
                    class="cp-unqueue"
                    title="remove from queue"
                    onClick={() => unqueue(props.branch, path(), i())}
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
          <Show when={atts.length}>
            <div class="cp-att-strip">
              <For each={atts}>
                {(a) => (
                  <div class="cp-thumb" classList={{ uploading: a.uploading }}>
                    <img src={a.url} alt={a.name} />
                    <button class="cp-thumb-x" title="remove" onClick={() => dropAtt(a.id)}>×</button>
                  </div>
                )}
              </For>
            </div>
          </Show>
          <div class="cp-foot-row">
            {/* always sends — a message fired mid-stream queues and auto-sends when the turn ends */}
            <textarea
              class="cp-input"
              ref={inputEl}
              rows={2}
              placeholder={streaming() ? "Claude is responding — ⏎ to queue your next question…" : "ask about this file — drop or paste a screenshot, ⏎ to send"}
              value={input()}
              onInput={(e) => setInput(e.currentTarget.value)}
              onPaste={(e) => {
                if (takeImages(e.clipboardData?.files)) {
                  e.preventDefault();
                }
              }}
              onKeyDown={(e) => {
                if (e.key === "Enter" && !e.shiftKey) {
                  e.preventDefault();
                  submit();
                }
              }}
            />
            <button
              class="cp-send"
              disabled={!input().trim() && !atts.some((a) => a.path && !a.uploading)}
              onClick={submit}
            >
              {streaming() ? "queue ✦" : "send ✦"}
            </button>
          </div>
        </footer>
      </aside>
      <Show when={minimized()}>
        <div class="cp-pill" classList={{ working: streaming(), done: !streaming() && finished() }}>
          <button class="cp-pill-main" title="restore chat" onClick={restore}>
            <span class="cp-pill-mark">✦</span>
            <span class="cp-pill-name">{props.file ? props.file.path.split("/").pop() : "whole branch"}</span>
            <Show when={streaming() || (finished() && !streaming())}>
              <span class="cp-pill-state">{streaming() ? status() || "working…" : "done ✓"}</span>
            </Show>
          </button>
          <button class="cp-pill-x" title="close chat" onClick={props.onClose}>×</button>
        </div>
      </Show>
    </>
  );
}

// Self-contained, scoped under .cp-* — rides the viewer's gold/ember dark palette and IBM
// Plex Mono without touching index.css.
const CSS = `
.cp-scrim { position: fixed; inset: 0; z-index: 60; background: rgba(8,7,6,.45); animation: cp-fade 120ms ease-out; }
.cp-hidden { display: none !important; }
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
.cp-min { border: 0; background: transparent; color: var(--faint, #6f675a); font-size: 15px; line-height: 1; cursor: pointer; padding: 0 3px; }
.cp-min:hover { color: var(--ink, #e9e2d4); }

/* minimized → docked corner pill: no scrim, page interactive, the turn keeps streaming behind it */
.cp-pill {
  position: fixed; bottom: 18px; right: 18px; z-index: 61; display: flex; align-items: stretch;
  background: var(--raised, #1b1815); border: 1px solid var(--line, #3a332b);
  border-radius: 9px; box-shadow: 0 10px 30px rgba(0,0,0,.45);
  font-family: "IBM Plex Mono", ui-monospace, monospace;
  animation: cp-pill-in 160ms cubic-bezier(.2,.7,.2,1);
}
@keyframes cp-pill-in { from { transform: translateY(8px); opacity: .3; } to { transform: none; opacity: 1; } }
@media (prefers-reduced-motion: reduce) { .cp-pill { animation: none; } }
.cp-pill.working { border-color: var(--gold, #e0ad4e); }
.cp-pill.done { border-color: var(--patina, #8a9a6b); }
.cp-pill-main {
  display: flex; align-items: center; gap: 8px; max-width: 320px;
  font: inherit; font-size: 12px; cursor: pointer; text-align: left;
  background: transparent; border: 0; color: var(--ink, #e9e2d4);
  padding: 9px 6px 9px 12px; border-radius: 9px 0 0 9px;
}
.cp-pill-main:hover { background: var(--panel, #221e1a); }
.cp-pill-mark { color: var(--gold, #e0ad4e); flex: none; }
.cp-pill.working .cp-pill-mark { animation: cp-blink 1s step-end infinite; }
.cp-pill-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.cp-pill-state { flex: none; font-size: 10.5px; padding: 1px 7px; border-radius: 999px; white-space: nowrap; }
.cp-pill.working .cp-pill-state { color: var(--gold, #e0ad4e); background: rgba(224,173,78,.12); }
.cp-pill.done .cp-pill-state { color: var(--patina, #8a9a6b); background: rgba(138,154,107,.14); }
.cp-pill-x {
  border: 0; border-left: 1px solid var(--line, #3a332b); background: transparent;
  color: var(--faint, #6f675a); font-size: 16px; line-height: 1; cursor: pointer;
  padding: 0 11px; border-radius: 0 9px 9px 0;
}
.cp-pill-x:hover { color: var(--ink, #e9e2d4); background: var(--panel, #221e1a); }
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

.cp-foot { display: flex; flex-direction: column; gap: 8px; padding: 12px 16px 14px; border-top: 1px solid var(--line, #3a332b); }
.cp-foot-row { display: flex; gap: 8px; align-items: flex-end; }

/* drag-to-attach: a dashed overlay over the drawer while a file hovers */
.cp.cp-drag { outline: 2px dashed var(--gold, #e0ad4e); outline-offset: -8px; }
.cp-drop {
  position: absolute; inset: 0; z-index: 5; display: flex; align-items: center; justify-content: center;
  background: rgba(27,24,21,.86); color: var(--gold, #e0ad4e); font-size: 14px; letter-spacing: .03em;
  pointer-events: none;
}
/* composer thumbnails of pending attachments */
.cp-att-strip { display: flex; flex-wrap: wrap; gap: 8px; }
.cp-thumb { position: relative; width: 56px; height: 56px; border-radius: 7px; overflow: hidden; border: 1px solid var(--line, #3a332b); }
.cp-thumb img { width: 100%; height: 100%; object-fit: cover; display: block; }
.cp-thumb.uploading img { opacity: .45; }
.cp-thumb.uploading::after {
  content: "↑"; position: absolute; inset: 0; display: flex; align-items: center; justify-content: center;
  color: var(--gold, #e0ad4e); font-size: 16px; animation: cp-blink 1s step-end infinite;
}
.cp-thumb-x {
  position: absolute; top: 1px; right: 1px; width: 16px; height: 16px; line-height: 14px; padding: 0;
  border: 0; border-radius: 0 0 0 6px; cursor: pointer; font-size: 13px;
  background: rgba(8,7,6,.7); color: var(--ink, #e9e2d4);
}
.cp-thumb-x:hover { background: var(--ember, #d36a36); color: #1a160f; }
/* sent-message attachment chips */
.cp-att-row { display: flex; flex-wrap: wrap; gap: 5px; margin-top: 2px; }
.cp-att-chip {
  font-size: 10.5px; color: var(--dim, #a89e8c); background: var(--panel, #221e1a);
  border: 1px solid var(--line, #3a332b); border-radius: 5px; padding: 1px 7px;
}
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
