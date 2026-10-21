// The Tutor tab — the `tutor` skill in the browser instead of the terminal. Two things the
// terminal couldn't do: the answer box has no autosuggest ghost-typing the answer, and code
// stays pinned beside the question instead of being re-pasted every rung.
//
// The tutor's turns are markdown plus three fenced blocks (srv/tutor.py teaches them):
//   tutor-pin      {path, ref?, lines:[a,b]} → the code pane shows that file, lines lit
//   tutor-options  ["…", "…"]                → answer chips
//   tutor-ledger   {topic, unaided[], …}     → the close, edited + approved here, then saved
//
// Sessions live in localStorage (this browser only): the transcript and the claude session id
// each follow-up resumes. A reload mid-turn re-attaches to the server-side job. A terminal /tutor
// session can be picked up (`/tutor?import=<session id>` or the home list): its first answer here
// resumes a fork of it, in its own worktree.
import { createEffect, createMemo, createRoot, createResource, createSignal, For, Index, Show, onMount } from "solid-js";
import { createStore, produce } from "solid-js/store";
import { fetchJSON } from "./api";
import { renderMarkdown } from "./markdown";

type Msg = { role: "tutor" | "me"; text: string };
type Pin = { path: string; ref?: string; lines?: [number, number] };
type Ledger = {
  topic: string;
  source: string;
  unaided: string[];
  scaffolded: string[];
  handed: string[];
  misconceptions: string[];
  calibration: string[];
  retest: string[];
  retested: string[];
};
type Session = {
  id: string;
  target: string;
  created: number;
  sessionId: string;
  msgs: Msg[];
  pendingTurn?: string;
  error?: string;
  saved?: boolean;
  cwd?: string; // a picked-up terminal session's worktree — its claude session only resumes there
  forkNext?: boolean; // the next turn forks the terminal session instead of resuming it in place
  importedFrom?: string;
};
type TerminalSession = { session: string; cwd: string; target: string; mtime: number; answers: number; last: string };
type ImportReply = { session: string; cwd: string; target: string; msgs: Msg[]; err?: string };
type TrackReply = { path?: string; retest: string[]; topics: string[]; err?: string };
type SrcReply = { path: string; ref: string; text: string; err?: string };

const STORE_KEY = "tutor:sessions:v1";
const BUCKETS = ["unaided", "scaffolded", "handed"] as const;
type Bucket = (typeof BUCKETS)[number];
const BUCKET_HINT: Record<Bucket, string> = {
  unaided: "produced before any scaffold narrowed the field",
  scaffolded: "got there, but the framing did part of the work",
  handed: "revealed",
};

function loadSessions(): Session[] {
  try {
    return JSON.parse(localStorage.getItem(STORE_KEY) || "[]") as Session[];
  } catch {
    return [];
  }
}

const [sessions, setSessions] = createStore<Session[]>(loadSessions());
createRoot(() => createEffect(() => {
  const snapshot = JSON.stringify(sessions);
  try {
    localStorage.setItem(STORE_KEY, snapshot);
  } catch {
    /* private window / quota — sessions just won't survive a reload */
  }
}));
const [activeId, setActiveId] = createSignal<string | null>(null);
const [status, setStatus] = createSignal<string | null>(null);
const [streaming, setStreaming] = createSignal(false);

const indexOf = (id: string) => sessions.findIndex((s) => s.id === id);

// ── parsing a tutor turn into prose + UI blocks ──────────────────────

type Seg =
  | { kind: "prose"; text: string }
  | { kind: "pin"; pin: Pin }
  | { kind: "options"; options: string[] }
  | { kind: "ledger"; ledger: Ledger };

const FENCE = /```tutor-(pin|options|ledger)[ \t]*\r?\n([\s\S]*?)```/g;

function emptyLedger(): Ledger {
  return { topic: "", source: "", unaided: [], scaffolded: [], handed: [], misconceptions: [], calibration: [], retest: [], retested: [] };
}

function asList(v: unknown): string[] {
  return Array.isArray(v) ? v.map((x) => String(x)).filter((x) => x.trim()) : [];
}

