import { createEffect, on, onCleanup, onMount, createSignal, For, Show, type JSX } from "solid-js";
import { useImageAttachments } from "./useImageAttachments";
import { usePopout } from "./usePopout";
import type { FileDiff } from "./types";
import { thread, clearThread, chatModel, setChatModel, CHAT_MODELS } from "./chatStore";
import { runtime, send, stop as runnerStop, unqueue, setViewingThread, clearViewingThread, ensureWatching } from "./chatRunner";
import { drawerMinimized as minimized, setDrawerMinimized } from "./chatDrawer";
import { renderMarkdown } from "./markdown";
import { parseSegments, runAction, actionById, chatMessageFor, editStreamFor, type ActionSpec } from "./chatActions";

// The drawer predates the ledger palette and keeps its own: `--gold` here is #e0ad4e (not the
// blessed gold-leaf), and its raised/line/panel/bg surfaces are local hexes. Only ink, patina
// and ember resolved to ledger tokens in the old CSS (defined vars beat the fallbacks), so only
// those use ledger utilities below.
const SMALL_BTN = "cursor-pointer whitespace-nowrap rounded-[5px] border bg-transparent px-2 py-[2px] text-[10.5px] leading-[1.55]";

// One action Claude offered, rendered as a button. Destructive actions (registry `confirm`) arm on
// the first click and fire on the second; the rest fire immediately. The endpoint's verdict shows
// inline, so a click never leaves the chat to learn whether it worked.
function ChatActionButton(props: { spec: ActionSpec; branch: string; path: string }) {
  const def = actionById(props.spec.action);
  const [phase, setPhase] = createSignal<"idle" | "armed" | "running" | "done" | "error">("idle");
  const [note, setNote] = createSignal("");
  const label = () => props.spec.label || def?.label || props.spec.action;

  const onClick = async () => {
    if (phase() === "running" || phase() === "done") {
      return;
    }
    if (def?.confirm && phase() === "idle") {
      setPhase("armed");
      return;
    }
    // A "/chat" action types its canned message into the drawer as a real turn — it streams
    // below with the same machinery as anything you'd type, not a one-shot HTTP verdict.
    const chatMsg = chatMessageFor(props.spec);
    if (chatMsg) {
      send(props.branch, props.path, { q: chatMsg, model: chatModel() });
      setPhase("done");
      return;
    }
    // A "/claude-stream" action hands the edit to a headless editing claude and streams its run
    // in below as a turn — the work, its activity, and the final summary stay in this chat.
    const edit = editStreamFor(props.spec, { branch: props.branch, path: props.path });
    if (edit) {
      if (!edit.selections.length || !edit.instruction) {
        setNote("this action needs a file + instruction — ask Claude to re-offer it");
        setPhase("error");
        return;
      }
      send(props.branch, props.path, {
        q: `✎ ${edit.instruction}`,
        model: chatModel(),
        edit,
      });
      setPhase("done");
      return;
    }
    setPhase("running");
    const r = await runAction(props.spec, { branch: props.branch, path: props.path });
    setNote(r.msg);
    setPhase(r.ok ? "done" : "error");
  };

  return (
    <span class="cp-actions mt-[6px] mr-[6px] mb-[2px] inline-flex flex-wrap items-center gap-[6px]">
      <button
        class={`cp-action inline-flex cursor-pointer items-center gap-[6px] rounded-[6px] border px-[11px] py-[5px] text-[12px] leading-[1.2] transition-[background,border-color] duration-[120ms] disabled:cursor-default disabled:opacity-55 ${
          phase() === "armed"
            ? "confirm border-ember bg-ember text-(--chip-del-text)"
            : phase() === "done"
              ? "ok cursor-default border-gold-deep bg-transparent text-add"
              : phase() === "error"
                ? "err border-del bg-del-bg text-del"
                : "border-gold-deep bg-ember-wash text-ink hover:border-gold-leaf hover:bg-gold-wash"
        }`}
        disabled={phase() === "running" || phase() === "done"}
        title={def?.describe}
        onClick={onClick}
      >
        <Show when={phase() === "done"} fallback={<span>{phase() === "armed" ? `confirm — ${label()}` : label()}</span>}>
          <span>✓ {label()}</span>
        </Show>
      </button>
      <Show when={phase() === "running"}>
        <span class="cp-action-spin text-[11px] text-ink-dim">running…</span>
      </Show>
      {/* a query action (whats-next) shows its answer here; "done" is the mute default for do-X actions */}
      <Show when={note() && note() !== "done" && (phase() === "done" || phase() === "error")}>
        <span class="cp-action-note ml-1 text-[11px] text-ink-faint">{note()}</span>
      </Show>
    </span>
  );
}

