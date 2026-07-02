import { createSignal } from "solid-js";
import { createStore } from "solid-js/store";
import {
  thread,
  appendMsg,
  setMsgText,
  setSession,
  setActiveTurn,
  clearActiveTurn,
  markTurnEnded,
  markThreadSeen,
  threadsWithActiveTurn,
  type ChatModel,
} from "./chatStore";

// The chat streaming engine, lifted OUT of the ChatPanel component and up to module scope.
//
// Why it lives here, not in the drawer: a turn runs as a server-side job, but its *consumer* used
// to be the ChatPanel component — so closing the drawer dropped the consumer, and nothing learned
// the job had finished. activeTurn stayed set, and any "working" badge stuck on "working" forever
// (the bug). Now the engine consumes the stream from module scope: closing the drawer just hides
// the view, the run loop keeps writing tokens into the store and clears activeTurn when the job
// actually ends — so threadWorking() is finally truthful whether the drawer is open or not.
//
// One turn per thread is in flight at a time; extra messages queue (rt.queue) and pump in order.
//
// keyOf keys this module's OWN maps (rt / aborts / viewing) only — every call into chatStore goes
// by (branch, path) and re-keys there. So this separator just has to be internally consistent; it
// is never compared against a chatStore key (which joins on a NUL), so a plain space is fine here.
const keyOf = (branch: string, path: string) => `${branch} ${path}`;

interface QueuedMsg {
  q: string;
  patch?: string; // seeds turn one only; ignored once a resume session exists
  model: ChatModel;
  attachments?: { name: string; path: string }[]; // dropped/pasted images, saved server-side
  project?: string; // whole-forest chat → POST {project} instead of {branch, path}; server builds the seed
}

interface Runtime {
  streaming: boolean;
  status: string | null;
  error: string | null;
  queue: QueuedMsg[];
}

const [rt, setRt] = createStore<Record<string, Runtime>>({});
const aborts = new Map<string, AbortController>(); // one in-flight turn per thread

// Which thread's drawer is open, so a turn finishing knows whether it ended unseen.
const [viewing, setViewing] = createSignal<string | null>(null);

function ensure(k: string): Runtime {
  if (!rt[k]) {
    setRt(k, { streaming: false, status: null, error: null, queue: [] });
  }
  return rt[k];
}

// Reactive view of a thread's transient run state (streaming flag, status line, error, queue).
// Unlike the thread itself this is in-memory only — a reload rebuilds it via reconcile().
export function runtime(branch: string, path: string): Runtime {
  return ensure(keyOf(branch, path));
}

export function setViewingThread(branch: string, path: string) {
  setViewing(keyOf(branch, path));
  markThreadSeen(branch, path); // opening it clears the "done, go look" marker
}

export function clearViewingThread(branch: string, path: string) {
  if (viewing() === keyOf(branch, path)) {
    setViewing(null);
  }
}

const HEADERS = { "Content-Type": "application/json" };

// Read the SSE stream off a /chat response into the thread's claude message at `idx`. `reset`
// (re-attaching to an in-flight job, which replays from the top) rebuilds the message from
// scratch — but LAZILY, on the first token, so re-attaching to a "gone" job doesn't wipe the
// partial we already had. Returns the terminal outcome.
async function consume(
  branch: string,
  path: string,
  res: Response,
  idx: number,
  reset: boolean,
): Promise<"done" | "gone" | "error"> {
  const k = keyOf(branch, path);
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
        if (payload.session_id) {
          setSession(branch, path, payload.session_id);
        }
      } else if (event === "token") {
        setRt(k, "status", null);
        if (reset && !didReset) {
          setMsgText(branch, path, idx, () => ""); // first replayed token → rebuild from scratch
          didReset = true;
        }
        setMsgText(branch, path, idx, (t) => t + (payload.t || ""));
      } else if (event === "status") {
        setRt(k, "status", payload.s);
      } else if (event === "done") {
        if (payload.session_id) {
          setSession(branch, path, payload.session_id);
        }
        finished = true;
      } else if (event === "gone") {
        outcome = "gone"; // the job no longer exists — partial stays; --resume can continue it
        finished = true;
      } else if (event === "error") {
        setRt(k, "error", payload.err || "stream error");
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
}

// Shared teardown for a turn — runs on natural end, stop, OR connection error. Unlike the old
// component version there's no "unmounting" special case: the engine isn't tied to the drawer, so
// a finished turn ALWAYS clears activeTurn. `markTurnEnded(unseen)` flags it for the done badge
// when the thread's drawer wasn't open.
function finish(branch: string, path: string, idx: number, ctrl: AbortController) {
  const k = keyOf(branch, path);
  setRt(k, "streaming", false);
  setRt(k, "status", null);
  aborts.delete(k);
  clearActiveTurn(branch, path);
  const answered = thread(branch, path).msgs[idx]?.text;
  if (ctrl.signal.aborted) {
    if (!answered) {
      setMsgText(branch, path, idx, () => "⏹ stopped");
    }
  } else if (!answered && !rt[k]?.error) {
    setRt(k, "error", "no response — the headless claude produced nothing");
  }
  markTurnEnded(branch, path, viewing() !== k);
}