function segments(text: string): Seg[] {
  // A fence still streaming in has no closing ``` yet — hold it back rather than flash raw JSON.
  const open = text.lastIndexOf("```tutor-");
  if (open >= 0 && !text.slice(open + 9).includes("```")) {
    text = text.slice(0, open);
  }
  const out: Seg[] = [];
  let last = 0;
  for (const m of text.matchAll(FENCE)) {
    if (m.index! > last) {
      out.push({ kind: "prose", text: text.slice(last, m.index) });
    }
    last = m.index! + m[0].length;
    let data: unknown;
    try {
      data = JSON.parse(m[2]);
    } catch {
      out.push({ kind: "prose", text: m[0] });
      continue;
    }
    if (m[1] === "pin" && data && typeof data === "object" && "path" in data) {
      const p = data as { path: string; ref?: string; lines?: number[] };
      const lines = Array.isArray(p.lines) && p.lines.length >= 1
        ? ([p.lines[0], p.lines[1] ?? p.lines[0]] as [number, number]) : undefined;
      out.push({ kind: "pin", pin: { path: String(p.path), ref: p.ref ? String(p.ref) : undefined, lines } });
    } else if (m[1] === "options") {
      out.push({ kind: "options", options: asList(data) });
    } else if (m[1] === "ledger" && data && typeof data === "object") {
      const d = data as Record<string, unknown>;
      out.push({
        kind: "ledger",
        ledger: {
          topic: String(d.topic ?? ""), source: String(d.source ?? ""),
          unaided: asList(d.unaided), scaffolded: asList(d.scaffolded), handed: asList(d.handed),
          misconceptions: asList(d.misconceptions), calibration: asList(d.calibration),
          retest: asList(d.retest), retested: asList(d.retested),
        },
      });
    }
  }
  if (last < text.length) {
    out.push({ kind: "prose", text: text.slice(last) });
  }
  return out;
}

