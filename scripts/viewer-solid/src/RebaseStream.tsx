import { createSignal, onCleanup, onMount, Show } from "solid-js";
import { withRepo } from "./provider";
import { renderMarkdown } from "./markdown";

// RebaseStream — watch the ejected forward-rebase work, live. When /sync can't rebase a branch
// in place it hands the job to a headless claude (srv/rebase); this panel tails that job's
// output over SSE so the old frozen "rebasing onto origin/main via Claude" line becomes a
// moving stream you can trust is alive. Self-contained: it owns its fetch + SSE parse (a
// trimmed twin of chatRunner.consume — no chatStore, no multi-turn), so it drops in under
// NodeActions with one mount line and tears its connection down on unmount.
//
//   <RebaseStream branch={b} onClose={() => …} />
//
// Terminal states: `done` (claude finished — re-run prep to merge), `gone` (no job: it
// expired, or the server restarted mid-rebase), `error`. "Take over" pops the same session
// out into an interactive tmux claude via the existing /chat-popout.
const HEADERS = { "Content-Type": "application/json" };

const BTN = "rs-btn cursor-pointer rounded-[6px] border border-rule bg-transparent px-[7px] py-[2px] text-[11px] leading-[1.55] text-ink-dim hover:border-patina hover:text-ink";

async function post(url: string, body: unknown) {
  await fetch(withRepo(url), { method: "POST", headers: HEADERS, body: JSON.stringify(body) }).catch(() => {});
}

export default function RebaseStream(props: {
  branch: string;
  onClose: () => void;
  // fired once when the job reaches a terminal state, so the parent motion can stop showing the
  // rebase step as running and — on a clean finish — continue merging without a manual re-click.
  // "stopped" is the user killing it (never auto-continue that); the others are the job's own end.
  onSettled?: (outcome: "done" | "gone" | "error" | "stopped") => void;
}) {
  const [text, setText] = createSignal("");
  const [status, setStatus] = createSignal<string | null>("starting");
  const [phase, setPhase] = createSignal<"streaming" | "done" | "gone" | "error">("streaming");
  const [err, setErr] = createSignal<string | null>(null);
  const [session, setSession] = createSignal<string | null>(null);
  // the user hit ■ stop — suppresses the auto-continue on the `done` the SIGKILL then emits.
  let stopped = false;
  const ctrl = new AbortController();
  let scroller: HTMLDivElement | undefined;
  // sticky-bottom: follow new output only while parked at the bottom, so scrolling up to read
  // back doesn't get yanked down on the next token.
  let stick = true;
  const onScroll = () => {
    if (!scroller) return;
    stick = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 40;
  };
  const follow = () => {
    if (stick && scroller) scroller.scrollTop = scroller.scrollHeight;
  };

  async function consume() {
    let res: Response;
    try {
      res = await fetch(withRepo("/rebase-stream"), {
        method: "POST",
        headers: HEADERS,
        signal: ctrl.signal,
        body: JSON.stringify({ branch: props.branch }),
      });
    } catch (e) {
      if (!ctrl.signal.aborted) {
        setErr(e instanceof Error ? e.message : String(e));
        setPhase("error");
      }
      return;
    }
    if (!res.ok || !res.body) {
      setErr(`/rebase-stream → ${res.status}`);
      setPhase("error");
      return;
    }
    const reader = res.body.getReader();
    const dec = new TextDecoder();
    let buf = "";
    let finished = false;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let nl: number;
      while ((nl = buf.indexOf("\n\n")) >= 0) {
        const frame = buf.slice(0, nl);
        buf = buf.slice(nl + 2);
        let event = "message";
        let data = "";
        for (const ln of frame.split("\n")) {
          if (ln.startsWith("event:")) event = ln.slice(6).trim();
          else if (ln.startsWith("data:")) data += ln.slice(5).trim();
        }
        if (!data) continue; // keepalive ping
        const payload = JSON.parse(data);
        if (event === "session") {
          if (payload.session_id) setSession(payload.session_id);
        } else if (event === "token") {
          setStatus(null);
          setText((t) => t + (payload.t || ""));
          follow();
        } else if (event === "status") {
          setStatus(payload.s);
        } else if (event === "done") {
          if (payload.session_id) setSession(payload.session_id);
          setPhase("done");
          finished = true;
          if (!stopped) props.onSettled?.("done");
        } else if (event === "gone") {
          setPhase("gone");
          finished = true;
          props.onSettled?.("gone");
        } else if (event === "error") {
          setErr(payload.err || "stream error");
          setPhase("error");
          finished = true;
          props.onSettled?.("error");
        }
      }
      if (finished) {
        await reader.cancel().catch(() => {});
        break;
      }
    }
  }

  onMount(() => void consume());
  onCleanup(() => ctrl.abort());

  const streaming = () => phase() === "streaming";
  const takeOver = () => {
    const s = session();
    if (s) void post("/chat-popout", { session: s, branch: props.branch });
  };
  const stop = () => {
    stopped = true;
    void post("/rebase-stop", { branch: props.branch });
    setPhase("done");
    props.onSettled?.("stopped");
  };

  return (
    <div class="rebase-stream absolute top-[calc(100%+8px)] right-0 z-[25] flex w-[min(560px,78vw)] flex-col gap-2 rounded-[9px] border border-rule bg-vellum-raise px-3 py-2.5 text-left shadow-[0_12px_34px_-14px_rgba(0,0,0,0.75)]">
      <div class="rs-head flex items-baseline justify-between gap-3">
        <span class="rs-title text-[12px]" classList={{ "rs-live text-ember": streaming(), "text-patina": !streaming() }}>
          <Show when={streaming()} fallback={phase() === "done" ? "✓" : phase() === "gone" ? "◌" : "✗"}>
            <span class="rs-spin inline-block animate-rs-spin motion-reduce:animate-none">⟳</span>
          </Show>{" "}
          {streaming()
            ? `rebasing ${props.branch} onto origin/main${status() ? ` — ${status()}` : "…"}`
            : phase() === "done"
              ? "rebase session finished — re-run prep to merge"
              : phase() === "gone"
                ? "rebase job gone (expired or server restarted) — re-run prep to merge to check"
                : `rebase stream error: ${err() ?? "?"}`}
        </span>
        <span class="rs-btns flex flex-none gap-1.5">
          <Show when={streaming() && session()}>
            <button class={BTN} title="take over by hand — resume this rebase in an interactive tmux claude" onClick={takeOver}>
              take over
            </button>
          </Show>
          <Show when={streaming()}>
            <button class={BTN} title="kill the rebase job for real" onClick={stop}>■ stop</button>
          </Show>
          <button class={BTN} title="hide this stream (the job keeps running)" onClick={props.onClose}>✕</button>
        </span>
      </div>
      <Show when={text()}>
        <div
          class="rs-body max-h-[340px] overflow-y-auto border-t border-rule pt-2 text-[12px] leading-[1.5] text-ink-dim [&_pre]:whitespace-pre-wrap [&_pre]:[word-break:break-word]"
          ref={scroller}
          onScroll={onScroll}
          innerHTML={renderMarkdown(text())}
        />
      </Show>
    </div>
  );
}