async function runTurn(branch: string, path: string, item: QueuedMsg) {
  const k = keyOf(branch, path);
  const resume = thread(branch, path).session;
  const turn = crypto.randomUUID(); // the server keys the job by this; a reload re-attaches to it
  setRt(k, "error", null);
  setRt(k, "streaming", true);
  setRt(k, "status", "starting");
  markThreadSeen(branch, path); // a fresh turn supersedes any prior "done" marker
  appendMsg(branch, path, {
    role: "you",
    text: item.q,
    attachments: item.attachments?.map((a) => ({ name: a.name })),
  });
  const idx = appendMsg(branch, path, { role: "claude", text: "" });
  setActiveTurn(branch, path, turn, idx); // persist NOW so a reload mid-answer can re-attach
  const ctrl = new AbortController();
  aborts.set(k, ctrl);
  try {
    const res = await fetch("/chat", {
      method: "POST",
      headers: HEADERS,
      signal: ctrl.signal,
      body: JSON.stringify({
        // a forest chat carries {project}; the server gathers the whole DAG. branch/path are the
        // local thread key only, so they're omitted from the payload when project is set.
        project: item.project || undefined,
        branch: item.project ? undefined : branch,
        turn,
        path: item.project ? undefined : path || undefined,
        patch: resume ? undefined : item.patch, // diff only seeds turn one
        question: item.q,
        resume: resume || undefined,
        model: item.model,
        attachments: item.attachments?.map((a) => a.path),
      }),
    });
    if (!res.ok || !res.body) {
      throw new Error(`/chat → ${res.status}`);
    }
    await consume(branch, path, res, idx, false);
  } catch (e) {
    if (!ctrl.signal.aborted) {
      setRt(k, "error", e instanceof Error ? e.message : String(e));
    }
  } finally {
    finish(branch, path, idx, ctrl);
  }
}

function pump(branch: string, path: string) {
  const k = keyOf(branch, path);
  const r = rt[k];
  if (!r || r.streaming || !r.queue.length) {
    return;
  }
  const item = r.queue[0];
  setRt(k, "queue", (q) => q.slice(1));
  void runTurn(branch, path, item).then(() => pump(branch, path)); // chain the next queued message
}

// Enqueue a message and start draining. Fire it any time — even mid-stream; it queues and
// auto-sends in order when the current turn ends.
export function send(branch: string, path: string, item: QueuedMsg) {
  const k = keyOf(branch, path);
  ensure(k);
  setRt(k, "queue", (q) => [...q, item]);
  pump(branch, path);
}

// Stop the in-flight turn: kill the server job for real, then abort our local read.
export function stop(branch: string, path: string) {
  const k = keyOf(branch, path);
  const at = thread(branch, path).activeTurn;
  if (at) {
    void fetch("/chat-stop", { method: "POST", headers: HEADERS, body: JSON.stringify({ turn: at.id }) });
  }
  aborts.get(k)?.abort();
}

export function unqueue(branch: string, path: string, i: number) {
  setRt(keyOf(branch, path), "queue", (q) => q.filter((_, j) => j !== i));
}

// Re-attach to a still-running turn (a reopened drawer after reload, or app-load reconcile):
// replay its buffer, then live-tail to the end. A body without a question tells the server
// "reconnect, don't start". No-op if we're already consuming this thread's turn.
export function ensureWatching(branch: string, path: string) {
  const k = keyOf(branch, path);
  if (aborts.has(k)) {
    return; // already streaming it (drawer was never the thing holding the connection)
  }
  const at = thread(branch, path).activeTurn;
  if (!at) {
    return;
  }
  void reattach(branch, path, at.id, at.idx);
}

async function reattach(branch: string, path: string, turn: string, idx: number) {
  const k = keyOf(branch, path);
  setRt(k, "error", null);
  setRt(k, "streaming", true);
  setRt(k, "status", "reconnecting");
  const ctrl = new AbortController();
  aborts.set(k, ctrl);
  try {
    const res = await fetch("/chat", {
      method: "POST",
      headers: HEADERS,
      signal: ctrl.signal,
      body: JSON.stringify({ branch, turn, path: path || undefined }),
    });
    if (!res.ok || !res.body) {
      throw new Error(`/chat → ${res.status}`);
    }
    await consume(branch, path, res, idx, true);
  } catch (e) {
    if (!ctrl.signal.aborted) {
      setRt(k, "error", e instanceof Error ? e.message : String(e));
    }
  } finally {
    finish(branch, path, idx, ctrl);
  }
}

// On app load, re-attach every persisted in-flight turn so its badge resolves working→done from
// the live server job (or "gone" if it expired) without waiting for the user to open the drawer.
export function reconcile() {
  for (const t of threadsWithActiveTurn()) {
    ensureWatching(t.branch, t.path);
  }
}