// The one line a folded rung shows: the question it asked (its last "?" sentence), else its opening.
function askOf(text: string): string {
  const prose = segments(text)
    .filter((x) => x.kind === "prose")
    .map((x) => (x as { text: string }).text)
    .join(" ")
    .replace(/```[\s\S]*?```/g, " ")
    .replace(/[*_`#>|]/g, "")
    .replace(/\s+/g, " ")
    .trim();
  const asks = prose.match(/[^.?!]*\?/g);
  const line = (asks ? asks[asks.length - 1] : prose).trim();
  return line.length > 160 ? line.slice(0, 157) + "…" : line || "(no text)";
}

function latestPin(msgs: Msg[]): Pin | null {
  for (let i = msgs.length - 1; i >= 0; i--) {
    if (msgs[i].role !== "tutor") continue;
    const pins = segments(msgs[i].text).filter((s) => s.kind === "pin");
    if (pins.length) return (pins[pins.length - 1] as { pin: Pin }).pin;
  }
  return null;
}

// ── the stream ────────────────────────────────────────────────────────

async function runTurn(id: string, body: Record<string, string>, reattach = false) {
  const turn = body.turn;
  const at = () => indexOf(id);
  setSessions(at(), "pendingTurn", turn);
  setSessions(at(), "error", undefined);
  setStreaming(true);
  setStatus("thinking");
  const cwd = sessions[at()].cwd;
  if (cwd) body = { ...body, cwd };
  if (sessions[at()].forkNext && body.resume) {
    body = { ...body, fork: "1" };
  }
  let tutorIdx = sessions[at()].msgs.length - 1;
  let reset = reattach;
  try {
    const res = await fetch("/tutor", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
    if (!res.ok || !res.body) throw new Error(`/tutor → ${res.status}`);
    const reader = res.body.getReader();
    const dec = new TextDecoder();
    let buf = "";
    let finished = false;
    while (!finished) {
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
        if (!data) continue;
        const p = JSON.parse(data);
        // the server holds the connection open after the last frame — the terminal event ends the read
        if (event === "done" || event === "error" || event === "gone") finished = true;
        if (event === "session" && p.session_id) {
          setSessions(at(), "sessionId", p.session_id);
          if (p.session_id !== sessions[at()].importedFrom) setSessions(at(), "forkNext", false);
        } else if (event === "token") {
          if (reset) {
            setSessions(at(), "msgs", tutorIdx, "text", "");
            reset = false;
          }
          setStatus(null);
          setSessions(at(), "msgs", tutorIdx, "text", (t) => t + (p.t || ""));
        } else if (event === "tool") {
          setStatus(`reading · ${p.arg || p.name}`);
        } else if (event === "status") {
          if (p.s === "thinking") setStatus("thinking");
        } else if (event === "gone") {
          setSessions(at(), "error", "that turn was lost (server restarted) — send your answer again");
          setSessions(at(), "msgs", produce((m) => { if (m[tutorIdx]?.role === "tutor" && !m[tutorIdx].text) m.splice(tutorIdx, 1); }));
          tutorIdx = -1;
        } else if (event === "error") {
          setSessions(at(), "error", p.err || "the turn failed");
        }
      }
    }
    await reader.cancel().catch(() => {});
  } catch (e) {
    setSessions(at(), "error", String(e));
  } finally {
    setSessions(at(), "pendingTurn", undefined);
    setStreaming(false);
    setStatus(null);
  }
}

function startSession(target: string) {
  const id = crypto.randomUUID();
  setSessions(produce((s) => {
    s.unshift({ id, target, created: Date.now(), sessionId: "", msgs: [{ role: "tutor", text: "" }] });
  }));
  setActiveId(id);
  void runTurn(id, { turn: crypto.randomUUID(), target });
}

const worktreeName = (cwd: string) => cwd.split("/").pop() || cwd;

async function importTerminal(session: string): Promise<string> {
  const existing = sessions.find((s) => s.importedFrom === session && !s.saved);
  if (existing) {
    setActiveId(existing.id);
    return existing.id;
  }
  const r = await fetchJSON<ImportReply>(`/tutor-import?session=${encodeURIComponent(session)}`);
  if (r.err) throw new Error(r.err);
  const id = crypto.randomUUID();
  setSessions(produce((s) => {
    s.unshift({
      id, created: Date.now(), msgs: r.msgs, sessionId: r.session, cwd: r.cwd, forkNext: true, importedFrom: r.session,
      target: r.target || `picked up from the terminal · ${worktreeName(r.cwd)}`,
    });
  }));
  setActiveId(id);
  return id;
}

function answer(id: string, text: string) {
  const s = sessions[indexOf(id)];
  if (!s || streaming() || !text.trim()) return;
  setSessions(indexOf(id), "msgs", produce((m) => { m.push({ role: "me", text }, { role: "tutor", text: "" }); }));
  void runTurn(id, { turn: crypto.randomUUID(), answer: text, resume: s.sessionId });
}

// ── components ────────────────────────────────────────────────────────

export function Tutor() {
  const [importErr, setImportErr] = createSignal("");
  onMount(() => {
    // a reload mid-turn: re-attach to the server-side job so the reply still lands
    for (const s of sessions) {
      if (s.pendingTurn) void runTurn(s.id, { turn: s.pendingTurn }, true);
    }
    // /tutor?import=<id>[&say=<first message>] — say lets a link resume the climb, not just open it
    const params = new URLSearchParams(window.location.search);
    const wanted = params.get("import");
    const say = params.get("say");
    if (wanted) {
      history.replaceState(null, "", "/tutor");
      importTerminal(wanted)
        .then((id) => { if (say) answer(id, say); })
        .catch((e) => setImportErr(String(e)));
    }
  });
  const active = createMemo(() => sessions.find((s) => s.id === activeId()) ?? null);
  return (
    <Show when={active()} fallback={<TutorHome importErr={importErr()} />}>
      {(s) => <TutorSession session={s()} />}
    </Show>
  );
}

function TutorHome(props: { importErr: string }) {
  const [track, { refetch }] = createResource(() => fetchJSON<TrackReply>("/tutor-track"));
  const [terminal] = createResource(() => fetchJSON<TerminalSession[]>("/tutor-terminal").catch(() => []));
  const ours = () => new Set(sessions.flatMap((s) => [s.sessionId, s.importedFrom ?? ""]));
  const pickable = () => (terminal() ?? []).filter((t) => !ours().has(t.session));
  const [pickErr, setPickErr] = createSignal("");
  const [target, setTarget] = createSignal("");
  onMount(() => void refetch());
  const go = () => {
    const t = target().trim();
    if (t) startSession(t);
  };
  return (
    <div class="tutor-home mx-auto max-w-[760px] px-8 py-10 max-[640px]:px-4">
      <div class="font-mono text-[10px] tracking-[0.14em] uppercase text-ink-faint mb-2">tutor</div>
      <h1 class="font-display text-[28px] leading-tight text-ink mb-6">What do you want to dig into?</h1>
      <form class="flex gap-2 mb-10" onSubmit={(e) => { e.preventDefault(); go(); }}>
        <input
          class="flex-1 min-w-0 rounded-sm border border-rule bg-vellum-raise px-3 py-2 font-mono text-[14px] text-ink outline-none focus:border-gold-deep"
          placeholder="a PR number, a branch, a file, or a concept"
          autocomplete="off"
          value={target()}
          onInput={(e) => setTarget(e.currentTarget.value)}
        />
        <button class="rounded-sm border border-gold-deep bg-gold-wash px-4 font-display text-[15px] text-gold-leaf hover:bg-vellum-edge" type="submit">
          start
        </button>
      </form>

      <Show when={props.importErr || pickErr()}>
        <div class="mb-6 font-mono text-[12px] text-del">{props.importErr || pickErr()}</div>
      </Show>

      <Show when={pickable().length}>
        <section class="mb-10">
          <h2 class="font-display text-[17px] text-ink mb-1">Pick up from the terminal</h2>
          <p class="text-[13px] text-ink-faint mb-3 mt-0">A /tutor session running in Claude Code. It continues here as a copy; the terminal one is left alone.</p>
          <ul class="m-0 p-0 list-none">
            <For each={pickable()}>
              {(t) => (
                <li class="border-t border-rule py-3">
                  <button class="block w-full text-left group" onClick={() => importTerminal(t.session).catch((e) => setPickErr(String(e)))}>
                    <div class="flex items-baseline gap-3">
                      <span class="flex-1 min-w-0 truncate text-[14px] text-ink group-hover:text-gold-leaf">{t.target || worktreeName(t.cwd)}</span>
                      <span class="shrink-0 font-mono text-[11px] text-ink-faint">
                        {worktreeName(t.cwd)} · {t.answers} answers · {new Date(t.mtime * 1000).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}
                      </span>
                    </div>
                    <div class="mt-1 text-[13px] leading-snug text-ink-faint line-clamp-2">…{t.last}</div>
                  </button>
                </li>
              )}
            </For>
          </ul>
        </section>
      </Show>

      <section class="mb-10">
        <h2 class="font-display text-[17px] text-ink mb-1">Re-test queue</h2>
        <p class="text-[13px] text-ink-faint mb-3 mt-0">Things you got with help. A cold re-test is one bare question, no scaffold.</p>
        <Show when={track()?.err}>
          <div class="font-mono text-[12px] text-del">{track()!.err}</div>
        </Show>
        <Show when={track() && !track()!.err && track()!.retest.length === 0}>
          <div class="text-[13px] text-ink-dim">Empty — nothing waiting.</div>
        </Show>
        <ul class="m-0 p-0 list-none">
          <For each={track()?.retest ?? []}>
            {(item) => (
              <li class="flex items-baseline gap-3 border-t border-rule py-2.5">
                <span class="flex-1 text-[14px] leading-snug text-ink-dim">{item}</span>
                <button
                  class="shrink-0 font-mono text-[11px] text-ember hover:text-gold-leaf"
                  onClick={() => startSession(`re-test cold, zero scaffold — one bare question first: ${item}`)}
                >re-test me cold</button>
              </li>
            )}
          </For>
        </ul>
      </section>

      <Show when={sessions.length}>
        <section>
          <h2 class="font-display text-[17px] text-ink mb-3">Sessions</h2>
          <ul class="m-0 p-0 list-none">
            <For each={sessions}>
              {(s) => (
                <li class="group flex items-baseline gap-3 border-t border-rule py-2.5">
                  <button class="flex-1 min-w-0 truncate text-left text-[14px] text-ink-dim hover:text-ink" onClick={() => setActiveId(s.id)}>
                    {s.target}
                  </button>
                  <span class="shrink-0 font-mono text-[11px] text-ink-faint">
                    {s.saved ? "saved · " : ""}{s.msgs.filter((m) => m.role === "me").length} answers · {new Date(s.created).toLocaleDateString()}
                  </span>
                  <button
                    class="shrink-0 font-mono text-[11px] text-ink-faint opacity-0 group-hover:opacity-100 hover:text-del"
                    title="forget this session"
                    onClick={() => setSessions((all) => all.filter((x) => x.id !== s.id))}
                  >✕</button>
                </li>
              )}
            </For>
          </ul>
        </section>
      </Show>
    </div>
  );
}

function TutorSession(props: { session: Session }) {
  const s = () => props.session;
  const [draft, setDraft] = createSignal("");
  const [pin, setPin] = createSignal<Pin | null>(null);
  let scroller: HTMLDivElement | undefined;
  let box: HTMLTextAreaElement | undefined;

  const [historyOpen, setHistoryOpen] = createSignal(false);
  const [expanded, setExpanded] = createSignal<number | null>(null);

  // A rung is one tutor turn plus the answer that followed it. Only the newest is shown in full;
  // the rest fold into a one-line-per-rung ladder, so a long climb never becomes a scroll wall.
  const rungs = createMemo(() => {
    const msgs = s().msgs;
    const out: { n: number; tutorIdx: number; answer?: string }[] = [];
    msgs.forEach((m, i) => {
      if (m.role === "tutor") {
        out.push({ n: out.length + 1, tutorIdx: i, answer: msgs[i + 1]?.role === "me" ? msgs[i + 1].text : undefined });
      }
    });
    return out;
  });
  const current = () => rungs()[rungs().length - 1];
  const history = () => rungs().slice(0, -1);
  const prevAnswer = () => {
    const at = current()?.tutorIdx ?? 0;
    return s().msgs[at - 1]?.role === "me" ? s().msgs[at - 1].text : "";
  };

  createEffect(() => setPin(latestPin(s().msgs)));
  // a new rung starts reading at its TOP — never chase the bottom while it streams
  createEffect(() => {
    current()?.tutorIdx;
    queueMicrotask(() => scroller?.scrollTo({ top: 0 }));
  });

  const send = (text: string) => {
    answer(s().id, text);
    setDraft("");
    setExpanded(null);
    box?.focus();
  };

  return (
    <div class="tutor grid h-screen grid-cols-[minmax(0,1.1fr)_minmax(380px,1fr)] max-[960px]:grid-cols-[1fr] max-[960px]:h-auto">
      <CodePane pin={pin()} />
      <div class="flex min-h-0 flex-col border-l border-rule max-[960px]:border-l-0 max-[960px]:border-t">
        <header class="flex items-baseline gap-3 border-b border-rule px-5 py-3">
          <button class="font-mono text-[11px] text-ink-faint hover:text-gold-leaf" onClick={() => setActiveId(null)} title="all sessions">← tutor</button>
          <span class="flex-1 min-w-0 truncate font-display text-[15px] text-ink" title={s().target}>{s().target}</span>
          <span class="shrink-0 font-mono text-[11px] text-gold-leaf">rung {rungs().length}</span>
          <Show when={!s().saved}>
            <button
              class="shrink-0 font-mono text-[11px] text-ink-faint hover:text-ember disabled:opacity-40"
              disabled={streaming()}
              title="ask for the close — the ledger you review before it's saved"
              onClick={() => send("Let's stop here. Close out: write the tutor-ledger.")}
            >wrap up</button>
          </Show>
        </header>

        <div ref={scroller} class="flex-1 min-h-0 overflow-y-auto">
          <Show when={history().length}>
            <div class="border-b border-rule">
              <button
                class="flex w-full items-baseline gap-2 px-5 py-2 text-left font-mono text-[11px] text-ink-faint hover:text-ink"
                onClick={() => setHistoryOpen((o) => !o)}
              >
                <span>{historyOpen() ? "▾" : "▸"}</span>
                <span>{history().length} earlier {history().length === 1 ? "rung" : "rungs"}</span>
              </button>
              <Show when={historyOpen()}>
                <ol class="m-0 list-none p-0 pb-2">
                  <For each={history()}>
                    {(r) => (
                      <li>
                        <button
                          class="grid w-full grid-cols-[26px_minmax(0,1fr)] gap-x-2 px-5 py-1.5 text-left hover:bg-vellum-edge"
                          classList={{ "bg-vellum-edge": expanded() === r.tutorIdx }}
                          onClick={() => setExpanded((e) => (e === r.tutorIdx ? null : r.tutorIdx))}
                        >
                          <span class="pt-px text-right font-mono text-[11px] text-ink-faint">{r.n}</span>
                          <span class="min-w-0">
                            <span class="block truncate text-[13px] text-ink-dim">{askOf(s().msgs[r.tutorIdx].text)}</span>
                            <Show when={r.answer}>
                              <span class="block truncate text-[13px] text-ink">→ {r.answer}</span>
                            </Show>
                          </span>
                        </button>
                        <Show when={expanded() === r.tutorIdx}>
                          <div class="mx-5 mt-1 mb-3 border-l-2 border-gold-deep pl-4">
                            <TutorTurn text={s().msgs[r.tutorIdx].text} latest={false} session={s()} onPin={setPin} onPick={() => {}} />
                            <Show when={r.answer}>
                              <div class="mb-2 whitespace-pre-wrap text-[13px] text-ink-dim">you: {r.answer}</div>
                            </Show>
                          </div>
                        </Show>
                      </li>
                    )}
                  </For>
                </ol>
              </Show>
            </div>
          </Show>

          <div class="px-5 py-5">
            <Show when={prevAnswer()}>
              <div class="mb-4 border-l-2 border-rule pl-3 text-[13px] leading-snug text-ink-faint">
                <span class="font-mono text-[10px] uppercase tracking-[0.12em]">you said</span>
                <div class="mt-0.5 whitespace-pre-wrap text-ink-dim">{prevAnswer()}</div>
              </div>
            </Show>
            <Show when={current()}>
              {(c) => (
                <TutorTurn
                  text={s().msgs[c().tutorIdx].text}
                  latest={true}
                  session={s()}
                  onPin={setPin}
                  onPick={(o) => setDraft(o)}
                />
              )}
            </Show>
            <Show when={streaming() && status()}>
              <div class="font-mono text-[11px] text-ink-faint truncate">{status()}…</div>
            </Show>
            <Show when={s().error}>
              <div class="mt-2 font-mono text-[12px] text-del">{s().error}</div>
            </Show>
          </div>
        </div>

        <form
          class="border-t border-rule p-4"
          onSubmit={(e) => { e.preventDefault(); send(draft()); }}
        >
          <textarea
            ref={box}
            class="block w-full resize-none rounded-sm border border-rule bg-vellum-raise px-3 py-2 text-[14px] leading-relaxed text-ink outline-none focus:border-gold-deep"
            rows={3}
            placeholder={streaming() ? "…" : "your answer — a guess is fine"}
            autocomplete="off"
            value={draft()}
            onInput={(e) => setDraft(e.currentTarget.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
                e.preventDefault();
                send(draft());
              }
            }}
          />
          <div class="mt-1.5 flex justify-between font-mono text-[10px] text-ink-faint">
            <span>enter sends · shift+enter for a new line</span>
            <Show when={streaming()}>
              <button type="button" class="hover:text-del" onClick={() => {
                const turn = s().pendingTurn;
                if (turn) void fetch("/tutor-stop", { method: "POST", body: JSON.stringify({ turn }) });
              }}>■ stop</button>
            </Show>
          </div>
        </form>
      </div>
    </div>
  );
}

function TutorTurn(props: {
  text: string;
  latest: boolean;
  session: Session;
  onPin: (p: Pin) => void;
  onPick: (o: string) => void;
}) {
  const segs = createMemo(() => segments(props.text));
  return (
    <div class="mb-5">
      <For each={segs()}>
        {(seg) => {
          if (seg.kind === "prose") {
            return <div class="wiki-prose text-[15px] [&_a]:text-gold-leaf [&_a]:underline [&_a]:decoration-gold-deep" innerHTML={renderMarkdown(seg.text)} />;
          }
          if (seg.kind === "pin") {
            return (
              <button
                class="my-1.5 inline-flex max-w-full items-baseline gap-2 rounded-sm border border-rule px-2 py-0.5 font-mono text-[11px] text-ink-dim hover:border-gold-deep hover:text-gold-leaf"
                onClick={() => props.onPin(seg.pin)}
                title="show in the code pane"
              >
                <span class="truncate">{seg.pin.path}</span>
                <Show when={seg.pin.lines}>
                  <span class="shrink-0 text-ink-faint">L{seg.pin.lines![0]}–{seg.pin.lines![1]}</span>
                </Show>
              </button>
            );
          }
          if (seg.kind === "options") {
            return (
              <div class="my-3 flex flex-wrap gap-2">
                <For each={seg.options}>
                  {(o) => (
                    <button
                      class="rounded-sm border border-gold-deep bg-gold-wash px-3 py-1.5 text-left text-[14px] text-ink hover:bg-vellum-edge disabled:opacity-40"
                      disabled={!props.latest}
                      title="put this in the answer box — then say why"
                      onClick={() => props.onPick(o)}
                    >{o}</button>
                  )}
                </For>
              </div>
            );
          }
          return <LedgerEditor initial={seg.ledger} session={props.session} />;
        }}
      </For>
    </div>
  );
}

function CodePane(props: { pin: Pin | null }) {
  const key = () => (props.pin ? `${props.pin.ref ?? ""}:${props.pin.path}` : null);
  const [src] = createResource(key, () => {
    const p = props.pin!;
    return fetchJSON<SrcReply>(`/tutor-src?path=${encodeURIComponent(p.path)}&ref=${encodeURIComponent(p.ref ?? "")}`);
  });
  let pane: HTMLDivElement | undefined;
  const lines = createMemo(() => (src()?.text ?? "").replace(/\n$/, "").split("\n"));
  const lit = (n: number) => {
    const r = props.pin?.lines;
    return !!r && n >= r[0] && n <= r[1];
  };
  createEffect(() => {
    lines();
    const start = props.pin?.lines?.[0];
    if (!start) return;
    queueMicrotask(() => {
      const el = pane?.querySelector(`[data-ln="${start}"]`) as HTMLElement | null;
      if (el && pane) pane.scrollTo({ top: Math.max(0, el.offsetTop - 80), behavior: "smooth" });
    });
  });
  return (
    <div class="flex min-h-0 flex-col bg-diff-bg max-[960px]:max-h-[50vh]">
      <div class="flex items-baseline justify-between gap-3 border-b border-rule bg-vellum-raise px-4 py-2 font-mono text-[11px]">
        <span class="truncate text-ink-dim">{props.pin?.path ?? "no code pinned yet"}</span>
        <span class="shrink-0 text-ink-faint">
          {props.pin?.lines ? `L${props.pin.lines[0]}–${props.pin.lines[1]} · ` : ""}{src()?.ref ?? ""}
        </span>
      </div>
      <div ref={pane} class="relative flex-1 min-h-0 overflow-auto py-2">
        <Show when={src()?.err}>
          <div class="px-4 font-mono text-[12px] text-del">{src()!.err}</div>
        </Show>
        <Show when={!props.pin}>
          <div class="px-4 py-6 text-[13px] text-ink-faint">Code the tutor pins shows up here and stays put while you answer.</div>
        </Show>
        <Show when={src() && !src()!.err}>
          <pre class="m-0 font-mono text-[12.5px] leading-[1.55]">
            <For each={lines()}>
              {(ln, i) => (
                <div
                  data-ln={i() + 1}
                  class="flex"
                  classList={{ "bg-gold-wash": lit(i() + 1) }}
                >
                  <span
                    class="w-[52px] shrink-0 select-none pr-3 text-right"
                    classList={{ "text-gold-leaf": lit(i() + 1), "text-ink-faint": !lit(i() + 1) }}
                  >{i() + 1}</span>
                  <span class="whitespace-pre pr-4" classList={{ "text-diff-ink": lit(i() + 1), "text-ink-dim": !lit(i() + 1) }}>{ln || " "}</span>
                </div>
              )}
            </For>
          </pre>
        </Show>
      </div>
    </div>
  );
}

function LedgerEditor(props: { initial: Ledger; session: Session }) {
  const [l, setL] = createStore<Ledger>({ ...emptyLedger(), ...structuredClone(props.initial) });
  const [state, setState] = createSignal<"idle" | "saving" | "error">("idle");
  const [err, setErr] = createSignal("");
  const saved = () => !!props.session.saved;

  const move = (from: Bucket, i: number, dir: -1 | 1) => {
    const to = BUCKETS[BUCKETS.indexOf(from) + dir];
    if (!to) return;
    const item = l[from][i];
    setL(produce((d) => { d[from].splice(i, 1); d[to].push(item); }));
  };
  const save = async () => {
    setState("saving");
    try {
      const r = await fetch("/tutor-ledger", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(l) });
      const j = await r.json();
      if (!j.ok) throw new Error(j.err || "save failed");
      setSessions(indexOf(props.session.id), "saved", true);
      setState("idle");
    } catch (e) {
      setErr(String(e));
      setState("error");
    }
  };

  const ListField = (p: { name: keyof Ledger; label: string; hint?: string }) => (
    <div class="mb-3">
      <div class="font-mono text-[10px] tracking-[0.12em] uppercase text-ink-faint">{p.label}</div>
      <Show when={p.hint}><div class="text-[11px] text-ink-faint mb-1">{p.hint}</div></Show>
      <Index each={l[p.name] as string[]}>
        {(item, i) => (
          <div class="group flex items-start gap-1">
            <textarea
              class="flex-1 resize-none border-0 bg-transparent p-0 text-[13px] leading-snug text-ink-dim outline-none focus:text-ink [field-sizing:content]"
              rows={1}
              disabled={saved()}
              value={item()}
              onInput={(e) => setL(p.name as "retest", i, e.currentTarget.value)}
            />
            <Show when={!saved()}>
              <button class="font-mono text-[11px] text-ink-faint opacity-0 group-hover:opacity-100 hover:text-del" title="cut it"
                onClick={() => setL(produce((d) => { (d[p.name] as string[]).splice(i, 1); }))}>✕</button>
            </Show>
          </div>
        )}
      </Index>
    </div>
  );

  return (
    <div class="my-4 rounded-sm border border-gold-deep bg-vellum-raise p-4">
      <div class="mb-1 font-display text-[17px] text-ink">The close</div>
      <p class="mt-0 mb-4 text-[12px] text-ink-faint">
        Audit it. Move anything that's over-credited down a column, cut what's wrong, then save — nothing reaches your track until you do.
      </p>
      <div class="mb-4 grid grid-cols-2 gap-3 max-[640px]:grid-cols-1">
        <input class="rounded-sm border border-rule bg-vellum-night px-2 py-1 text-[13px] text-ink" placeholder="topic" disabled={saved()}
          value={l.topic} onInput={(e) => setL("topic", e.currentTarget.value)} />
        <input class="rounded-sm border border-rule bg-vellum-night px-2 py-1 text-[13px] text-ink" placeholder="source" disabled={saved()}
          value={l.source} onInput={(e) => setL("source", e.currentTarget.value)} />
      </div>
      <div class="mb-4 grid grid-cols-3 gap-3 max-[760px]:grid-cols-1">
        <For each={[...BUCKETS]}>
          {(b) => (
            <div class="min-w-0 rounded-sm border border-rule p-2.5">
              <div class="font-mono text-[10px] tracking-[0.12em] uppercase text-gold-leaf">{b}</div>
              <div class="mb-2 text-[11px] leading-snug text-ink-faint">{BUCKET_HINT[b]}</div>
              <Index each={l[b]}>
                {(item, i) => (
                  <div class="group mb-1.5 rounded-sm bg-vellum-night px-2 py-1.5">
                    <textarea
                      class="block w-full resize-none border-0 bg-transparent p-0 text-[13px] leading-snug text-ink outline-none [field-sizing:content]"
                      rows={1}
                      disabled={saved()}
                      value={item()}
                      onInput={(e) => setL(b, i, e.currentTarget.value)}
                    />
                    <Show when={!saved()}>
                      <div class="mt-1 flex gap-2 font-mono text-[11px] text-ink-faint">
                        <Show when={b !== "unaided"}>
                          <button class="hover:text-gold-leaf" title="more credit" onClick={() => move(b, i, -1)}>◀</button>
                        </Show>
                        <Show when={b !== "handed"}>
                          <button class="hover:text-ember" title="less credit" onClick={() => move(b, i, 1)}>▶</button>
                        </Show>
                        <span class="flex-1" />
                        <button class="hover:text-del" title="cut it" onClick={() => setL(produce((d) => { d[b].splice(i, 1); }))}>✕</button>
                      </div>
                    </Show>
                  </div>
                )}
              </Index>
            </div>
          )}
        </For>
      </div>
      <ListField name="misconceptions" label="misconceptions" />
      <ListField name="calibration" label="calibration for next time" />
      <ListField name="retest" label="add to the re-test queue" />
      <ListField name="retested" label="passed cold — checks off the queue" />
      <div class="flex items-center gap-3">
        <Show when={!saved()} fallback={<span class="font-mono text-[12px] text-add">saved to your track ✓</span>}>
          <button
            class="rounded-sm border border-gold-deep bg-gold-wash px-4 py-1.5 font-display text-[15px] text-gold-leaf hover:bg-vellum-edge disabled:opacity-40"
            disabled={state() === "saving"}
            onClick={() => void save()}
          >{state() === "saving" ? "saving…" : "save to my track"}</button>
        </Show>
        <Show when={state() === "error"}>
          <span class="font-mono text-[12px] text-del">{err()}</span>
        </Show>
      </div>
    </div>
  );
}