// ChatPanel — "chat about this file", with Claude's answer streaming in token-by-token.
// A right-side drawer scoped to ONE file on ONE branch: the diff is the opening context, then
// it's a normal back-and-forth, talking to a headless, read-only `claude -p`.
//
// This component is now just a VIEW: the streaming engine lives in chatRunner (module scope), so
// the turn keeps running — and the badges keep updating — even when this drawer is closed. msgs +
// session come from chatStore; the live run state (streaming/status/error/queue) from the runner.
// `file` null → chat about the whole branch (the server computes its parent…branch diff). The
// store thread is keyed by path, so branch chats live under the "" key, distinct from any file.
export default function ChatPanel(props: {
  file: FileDiff | null;
  branch: string; // the branch this chat is pinned to — stays put even as you navigate elsewhere
  viewingBranch: string; // the branch currently on screen; differs from `branch` once you nav away
  project?: string; // set → a whole-forest chat: branch holds the project name (thread key), file null
  onGoToBranch: () => void; // navigate back to this chat's project + branch
  onClose: () => void;
}) {
  const path = () => props.file?.path ?? "";
  const away = () => props.viewingBranch !== props.branch; // you've navigated off this chat's branch
  // Navigating off this chat's branch docks it to the corner pill: a full drawer on another
  // branch's page reads as THAT page's chat (Phil, 2026-07-05 — "same chat on two branches").
  // The ✦ presence badge + pill still advertise it; restoring while away is deliberate and sticks.
  createEffect(on(away, (a, prev) => {
    if (a && prev === false) {
      setDrawerMinimized(true);
    }
  }, { defer: true }));
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
  const [finished, setFinished] = createSignal(false);
  const restore = () => {
    setDrawerMinimized(false);
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
  const { popoutOpen, setPopoutOpen, targets, popoutMsg, togglePopout, popOut } = usePopout({ session, branch: () => props.branch });

  // ── attached images: drop or paste a screenshot, we upload it to a temp file claude can Read ──
  // Each carries a blob URL for the live thumbnail + the server path that rides with the message.
  const { atts, setAtts, dragOver, setDragOver, dropAtt, addImage, takeImages } = useImageAttachments();

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
      project: props.project,
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
    return i < 0 ? <b>{p}</b> : [<span class="cp-dir text-[#6f675a]">{p.slice(0, i + 1)}</span>, <b>{p.slice(i + 1)}</b>];
  };

  return (
    <>
      <style>{MD_CSS}</style>
      <div
        class={`cp-scrim fixed inset-0 z-[60] bg-[rgba(8,7,6,.45)] animate-cp-fade motion-reduce:animate-none ${minimized() ? "cp-hidden hidden" : ""}`}
        onClick={props.onClose}
      />
      <aside
        class={`cp fixed top-0 right-0 bottom-0 z-[61] w-[min(540px,92vw)] flex-col border-l border-[#3a332b] bg-[#1b1815] font-mono text-ink shadow-[-16px_0_48px_rgba(0,0,0,.5)] animate-cp-slide motion-reduce:animate-none ${
          minimized() ? "cp-hidden hidden" : "flex"
        } ${dragOver() ? "cp-drag outline-2 outline-dashed outline-[#e0ad4e] outline-offset-[-8px]" : ""}`}
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
          {/* drag-to-attach: a dashed overlay over the drawer while a file hovers */}
          <div class="cp-drop pointer-events-none absolute inset-0 z-[5] flex items-center justify-center bg-[rgba(27,24,21,.86)] text-[14px] tracking-[0.03em] text-[#e0ad4e]">⤓ drop image to attach</div>
        </Show>
        <header class="cp-head border-b border-[#3a332b] px-4 pt-[14px] pb-3">
          <div class="cp-title flex items-baseline gap-2 text-[13px]">
            <span class="cp-mark text-[#e0ad4e]">✦</span>
            <span class="cp-path break-all">
              {props.file
                ? seg(props.file.path)
                : <b>{props.project ? "whole forest" : away() ? `whole branch · ${props.branch.split("/").pop()}` : "whole branch"}</b>}
            </span>
          </div>
          <div class="cp-sub mt-[9px] flex items-center justify-between gap-[10px]">
            <div class="cp-models flex gap-[2px]" role="group" aria-label="chat model">
              <For each={CHAT_MODELS}>
                {(m) => (
                  <button
                    class={`cp-model cursor-pointer rounded-[5px] border bg-transparent px-2 py-[2px] text-[10.5px] leading-[1.55] tracking-[0.02em] ${
                      chatModel() === m
                        ? "on border-[#e0ad4e] bg-[rgba(224,173,78,.08)] text-[#e0ad4e]"
                        : "border-transparent text-[#6f675a] hover:text-[#a89e8c]"
                    }`}
                    title={`claude ${m} — used when a chat starts. A running thread stays on the model it began with; hit "new chat" to switch.`}
                    onClick={() => setChatModel(m)}
                  >
                    {m}
                  </button>
                )}
              </For>
            </div>
            <div class="cp-sub-right flex items-center gap-[6px]">
              <Show when={session()}>
                <div class="cp-popout-wrap relative">
                  <button
                    class={`cp-popout ${SMALL_BTN} border-[#e0ad4e] text-[#e0ad4e] hover:bg-[rgba(224,173,78,.1)] hover:opacity-100 ${
                      popoutOpen() ? "on bg-[rgba(224,173,78,.1)] opacity-100" : "opacity-85"
                    }`}
                    title="pop this chat out into an interactive Claude Code session in tmux — resumes the same thread, now able to edit/run"
                    onClick={togglePopout}
                  >
                    ⤢ pop out
                  </button>
                  <Show when={popoutOpen()}>
                    <div class="cp-popout-menu absolute top-[calc(100%+6px)] right-0 z-[62] flex w-[220px] cursor-default flex-col gap-px rounded-lg border border-[#3a332b] bg-[#1b1815] p-[5px] text-left shadow-[0_12px_32px_rgba(0,0,0,.5)]">
                      <div class="cp-popout-head px-2 pt-1 pb-[5px] text-[9.5px] uppercase tracking-[0.08em] text-[#6f675a]">open in…</div>
                      <button class={POPOUT_ITEM} onClick={() => popOut("new")}>
                        ＋ new window
                      </button>
                      <For each={targets}>
                        {(t) => (
                          <button class={POPOUT_ITEM} onClick={() => popOut(t.target)}>
                            <span class="cp-popout-target flex-none text-patina">{t.target}</span>
                            <span class="cp-popout-name overflow-hidden text-[10.5px] text-ellipsis whitespace-nowrap text-[#6f675a]">{t.name}</span>
                          </button>
                        )}
                      </For>
                      <Show when={!targets.length}>
                        <div class="cp-popout-empty px-2 pt-1 pb-[6px] text-[10.5px] italic text-[#6f675a]">no tmux windows — opens a new one</div>
                      </Show>
                    </div>
                  </Show>
                </div>
              </Show>
              <Show when={popoutMsg()}>
                <span class="cp-popout-msg whitespace-nowrap text-[10.5px] text-[#e0ad4e]">{popoutMsg()}</span>
              </Show>
              <Show when={msgs().length}>
                <button
                  class={`cp-new ${SMALL_BTN} border-patina text-patina enabled:hover:opacity-100 disabled:cursor-default disabled:opacity-40 opacity-85`}
                  title="start a fresh chat — clears this thread so the next message opens a new session (the only way to switch an existing thread to a different model)"
                  disabled={streaming()}
                  onClick={() => clearThread(props.branch, path())}
                >
                  ＋ new chat
                </button>
              </Show>
              <button
                class={`cp-branch max-w-[150px] cursor-pointer overflow-hidden rounded border text-ellipsis whitespace-nowrap px-[7px] py-px text-[11px] leading-[1.55] ${
                  away()
                    ? "away border-[#e0ad4e] bg-[rgba(224,173,78,.08)] text-[#e0ad4e] opacity-100"
                    : "border-patina bg-transparent text-patina opacity-85 hover:opacity-100"
                }`}
                title={`${away() ? "you're viewing another branch — return to " : "this chat's branch · "}${props.branch}`}
                onClick={props.onGoToBranch}
              >
                {props.branch.split("/").pop()}{away() ? " ↗" : ""}
              </button>
              <button
                class="cp-min group/cpmin inline-flex h-6 min-w-7 cursor-pointer items-center justify-center rounded-[5px] border-0 bg-transparent px-[6px] py-0 hover:bg-[rgba(224,173,78,.1)]"
                title="minimize — shrink to a corner pill; the chat keeps running and tells you when it's done"
                onClick={() => setDrawerMinimized(true)}
              >
                <span class="cp-min-bar block h-[2px] w-3 rounded-[2px] bg-[#6f675a] group-hover/cpmin:bg-ink" />
              </button>
              <button class="cp-x cursor-pointer border-0 bg-transparent px-[2px] py-0 text-[20px] leading-none text-[#6f675a] hover:text-ink" title="close (esc)" onClick={props.onClose}>×</button>
            </div>
          </div>
        </header>

        <div class="cp-body flex flex-1 flex-col gap-4 overflow-y-auto p-4" ref={scroller} onScroll={onScroll}>
          <Show when={!msgs().length}>
            <p class="cp-empty m-0 mt-1 text-[12.5px] leading-[1.6] text-[#a89e8c]">
              {props.project
                ? "Ask anything about this whole forest — what the feature does end to end, where the gaps are, what's left to build."
                : props.file
                ? "Ask anything about this diff — what it does, whether it's correct, what you'd change."
                : "Ask anything about this whole branch — what it does, whether it hangs together, what you'd change."}
              {" "}Claude reads the diff and can look at related code (read-only).
            </p>
          </Show>
          <For each={msgs()}>
            {(m, i) => (
              <div class="cp-turn flex flex-col gap-[5px]" classList={{ you: m.role === "you", claude: m.role === "claude" }}>
                <span class={`cp-who text-[10px] uppercase tracking-[0.08em] ${m.role === "you" ? "text-patina" : "text-[#e0ad4e]"}`}>{m.role}</span>
                <div class={`cp-text text-[13px] leading-[1.65] whitespace-pre-wrap [word-break:break-word] ${m.role === "you" ? "text-[#cabfa8]" : ""}`}>
                  <Show when={m.role === "claude"} fallback={m.text}>
                    <For each={parseSegments(m.text)}>
                      {(seg) => (
                        <Show
                          when={seg.kind === "action" ? seg : null}
                          fallback={
                            <Show when={seg.kind === "md" ? seg : null}>
                              {(md) => <div class="cp-md whitespace-normal" innerHTML={renderMarkdown(md().text)} />}
                            </Show>
                          }
                        >
                          {(a) => <ChatActionButton spec={a().spec} branch={props.branch} path={path()} />}
                        </Show>
                      )}
                    </For>
                  </Show>
                  <Show when={streaming() && m.role === "claude" && i() === msgs().length - 1}>
                    <span class="cp-caret ml-px inline-block h-3.5 w-[7px] bg-[#e0ad4e] align-text-bottom animate-cp-blink motion-reduce:animate-none" />
                  </Show>
                </div>
                <Show when={m.attachments?.length}>
                  <div class="cp-att-row mt-[2px] flex flex-wrap gap-[5px]">
                    <For each={m.attachments}>
                      {(a) => <span class="cp-att-chip rounded-[5px] border border-[#3a332b] bg-[#221e1a] px-[7px] py-px text-[10.5px] text-[#a89e8c]">🖼 {a.name}</span>}
                    </For>
                  </div>
                </Show>
              </div>
            )}
          </For>
          <Show when={streaming() || status()}>
            <div class="cp-status flex items-center gap-[10px] text-[11.5px] italic text-[#6f675a]">
              <span>{status() || "responding"}…</span>
              <Show when={streaming()}>
                <button class="cp-stop cursor-pointer rounded-[5px] border border-ember bg-transparent px-2 py-px text-[11px] leading-[1.55] not-italic text-ember hover:bg-[rgba(211,106,54,.12)]" title="stop responding" onClick={stop}>◼ stop</button>
              </Show>
            </div>
          </Show>
          {/* messages you sent while a turn was streaming — they auto-send in order */}
          <For each={pending()}>
            {(p, i) => (
              <div class="cp-turn you queued flex flex-col gap-[5px] opacity-55">
                <span class="cp-who text-[10px] uppercase tracking-[0.08em] text-patina after:content-['_·_waiting'] after:text-[#6f675a]">queued</span>
                <div class="cp-text text-[13px] leading-[1.65] whitespace-pre-wrap [word-break:break-word] text-[#cabfa8]">
                  <span>{p.q}</span>
                  <button
                    class="cp-unqueue ml-[6px] cursor-pointer border-0 bg-transparent px-[2px] py-0 align-middle text-[14px] leading-none text-[#6f675a] hover:text-ember"
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
            <div class="cp-err text-[12px] text-ember">{error()}</div>
          </Show>
        </div>

        <footer class="cp-foot flex flex-col gap-2 border-t border-[#3a332b] px-4 pt-3 pb-[14px]">
          <Show when={atts.length}>
            {/* composer thumbnails of pending attachments */}
            <div class="cp-att-strip flex flex-wrap gap-2">
              <For each={atts}>
                {(a) => (
                  <div
                    class={`cp-thumb relative h-14 w-14 overflow-hidden rounded-[7px] border border-[#3a332b] ${
                      a.uploading
                        ? "uploading after:absolute after:inset-0 after:flex after:items-center after:justify-center after:text-[16px] after:text-[#e0ad4e] after:content-['↑'] after:animate-cp-blink motion-reduce:after:animate-none"
                        : ""
                    }`}
                  >
                    <img class={`block h-full w-full object-cover ${a.uploading ? "opacity-45" : ""}`} src={a.url} alt={a.name} />
                    <button class="cp-thumb-x absolute top-px right-px h-4 w-4 cursor-pointer rounded-bl-[6px] border-0 bg-[rgba(8,7,6,.7)] p-0 text-[13px] leading-[14px] text-ink hover:bg-ember hover:text-[#1a160f]" title="remove" onClick={() => dropAtt(a.id)}>×</button>
                  </div>
                )}
              </For>
            </div>
          </Show>
          <div class="cp-foot-row flex items-end gap-2">
            {/* always sends — a message fired mid-stream queues and auto-sends when the turn ends */}
            <textarea
              class="cp-input box-border flex-1 resize-none rounded-[7px] border border-[#3a332b] bg-[#100e0c] px-[10px] py-2 font-mono text-[12.5px] leading-[1.5] text-ink outline-none focus:border-[#e0ad4e]"
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
              class="cp-send cursor-pointer whitespace-nowrap rounded-[7px] border-0 bg-[#e0ad4e] px-[14px] py-2 font-semibold leading-[1.55] text-[#1a160f] disabled:cursor-default disabled:opacity-50"
              disabled={!input().trim() && !atts.some((a) => a.path && !a.uploading)}
              onClick={submit}
            >
              {streaming() ? "queue ✦" : "send ✦"}
            </button>
          </div>
        </footer>
      </aside>
      <Show when={minimized()}>
        {/* minimized → docked corner pill: no scrim, page interactive, the turn keeps streaming behind it */}
        <div
          class={`cp-pill fixed right-[18px] bottom-[18px] z-[61] flex items-stretch rounded-[9px] border bg-[#1b1815] font-mono shadow-[0_10px_30px_rgba(0,0,0,.45)] animate-cp-pill-in motion-reduce:animate-none ${
            streaming() ? "working border-[#e0ad4e]" : finished() ? "done border-patina" : "border-[#3a332b]"
          }`}
        >
          <button class="cp-pill-main flex max-w-[320px] cursor-pointer items-center gap-2 rounded-l-[9px] border-0 bg-transparent py-[9px] pr-[6px] pl-3 text-left text-[12px] leading-[1.55] text-ink hover:bg-[#221e1a]" title="restore chat" onClick={restore}>
            <span class={`cp-pill-mark flex-none text-[#e0ad4e] ${streaming() ? "animate-cp-blink motion-reduce:animate-none" : ""}`}>✦</span>
            <span class="cp-pill-name overflow-hidden text-ellipsis whitespace-nowrap">{props.file ? props.file.path.split("/").pop() : props.project ? `✦ ${props.project}` : `✦ ${props.branch.split("/").pop()}`}</span>
            <span class="cp-pill-branch flex-none border-l border-[#3a332b] pl-2 text-[10px] text-[#6f675a]">{props.branch.split("/").pop()}</span>
            <Show when={streaming() || (finished() && !streaming())}>
              <span class={`cp-pill-state flex-none whitespace-nowrap rounded-full px-[7px] py-px text-[10.5px] ${streaming() ? "bg-[rgba(224,173,78,.12)] text-[#e0ad4e]" : "bg-[rgba(138,154,107,.14)] text-patina"}`}>
                {streaming() ? status() || "working…" : "done ✓"}
              </span>
            </Show>
          </button>
          <Show when={away()}>
            <button class="cp-pill-go flex-none cursor-pointer border-0 border-l border-[#3a332b] bg-transparent px-[9px] py-0 text-[13px] leading-none text-[#e0ad4e] hover:bg-[rgba(224,173,78,.12)]" title={`return to ${props.branch}`} onClick={props.onGoToBranch}>↗</button>
          </Show>
          <button class="cp-pill-x flex-none cursor-pointer rounded-r-[9px] border-0 border-l border-[#3a332b] bg-transparent px-[11px] py-0 text-[16px] leading-none text-[#6f675a] hover:bg-[#221e1a] hover:text-ink" title="close chat" onClick={props.onClose}>×</button>
        </div>
      </Show>
    </>
  );
}

const POPOUT_ITEM = "cp-popout-item flex w-full cursor-pointer items-baseline gap-2 rounded-[5px] border-0 bg-transparent px-2 py-[6px] text-left text-[11.5px] leading-[1.55] text-ink hover:bg-[#221e1a]";

// Keep-list: these style marked-rendered markdown (third-party DOM — same standing as the
// d2h re-tint). Everything else in the old inline sheet is utilities above; this block stays
// CSS so the drawer's prose styling never depends on markup we don't emit ourselves.
const MD_CSS = `
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
`;
