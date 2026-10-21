// The Tutor tab — the `tutor` skill in the browser, organized around the learner's concept graph
// (scripts/learning.py) rather than a transcript.
//
//   home     what's due, the topics (paths through the graph, shaded by depth), open questions
//   session  the topic map ("you are here") · the current rung (earlier ones fold) · pinned code
//   drawer   one concept: its depth and the evidence behind it (auditable), links, questions
//
// The tutor's turns are markdown plus fenced blocks (srv/tutor.py teaches them): tutor-map,
// tutor-rung, tutor-evidence, tutor-calibration are applied to the graph server-side when a turn
// ends; tutor-pin and tutor-options are page UI. Sessions live in localStorage (this browser only);
// a terminal /tutor session can be picked up as a fork (`/tutor?import=<id>[&say=…]`).
import { createEffect, createMemo, createRoot, createResource, createSignal, For, Show, onCleanup, onMount, type JSX } from "solid-js";
import { createStore, produce } from "solid-js/store";
import { fetchJSON } from "./api";
import { useViewerLocation, type ViewerLocation } from "./router";
import hljs from "highlight.js/lib/core";
import { renderMarkdown } from "./markdown"; // also registers hljs languages on the shared core

type Msg = { role: "tutor" | "me"; text: string };
type Pin = { path: string; ref?: string; lines?: [number, number] };
type Session = {
  id: string;
  target: string;
  created: number;
  sessionId: string;
  msgs: Msg[];
  topic?: string;
  pendingTurn?: string;
  error?: string;
  saved?: boolean;
  cwd?: string; // a picked-up terminal session's worktree — its claude session only resumes there
  forkNext?: boolean; // the next turn forks the terminal session instead of resuming it in place
  primed?: string | boolean; // the instructions version this claude session has seen (resume drops --append-system-prompt)
  lastActive?: number; // the last turn sent — orders the home page's "continue" card and the session list
  importedFrom?: string;
};
type TerminalSession = { session: string; cwd: string; target: string; mtime: number; answers: number; last: string };
type ImportReply = { session: string; cwd: string; target: string; msgs: Msg[]; err?: string };
type SrcReply = { path: string; ref: string; text: string; err?: string };

type Mastery = {
  depth: number; assisted: number; level: string; evidence: number; last: string; due: boolean; reason: string; open_miss: string;
  held?: number; held_level?: string; miss_confidence?: string; contrast?: string; overconfident?: number;
};
type CodeRef = { path: string; ref?: string; lines?: number[] };
type Concept = {
  id: string; name: string; statement: string; kind: "principle" | "convention";
  builds_on: string[]; built_on_by: string[]; analogs: string[]; code: CodeRef[]; topics: string[]; mastery: Mastery;
  blocked_by?: string[]; statement_learner?: string; restated?: string;
};
type Topic = { id: string; title: string; source: string; stages: { name: string; concepts: string[] }[]; progress: { held: number; shown?: number; total: number } };
type Evidence = {
  id: string; concept: string; level: string; credit: string; outcome: "hit" | "miss"; note: string; at: string; topic: string; session: string;
  confidence?: string; rung?: string; contrast?: string; via?: string;
};
type Question = { id: string; text: string; concept: string; topic: string; asked: string; status: "open" | "answered" };
type LearnState = {
  concepts: Record<string, Concept>; topics: Record<string, Topic>; due: string[]; questions: Question[];
  evidence: Evidence[]; levels: string[]; credits: string[];
};

const STORE_KEY = "tutor:sessions:v1";
const LEVELS = ["predict", "explain", "transfer", "critique"];
const CREDITS = ["unaided", "scaffolded", "handed"];
const CONFIDENCES = ["low", "medium", "high"];
const LEVEL_HINT: Record<string, string> = {
  predict: "said what happens in a situation",
  explain: "said why",
  transfer: "handled it cold in a new setting",
  critique: "spotted it, or its absence, in real code",
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
// Where you are lives in the URL (/tutor/<session>?concept=<id>), so a refresh or a shared link lands
// there and back steps out of a drawer or a session. These mirror it; go() changes it.
const [route, setRoute] = createSignal<{ session?: string; concept?: string }>({});
let navigateRef: ((loc: ViewerLocation) => void) | null = null;
function go(next: { session?: string; concept?: string }) {
  setRoute(next);
  navigateRef?.({ kind: "tutor", ...next });
}
const activeId = () => route().session ?? null;
const setActiveId = (id: string | null) => go({ session: id ?? undefined });
const [status, setStatus] = createSignal<string | null>(null);
const [streaming, setStreaming] = createSignal(false);
const [learn, setLearn] = createSignal<LearnState | null>(null);
const [learnErr, setLearnErr] = createSignal("");
const drawer = () => route().concept ?? null;
const setDrawer = (id: string | null) => {
  if ((id ?? undefined) !== route().concept) go({ ...route(), concept: id ?? undefined });
};
const [pin, setPin] = createSignal<Pin | null>(null);

const indexOf = (id: string) => sessions.findIndex((s) => s.id === id);
const activeSession = () => sessions.find((s) => s.id === activeId()) ?? null;
const conceptOf = (id: string) => learn()?.concepts[id];
const nameOf = (id: string) => conceptOf(id)?.name ?? id.replace(/-/g, " ");

async function refreshLearn() {
  try {
    setLearn(await fetchJSON<LearnState>("/learning-state"));
    setLearnErr("");
  } catch (e) {
    setLearnErr(String(e));
  }
}

async function postJSON(path: string, body: unknown) {
  const r = await fetch(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || j.ok === false) throw new Error(j.err || `${path} → ${r.status}`);
  return j;
}

// ── parsing a tutor turn into prose + UI blocks ──────────────────────

type EvidenceBlock = { concept: string; level: string; credit: string; outcome: string; note: string; confidence: string; contrast: string; via: string };
type Seg =
  | { kind: "prose"; text: string }
  | { kind: "pin"; pin: Pin }
  | { kind: "options"; options: string[] }
  | { kind: "rung"; concept: string; level: string; rung: string; confidence: boolean; via: string; contrastOf: string }
  | { kind: "evidence"; items: EvidenceBlock[] }
  | { kind: "map"; title: string; count: number }
  | { kind: "restate"; concept: string; text: string }
  | { kind: "question"; concept: string; text: string }
  | { kind: "quiet" };

const FENCE = /```tutor-(pin|options|rung|evidence|map|calibration|restate|question|ledger)[ \t]*\r?\n([\s\S]*?)```/g;

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
    const d = (data ?? {}) as Record<string, unknown>;
    if (m[1] === "pin" && typeof d.path === "string") {
      const lines = Array.isArray(d.lines) && d.lines.length >= 1
        ? ([Number(d.lines[0]), Number(d.lines[1] ?? d.lines[0])] as [number, number]) : undefined;
      out.push({ kind: "pin", pin: { path: d.path, ref: d.ref ? String(d.ref) : undefined, lines } });
    } else if (m[1] === "options") {
      out.push({ kind: "options", options: asList(data) });
    } else if (m[1] === "rung" && d.concept) {
      out.push({
        kind: "rung", concept: String(d.concept), level: String(d.level ?? ""), rung: String(d.rung ?? ""),
        confidence: d.confidence === true, via: String(d.via ?? ""), contrastOf: String(d.contrast_of ?? ""),
      });
    } else if (m[1] === "evidence") {
      const items = (Array.isArray(data) ? data : [data]).map((e) => {
        const x = (e ?? {}) as Record<string, unknown>;
        return {
          concept: String(x.concept ?? ""), level: String(x.level ?? ""), credit: String(x.credit ?? "unaided"), outcome: String(x.outcome ?? "hit"),
          note: String(x.note ?? ""), confidence: String(x.confidence ?? ""), contrast: String(x.contrast ?? ""), via: String(x.via ?? ""),
        };
      }).filter((e) => e.concept);
      out.push({ kind: "evidence", items });
    } else if (m[1] === "map") {
      const t = (d.topic ?? {}) as Record<string, unknown>;
      const stages = Array.isArray(d.stages) ? (d.stages as { concepts?: unknown[] }[]) : [];
      out.push({ kind: "map", title: String(t.title ?? t.id ?? "topic"), count: stages.reduce((n, s) => n + (s.concepts?.length ?? 0), 0) });
    } else if (m[1] === "restate" || m[1] === "question") {
      for (const x of Array.isArray(data) ? data : [data]) {
        const r = (typeof x === "string" ? { text: x } : x ?? {}) as Record<string, unknown>;
        if (r.text) out.push({ kind: m[1], concept: String(r.concept ?? ""), text: String(r.text) });
      }
    } else {
      out.push({ kind: "quiet" }); // calibration, and the retired ledger in old sessions
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

// The whole paragraph holding a turn's last question — the card shows the question as asked.
function questionOf(text: string): string {
  const paras = segments(text)
    .filter((x) => x.kind === "prose")
    .flatMap((x) => (x as { text: string }).text.split(/\n\s*\n/))
    .map((p) => p.replace(/[*_`#>|]/g, "").replace(/\s+/g, " ").trim())
    .filter(Boolean);
  const q = [...paras].reverse().find((p) => p.includes("?")) ?? paras[paras.length - 1] ?? "";
  return q.length > 420 ? q.slice(0, 417) + "…" : q;
}

function latest<K extends Seg["kind"]>(msgs: Msg[], kind: K): Extract<Seg, { kind: K }> | null {
  for (let i = msgs.length - 1; i >= 0; i--) {
    if (msgs[i].role !== "tutor") continue;
    const hits = segments(msgs[i].text).filter((s) => s.kind === kind);
    if (hits.length) return hits[hits.length - 1] as Extract<Seg, { kind: K }>;
  }
  return null;
}

// ── the stream ────────────────────────────────────────────────────────

async function runTurn(id: string, body: Record<string, string>, reattach = false) {
  const at = () => indexOf(id);
  setSessions(at(), "pendingTurn", body.turn);
  setSessions(at(), "lastActive", Date.now());
  setSessions(at(), "error", undefined);
  setStreaming(true);
  setStatus("thinking");
  const s = sessions[at()];
  body = { ...body, tab: id };
  if (s.topic) body.topic = s.topic;
  if (s.cwd) body.cwd = s.cwd;
  if (s.forkNext && body.resume) body.fork = "1";
  if (typeof s.primed === "string") body.primed = s.primed;
  let tutorIdx = s.msgs.length - 1;
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
        } else if (event === "graph") {
          if (p.topic) setSessions(at(), "topic", p.topic);
          if (p.protocol) setSessions(at(), "primed", p.protocol);
          if (p.errors?.length) setSessions(at(), "error", "graph: " + p.errors.join("; "));
          void refreshLearn();
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

function startSession(target: string, topic?: string) {
  const id = crypto.randomUUID();
  setSessions(produce((s) => {
    s.unshift({ id, target, topic, created: Date.now(), sessionId: "", msgs: [{ role: "tutor", text: "" }] });
  }));
  setActiveId(id);
  setDrawer(null);
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

// A learner question: recorded open in the graph, then sent into the live session (or a new one).
async function ask(text: string, concept?: Concept) {
  const t = text.trim();
  if (!t) return;
  await postJSON("/learning-question", { op: "add", text: t, concept: concept?.id ?? "", topic: concept?.topics[0] ?? activeSession()?.topic ?? "" });
  void refreshLearn();
  const msg = concept ? `Question about ${concept.name} [${concept.id}]: ${t}` : t;
  const s = activeSession();
  if (s && !streaming()) {
    setDrawer(null);
    answer(s.id, msg);
  } else {
    startSession(msg, concept?.topics[0]);
  }
}

// ── small parts ───────────────────────────────────────────────────────

function pipsTitle(m: Mastery): string {
  const parts = [];
  if (m.held) parts.push(`held at ${m.held_level} (two days)`);
  if (m.depth && (m.held ?? 0) < m.depth) parts.push(`shown once at ${m.level}`);
  if (!m.depth) parts.push("not yet shown unaided");
  if (m.assisted > m.depth) parts.push(`${LEVELS[m.assisted - 1]} with help`);
  if (m.open_miss) parts.push(`open miss${m.miss_confidence === "high" ? " (confident)" : ""}`);
  if (m.due) parts.push(`due: ${m.reason}`);
  return parts.join(" · ");
}

function Pips(props: { m?: Mastery; size?: "sm" | "md" }) {
  const box = () => (props.size === "md" ? "h-[9px] w-[9px]" : "h-[7px] w-[7px]");
  return (
    <span
      class="inline-flex shrink-0 items-center gap-[2px]"
      title={props.m ? pipsTitle(props.m) : ""}
    >
      <For each={LEVELS}>
        {(_, i) => (
          <span
            class={`${box()} rounded-[1px] border`}
            classList={{
              "border-gold-leaf bg-gold-leaf": (props.m?.held ?? 0) > i(),
              "border-gold-leaf bg-gold-leaf/25": (props.m?.held ?? 0) <= i() && (props.m?.depth ?? 0) > i(),
              "border-gold-deep bg-transparent": (props.m?.depth ?? 0) <= i() && (props.m?.assisted ?? 0) > i(),
              "border-rule bg-transparent": (props.m?.assisted ?? 0) <= i(),
            }}
          />
        )}
      </For>
      <Show when={props.m?.open_miss}>
        <span class="ml-[3px] h-[5px] w-[5px] rounded-full bg-del" classList={{ "ring-2 ring-del/40": props.m?.miss_confidence === "high" }} />
      </Show>
    </span>
  );
}

function ConceptChip(props: { id: string; here?: boolean; wrap?: boolean }) {
  const c = () => conceptOf(props.id);
  return (
    <button
      class="inline-flex max-w-full items-center gap-1.5 rounded-sm border px-2 py-1 text-left text-[12.5px] leading-tight hover:border-gold-deep"
      classList={{
        "border-gold-leaf bg-gold-wash text-ink": !!props.here,
        "border-rule text-ink-dim hover:text-ink": !props.here,
      }}
      title={c()?.statement}
      onClick={() => setDrawer(props.id)}
    >
      <Pips m={c()?.mastery} />
      <span classList={{ truncate: !props.wrap }}>{nameOf(props.id)}</span>
      <Show when={c()?.blocked_by?.length}>
        <span class="shrink-0 text-[11px] text-ink-faint" title={`needs first (never shown unaided): ${(c()?.blocked_by ?? []).map(nameOf).join(", ")}`}>⊘</span>
      </Show>
    </button>
  );
}

const SECTION = "font-mono text-[10px] uppercase tracking-[0.14em] text-ink-faint";

// ── components ────────────────────────────────────────────────────────

export function Tutor() {
  const [importErr, setImportErr] = createSignal("");
  const { location, navigate } = useViewerLocation();
  navigateRef = navigate;
  createEffect(() => {
    const l = location();
    if (l.kind === "tutor") setRoute({ session: l.session, concept: l.concept });
  });
  onMount(() => {
    void refreshLearn();
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
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") setDrawer(null); };
    window.addEventListener("keydown", onKey);
    onCleanup(() => window.removeEventListener("keydown", onKey));
  });
  return (
    <>
      <Show when={activeSession()} fallback={<TutorHome importErr={importErr()} />}>
        {(s) => <TutorSession session={s()} />}
      </Show>
      <Show when={drawer()}>
        {(id) => <ConceptDrawer id={id()} />}
      </Show>
    </>
  );
}

const touched = (s: Session) => s.lastActive ?? s.created;
const sessionTitle = (s: Session) => (s.topic && learn()?.topics[s.topic]?.title) || s.target;
const rungCount = (s: Session) => s.msgs.filter((m) => m.role === "tutor").length;

function ago(ms: number): string {
  const m = Math.round((Date.now() - ms) / 60_000);
  if (m < 1) return "just now";
  if (m < 60) return `${m} min ago`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h} h ago`;
  return new Date(ms).toLocaleDateString();
}

// The session you were last in, front and center: where in the climb, and the question waiting.
function ContinueCard(props: { s: Session }) {
  const question = () => {
    const last = [...props.s.msgs].reverse().find((m) => m.role === "tutor" && m.text.trim());
    return last ? questionOf(last.text) : "";
  };
  const here = () => latest(props.s.msgs, "rung")?.concept ?? null;
  const waiting = () => props.s.msgs[props.s.msgs.length - 1]?.role === "tutor";
  return (
    <section class="mb-10 rounded-sm border border-gold-deep bg-gold-wash p-5">
      <div class={`${SECTION} mb-2`}>continue where you left off</div>
      <div class="mb-1 flex items-baseline gap-3">
        <h2 class="m-0 min-w-0 flex-1 truncate font-display text-[20px] text-ink">{sessionTitle(props.s)}</h2>
        <span class="shrink-0 font-mono text-[11px] text-ink-faint">rung {rungCount(props.s)} · {ago(touched(props.s))}</span>
      </div>
      <Show when={here()}>
        {(id) => <div class="mb-3"><ConceptChip id={id()} here /></div>}
      </Show>
      <Show when={question()}>
        <p class="mt-0 mb-4 text-[15px] leading-relaxed text-ink-dim">
          <span class="font-mono text-[10px] uppercase tracking-[0.12em] text-ink-faint">{waiting() ? "waiting on you · " : "last question · "}</span>
          {question()}
        </p>
      </Show>
      <button
        class="rounded-sm border border-gold-deep bg-vellum-night px-4 py-1.5 font-display text-[15px] text-gold-leaf hover:bg-vellum-edge"
        onClick={() => setActiveId(props.s.id)}
      >continue</button>
    </section>
  );
}

function TutorHome(props: { importErr: string }) {
  const recent = createMemo(() => [...sessions].sort((a, b) => touched(b) - touched(a)));
  const [terminal] = createResource(() => fetchJSON<TerminalSession[]>("/tutor-terminal").catch(() => []));
  const ours = () => new Set(sessions.flatMap((s) => [s.sessionId, s.importedFrom ?? ""]));
  const pickable = () => (terminal() ?? []).filter((t) => !ours().has(t.session));
  const [pickErr, setPickErr] = createSignal("");
  const [target, setTarget] = createSignal("");
  const [allDue, setAllDue] = createSignal(false);
  const topics = createMemo(() => Object.values(learn()?.topics ?? {}).sort((a, b) => (b as { updated?: string }).updated?.localeCompare((a as { updated?: string }).updated ?? "") ?? 0));
  const due = () => learn()?.due ?? [];
  const openQs = () => (learn()?.questions ?? []).filter((q) => q.status === "open");

  return (
    <div class="tutor-home mx-auto grid max-w-[1180px] grid-cols-[minmax(0,1fr)_340px] gap-x-12 px-8 py-10 max-[1060px]:grid-cols-[1fr] max-[640px]:px-4">
      <div class="min-w-0">
        <Show when={recent()[0]}>{(s) => <ContinueCard s={s()} />}</Show>
        <div class={`${SECTION} mb-2`}>tutor</div>
        <h1 class="font-display text-[28px] leading-tight text-ink mb-6">What do you want to dig into?</h1>
        <form class="flex gap-2 mb-10" onSubmit={(e) => { e.preventDefault(); if (target().trim()) startSession(target().trim()); }}>
          <input
            class="flex-1 min-w-0 rounded-sm border border-rule bg-vellum-raise px-3 py-2 font-mono text-[14px] text-ink outline-none focus:border-gold-deep"
            placeholder="a PR number, a branch, a file, or a concept"
            autocomplete="off"
            value={target()}
            onInput={(e) => setTarget(e.currentTarget.value)}
          />
          <button class="rounded-sm border border-gold-deep bg-gold-wash px-4 font-display text-[15px] text-gold-leaf hover:bg-vellum-edge" type="submit">start</button>
        </form>
        <Show when={props.importErr || pickErr() || learnErr()}>
          <div class="mb-6 font-mono text-[12px] text-del">{props.importErr || pickErr() || learnErr()}</div>
        </Show>

        <section class="mb-10">
          <div class="flex items-baseline gap-3 mb-1">
            <h2 class="font-display text-[19px] text-ink m-0">Due</h2>
            <span class="font-mono text-[11px] text-ink-faint">{due().length} concepts</span>
          </div>
          <p class="text-[13px] text-ink-faint mt-0 mb-3">Open misconceptions first, then things you've only shown with help, then whatever's gone longest unchecked.</p>
          <ul class="m-0 p-0 list-none">
            <For each={allDue() ? due() : due().slice(0, 8)}>
              {(id) => (
                <li class="flex items-center gap-3 border-t border-rule py-2">
                  <Pips m={conceptOf(id)?.mastery} />
                  <button class="min-w-0 flex-1 text-left" onClick={() => setDrawer(id)}>
                    <span class="block truncate text-[14px] text-ink hover:text-gold-leaf">{nameOf(id)}</span>
                    <span class="block truncate text-[12px] text-ink-faint">
                      <Show when={conceptOf(id)?.mastery.miss_confidence === "high"}><span class="mr-1.5 text-del">confident miss ·</span></Show>
                      {conceptOf(id)?.mastery.reason}
                    </span>
                  </button>
                  <button
                    class="shrink-0 font-mono text-[11px] text-ember hover:text-gold-leaf"
                    onClick={() => startSession(`Re-test me cold on ${nameOf(id)} [${id}]`, conceptOf(id)?.topics[0])}
                  >re-test cold</button>
                </li>
              )}
            </For>
          </ul>
          <Show when={due().length > 8}>
            <button class="mt-2 font-mono text-[11px] text-ink-faint hover:text-ink" onClick={() => setAllDue((v) => !v)}>
              {allDue() ? "show fewer" : `show all ${due().length}`}
            </button>
          </Show>
        </section>

        <section>
          <h2 class="font-display text-[19px] text-ink mb-1">Topics</h2>
          <p class="text-[13px] text-ink-faint mt-0 mb-4">Paths through one graph. The same idea met in two topics is one concept, linked as an analog.</p>
          <For each={topics()}>
            {(t) => (
              <article class="mb-5 rounded-sm border border-rule p-4">
                <header class="mb-3 flex items-baseline gap-3">
                  <h3 class="m-0 flex-1 min-w-0 truncate font-display text-[16px] text-ink">{t.title}</h3>
                  <span class="shrink-0 font-mono text-[11px] text-ink-faint" title="at explain or deeper — held: two separate days · shown: once">{t.progress.held} held · {t.progress.shown ?? t.progress.held} shown / {t.progress.total}</span>
                  <button
                    class="shrink-0 font-mono text-[11px] text-ember hover:text-gold-leaf"
                    onClick={() => startSession(`Continue ${t.title} [${t.id}] — start from what my graph says is weakest`, t.id)}
                  >continue</button>
                </header>
                <div class="relative mb-3 h-[3px] rounded-full bg-rule">
                  <div class="absolute inset-y-0 left-0 rounded-full bg-gold-deep" style={{ width: `${t.progress.total ? (100 * (t.progress.shown ?? t.progress.held)) / t.progress.total : 0}%` }} />
                  <div class="absolute inset-y-0 left-0 rounded-full bg-gold-leaf" style={{ width: `${t.progress.total ? (100 * t.progress.held) / t.progress.total : 0}%` }} />
                </div>
                <For each={t.stages}>
                  {(st) => (
                    <div class="mb-2 grid grid-cols-[140px_minmax(0,1fr)] gap-3 max-[640px]:grid-cols-[1fr]">
                      <div class="pt-1 text-[12px] text-ink-faint">{st.name}</div>
                      <div class="flex flex-wrap gap-1.5">
                        <For each={st.concepts}>{(id) => <ConceptChip id={id} />}</For>
                      </div>
                    </div>
                  )}
                </For>
                <Show when={t.source}><div class="mt-2 font-mono text-[10.5px] text-ink-faint">{t.source}</div></Show>
              </article>
            )}
          </For>
        </section>
      </div>

      <aside class="min-w-0 max-[1060px]:mt-6">
        <section class="mb-8">
          <h2 class="font-display text-[17px] text-ink mb-2">Your open questions</h2>
          <Show when={openQs().length} fallback={<div class="text-[13px] text-ink-faint">None open. Ask one from any concept.</div>}>
            <ul class="m-0 p-0 list-none">
              <For each={openQs()}>
                {(q) => (
                  <li class="border-t border-rule py-2">
                    <div class="text-[13.5px] leading-snug text-ink">{q.text}</div>
                    <div class="mt-1 flex gap-3 font-mono text-[11px]">
                      <Show when={q.concept}><button class="text-ink-faint hover:text-gold-leaf" onClick={() => setDrawer(q.concept)}>{nameOf(q.concept)}</button></Show>
                      <button class="text-ember hover:text-gold-leaf" onClick={() => startSession(`My open question: ${q.text}`, q.topic || undefined)}>pursue</button>
                      <button class="text-ink-faint hover:text-ink" onClick={() => postJSON("/learning-question", { op: "close", id: q.id }).then(refreshLearn)}>answered</button>
                    </div>
                  </li>
                )}
              </For>
            </ul>
          </Show>
        </section>

        <Show when={pickable().length}>
          <section class="mb-8">
            <h2 class="font-display text-[17px] text-ink mb-1">Pick up from the terminal</h2>
            <p class="text-[12px] text-ink-faint mb-2 mt-0">Continues here as a copy; the terminal session is left alone.</p>
            <ul class="m-0 p-0 list-none">
              <For each={pickable()}>
                {(t) => (
                  <li class="border-t border-rule py-2">
                    <button class="block w-full text-left group" onClick={() => importTerminal(t.session).catch((e) => setPickErr(String(e)))}>
                      <span class="block truncate text-[13.5px] text-ink group-hover:text-gold-leaf">{t.target || worktreeName(t.cwd)}</span>
                      <span class="block font-mono text-[11px] text-ink-faint">{worktreeName(t.cwd)} · {t.answers} answers</span>
                    </button>
                  </li>
                )}
              </For>
            </ul>
          </section>
        </Show>

        <Show when={sessions.length}>
          <section>
            <h2 class="font-display text-[17px] text-ink mb-2">Sessions</h2>
            <ul class="m-0 p-0 list-none">
              <For each={recent()}>
                {(s) => (
                  <li class="group flex items-baseline gap-2 border-t border-rule py-2">
                    <button class="flex-1 min-w-0 truncate text-left text-[13px] text-ink-dim hover:text-ink" onClick={() => setActiveId(s.id)} title={s.target}>
                      {sessionTitle(s)}
                    </button>
                    <span class="shrink-0 font-mono text-[10.5px] text-ink-faint">rung {rungCount(s)} · {ago(touched(s))}</span>
                    <button
                      class="shrink-0 font-mono text-[11px] text-ink-faint opacity-0 group-hover:opacity-100 hover:text-del"
                      title="forget this session (its evidence stays in the graph)"
                      onClick={() => setSessions((all) => all.filter((x) => x.id !== s.id))}
                    >✕</button>
                  </li>
                )}
              </For>
            </ul>
          </section>
        </Show>
      </aside>
    </div>
  );
}

function SessionMap(props: { session: Session; here: string | null }) {
  const topic = () => (props.session.topic ? learn()?.topics[props.session.topic] : undefined);
  return (
    <nav class="flex min-h-0 flex-col overflow-y-auto border-r border-rule px-4 py-4">
      <Show
        when={topic()}
        fallback={<div class="text-[12.5px] leading-snug text-ink-faint">No map yet. The tutor draws one once it has read the material.</div>}
      >
        {(t) => (
          <>
            <div class={`${SECTION} mb-1`}>map</div>
            <div class="font-display text-[15px] leading-snug text-ink mb-1">{t().title}</div>
            <div class="mb-4 font-mono text-[10.5px] text-ink-faint">{t().progress.held} held · {t().progress.shown ?? t().progress.held} shown / {t().progress.total}</div>
            <For each={t().stages}>
              {(st) => (
                <div class="mb-4">
                  <div class="mb-1.5 text-[11.5px] text-ink-faint">{st.name}</div>
                  <div class="flex flex-col gap-1">
                    <For each={st.concepts}>{(id) => <ConceptChip id={id} here={props.here === id} wrap />}</For>
                  </div>
                </div>
              )}
            </For>
          </>
        )}
      </Show>
      <div class="mt-auto pt-4 font-mono text-[10px] leading-relaxed text-ink-faint">
        <div class="flex items-center gap-1.5"><Pips m={{ held: 1, depth: 2, assisted: 3, level: "", evidence: 0, last: "", due: false, reason: "", open_miss: "" }} /> predict · explain · transfer · critique</div>
        <div>solid = held (two days) · faint = shown once · outline = only with help · red = open misconception · ⊘ = needs a prerequisite first</div>
      </div>
    </nav>
  );
}

function TutorSession(props: { session: Session }) {
  const s = () => props.session;
  const [draft, setDraft] = createSignal("");
  const [historyOpen, setHistoryOpen] = createSignal(false);
  const [expanded, setExpanded] = createSignal<number | null>(null);
  const [evidenceOpen, setEvidenceOpen] = createSignal(false);
  const [mapOpen, setMapOpen] = createSignal(false);
  let scroller: HTMLDivElement | undefined;
  let box: HTMLTextAreaElement | undefined;

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
  const here = createMemo(() => latest(s().msgs, "rung")?.concept ?? null);
  const mine = createMemo(() => (learn()?.evidence ?? []).filter((e) => e.session === s().id));

  // the session's newest pin wins when it changes; a pin chosen from the drawer stays until then
  const newestPin = createMemo(() => latest(s().msgs, "pin")?.pin ?? null, null, {
    equals: (a, b) => JSON.stringify(a) === JSON.stringify(b),
  });
  createEffect(() => setPin(newestPin()));
  // a new rung starts reading at its TOP — never chase the bottom while it streams
  createEffect(() => {
    current()?.tutorIdx;
    queueMicrotask(() => scroller?.scrollTo({ top: 0 }));
  });

  // A rung marked `confidence: true` wants a rating BEFORE the reveal. Enter without one flags the
  // chips once; a second Enter sends without a rating rather than trapping the answer.
  const [confidence, setConfidence] = createSignal<string | null>(null);
  const [askedConfidence, setAskedConfidence] = createSignal(false);
  const wantsConfidence = () => {
    const c = current();
    if (!c) return false;
    const r = segments(s().msgs[c.tutorIdx].text).find((x) => x.kind === "rung") as Extract<Seg, { kind: "rung" }> | undefined;
    return !!r?.confidence;
  };
  createEffect(() => {
    current()?.tutorIdx;
    setConfidence(null);
    setAskedConfidence(false);
  });

  const send = (text: string, opts?: { plain?: boolean }) => {
    if (!text.trim() || streaming()) return;
    if (!opts?.plain && wantsConfidence() && !confidence() && !askedConfidence()) {
      setAskedConfidence(true);
      return;
    }
    answer(s().id, !opts?.plain && confidence() ? `${text} (confidence: ${confidence()})` : text);
    setDraft("");
    setExpanded(null);
    box?.focus();
  };

  return (
    <div
      class="tutor grid h-screen max-[900px]:grid-cols-[1fr] max-[900px]:h-auto"
      classList={{
        "grid-cols-[260px_minmax(0,1fr)_minmax(0,1fr)] max-[1200px]:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]": !!pin(),
        "grid-cols-[260px_minmax(0,760px)] max-[1200px]:grid-cols-[minmax(0,1fr)]": !pin(),
      }}
    >
      <div class="min-h-0 max-[1200px]:hidden flex">
        <SessionMap session={s()} here={here()} />
      </div>
      <div class="flex min-h-0 flex-col border-r border-rule max-[900px]:border-r-0">
        <header class="flex items-baseline gap-3 border-b border-rule px-5 py-3">
          <button class="font-mono text-[11px] text-ink-faint hover:text-gold-leaf" onClick={() => setActiveId(null)} title="your graph">← tutor</button>
          <span class="flex-1 min-w-0 truncate font-display text-[15px] text-ink" title={s().target}>
            {(s().topic && learn()?.topics[s().topic!]?.title) || s().target}
          </span>
          <button class="hidden shrink-0 font-mono text-[11px] text-ink-faint hover:text-gold-leaf max-[1200px]:inline" onClick={() => setMapOpen((v) => !v)}>map</button>
          <button
            class="shrink-0 font-mono text-[11px] hover:text-gold-leaf"
            classList={{ "text-gold-leaf": evidenceOpen(), "text-ink-faint": !evidenceOpen() }}
            title="what this session has recorded about you — audit it"
            onClick={() => setEvidenceOpen((v) => !v)}
          >evidence · {mine().length}</button>
          <button
            class="shrink-0 font-mono text-[11px] text-ink-faint hover:text-ember disabled:opacity-40"
            disabled={streaming()}
            title="ask for the consolidation: each principle said plainly"
            onClick={() => send("Let's stop here. Consolidate: say each principle we reached plainly, and record evidence for my last answer.", { plain: true })}
          >wrap up</button>
        </header>

        <Show when={mapOpen()}>
          <div class="max-h-[50vh] overflow-y-auto border-b border-rule"><SessionMap session={s()} here={here()} /></div>
        </Show>

        <Show when={evidenceOpen()}>
          <div class="max-h-[45vh] overflow-y-auto border-b border-rule bg-vellum-raise px-5 py-3">
            <div class={`${SECTION} mb-2`}>recorded this session — edit or cut anything over-credited</div>
            <Show when={mine().length} fallback={<div class="text-[12.5px] text-ink-faint">Nothing yet. Evidence lands after each answer.</div>}>
              <For each={mine()}>{(e) => <EvidenceRow e={e} showConcept />}</For>
            </Show>
          </div>
        </Show>

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
                            <TutorTurn text={s().msgs[r.tutorIdx].text} latest={false} onPick={() => {}} />
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
              {(c) => <TutorTurn text={s().msgs[c().tutorIdx].text} latest={true} onPick={(o) => setDraft(o)} />}
            </Show>
            <Show when={streaming() && status()}>
              <div class="font-mono text-[11px] text-ink-faint truncate">{status()}…</div>
            </Show>
            <Show when={s().error}>
              <div class="mt-2 font-mono text-[12px] text-del">{s().error}</div>
            </Show>
          </div>
        </div>

        <form class="border-t border-rule p-4" onSubmit={(e) => { e.preventDefault(); send(draft()); }}>
          <textarea
            ref={box}
            class="block w-full resize-none rounded-sm border border-rule bg-vellum-raise px-3 py-2 text-[14px] leading-relaxed text-ink outline-none focus:border-gold-deep"
            rows={3}
            placeholder={streaming() ? "…" : "your prediction, your why, or your own question"}
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
          <Show when={wantsConfidence() && !streaming()}>
            <div class="mt-2 flex flex-wrap items-center gap-2">
              <span class="font-mono text-[11px]" classList={{ "text-ember": askedConfidence() && !confidence(), "text-ink-faint": !askedConfidence() || !!confidence() }}>
                {askedConfidence() && !confidence() ? "how sure are you? (enter again to skip)" : "how sure are you?"}
              </span>
              <For each={CONFIDENCES}>
                {(c) => (
                  <button
                    type="button"
                    class="rounded-sm border px-2.5 py-0.5 font-mono text-[11px]"
                    classList={{
                      "border-gold-leaf bg-gold-wash text-gold-leaf": confidence() === c,
                      "border-rule text-ink-dim hover:border-gold-deep hover:text-ink": confidence() !== c,
                    }}
                    onClick={() => setConfidence((v) => (v === c ? null : c))}
                  >{c}</button>
                )}
              </For>
            </div>
          </Show>
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
      <Show when={pin()}>
        <CodePane pin={pin()} />
      </Show>
    </div>
  );
}

function TutorTurn(props: { text: string; latest: boolean; onPick: (o: string) => void }) {
  const segs = createMemo(() => segments(props.text));
  return (
    <div class="mb-5">
      <For each={segs()}>
        {(seg): JSX.Element => {
          switch (seg.kind) {
            case "prose":
              return <div class="wiki-prose text-[15px] [&_a]:text-gold-leaf [&_a]:underline [&_a]:decoration-gold-deep" innerHTML={renderMarkdown(seg.text)} />;
            case "pin":
              return (
                <button
                  class="my-1.5 inline-flex max-w-full items-baseline gap-2 rounded-sm border border-rule px-2 py-0.5 font-mono text-[11px] text-ink-dim hover:border-gold-deep hover:text-gold-leaf"
                  onClick={() => setPin(seg.pin)}
                  title="show in the code pane"
                >
                  <span class="truncate">{seg.pin.path}</span>
                  <Show when={seg.pin.lines}><span class="shrink-0 text-ink-faint">L{seg.pin.lines![0]}–{seg.pin.lines![1]}</span></Show>
                </button>
              );
            case "options":
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
            case "rung":
              return (
                <button class="mb-2 inline-flex items-center gap-2 font-mono text-[10.5px] text-ink-faint hover:text-gold-leaf" onClick={() => setDrawer(seg.concept)}>
                  <Pips m={conceptOf(seg.concept)?.mastery} />
                  <span>
                    testing {nameOf(seg.concept)} · {seg.level}
                    {seg.rung === "invent" ? " · invent the rule" : ""}
                    {seg.via ? ` · via ${nameOf(seg.via)}` : ""}
                    {seg.contrastOf ? " · contrast re-test of a miss" : ""}
                    {seg.confidence ? " · rate your confidence" : ""}
                  </span>
                </button>
              );
            case "evidence":
              return (
                <div class="mb-3 flex flex-col gap-1">
                  <For each={seg.items}>
                    {(e) => (
                      <button
                        class="flex items-baseline gap-2 text-left font-mono text-[11px] leading-snug hover:text-gold-leaf"
                        classList={{ "text-add": e.outcome !== "miss", "text-del": e.outcome === "miss" }}
                        title="recorded in your graph — open the concept to audit it"
                        onClick={() => setDrawer(e.concept)}
                      >
                        <span>{e.outcome === "miss" ? "✗" : "✓"}</span>
                        <span class="min-w-0">
                          <span>{nameOf(e.concept)} · {e.level} · {e.credit}{e.confidence ? ` · ${e.confidence} confidence` : ""}{e.via ? ` · via ${nameOf(e.via)}` : ""}</span>
                          <Show when={e.note}><span class="text-ink-faint"> — {e.note}</span></Show>
                          <Show when={e.contrast}><span class="block text-ink-faint">re-test with: {e.contrast}</span></Show>
                        </span>
                      </button>
                    )}
                  </For>
                </div>
              );
            case "map":
              return <div class="mb-2 font-mono text-[10.5px] text-ink-faint">map drawn · {seg.count} concepts in {seg.title}</div>;
            case "restate":
              return (
                <button class="my-2 block text-left text-[13.5px] text-gold-leaf hover:underline" onClick={() => setDrawer(seg.concept)}>
                  <span class="font-mono text-[10px] uppercase tracking-[0.12em] text-ink-faint">in your words · {nameOf(seg.concept)} </span>
                  “{seg.text}”
                </button>
              );
            case "question":
              return (
                <div class="my-2 font-mono text-[11px] text-ink-faint">
                  ? your question, kept open{seg.concept ? ` on ${nameOf(seg.concept)}` : ""}: <span class="text-ink-dim">{seg.text}</span>
                </div>
              );
            case "quiet":
              return <></>;
          }
        }}
      </For>
    </div>
  );
}

function EvidenceRow(props: { e: Evidence; showConcept?: boolean }) {
  const [err, setErr] = createSignal("");
  const edit = (fields: Partial<Evidence>) =>
    postJSON("/learning-evidence", { op: "edit", id: props.e.id, fields }).then(refreshLearn).catch((x) => setErr(String(x)));
  const SELECT = "rounded-sm border border-rule bg-vellum-night px-1 py-0.5 font-mono text-[11px] text-ink-dim";
  return (
    <div class="group border-t border-rule py-2 first:border-t-0">
      <div class="flex flex-wrap items-center gap-1.5">
        <button
          class="font-mono text-[12px]"
          classList={{ "text-add": props.e.outcome === "hit", "text-del": props.e.outcome === "miss" }}
          title="toggle hit / miss"
          onClick={() => edit({ outcome: props.e.outcome === "hit" ? "miss" : "hit" })}
        >{props.e.outcome === "miss" ? "✗" : "✓"}</button>
        <Show when={props.showConcept}>
          <button class="text-[12.5px] text-ink hover:text-gold-leaf" onClick={() => setDrawer(props.e.concept)}>{nameOf(props.e.concept)}</button>
        </Show>
        <select class={SELECT} value={props.e.level} title="level" onChange={(ev) => edit({ level: ev.currentTarget.value })}>
          <For each={LEVELS}>{(l) => <option value={l}>{l}</option>}</For>
        </select>
        <select class={SELECT} value={props.e.credit} title="credit" onChange={(ev) => edit({ credit: ev.currentTarget.value })}>
          <For each={CREDITS}>{(c) => <option value={c}>{c}</option>}</For>
        </select>
        <select class={SELECT} value={props.e.confidence ?? ""} title="confidence, rated before the reveal" onChange={(ev) => edit({ confidence: ev.currentTarget.value })}>
          <option value="">no rating</option>
          <For each={CONFIDENCES}>{(c) => <option value={c}>{c}</option>}</For>
        </select>
        <span class="font-mono text-[10.5px] text-ink-faint">{props.e.at}{props.e.rung === "invent" ? " · invent" : ""}{props.e.via ? ` · via ${nameOf(props.e.via)}` : ""}</span>
        <span class="flex-1" />
        <button
          class="font-mono text-[11px] text-ink-faint opacity-0 group-hover:opacity-100 hover:text-del"
          title="cut this evidence"
          onClick={() => postJSON("/learning-evidence", { op: "delete", id: props.e.id }).then(refreshLearn).catch((x) => setErr(String(x)))}
        >✕</button>
      </div>
      <Show when={props.e.note}><div class="mt-0.5 text-[12.5px] leading-snug text-ink-dim">{props.e.note}</div></Show>
      <Show when={props.e.contrast}><div class="mt-0.5 text-[12px] leading-snug text-ink-faint">re-test with: {props.e.contrast}</div></Show>
      <Show when={err()}><div class="font-mono text-[11px] text-del">{err()}</div></Show>
    </div>
  );
}

function ConceptDrawer(props: { id: string }) {
  const c = () => conceptOf(props.id);
  const [q, setQ] = createSignal("");
  const [err, setErr] = createSignal("");
  const evidence = createMemo(() => (learn()?.evidence ?? []).filter((e) => e.concept === props.id).slice().reverse());
  const questions = createMemo(() => (learn()?.questions ?? []).filter((x) => x.concept === props.id));
  const Links = (p: { label: string; ids: string[] }) => (
    <Show when={p.ids.length}>
      <div class="mb-3">
        <div class={`${SECTION} mb-1.5`}>{p.label}</div>
        <div class="flex flex-wrap gap-1.5"><For each={p.ids}>{(id) => <ConceptChip id={id} />}</For></div>
      </div>
    </Show>
  );
  return (
    <aside class="fixed top-0 right-0 z-[60] flex h-screen w-[460px] max-w-full flex-col border-l border-gold-deep bg-vellum-raise shadow-[-12px_0_32px_rgba(0,0,0,0.45)]">
      <Show when={c()} fallback={<div class="p-6 text-ink-faint">Unknown concept {props.id}</div>}>
        {(cc) => (
          <div class="flex-1 overflow-y-auto px-6 py-5">
            <div class="mb-2 flex items-baseline gap-2">
              <span class={SECTION}>{cc().kind === "convention" ? "convention · told, then tested" : "principle · derivable"}</span>
              <span class="flex-1" />
              <button class="font-mono text-[13px] text-ink-faint hover:text-ink" onClick={() => setDrawer(null)} title="close (esc)">✕</button>
            </div>
            <h2 class="m-0 mb-2 font-display text-[22px] leading-tight text-ink">{cc().name}</h2>
            <Show when={cc().statement_learner}>
              <div class="mb-2">
                <div class={`${SECTION} mb-0.5`}>in your words{cc().restated ? ` · ${cc().restated}` : ""}</div>
                <p class="m-0 text-[15px] leading-relaxed text-gold-leaf">“{cc().statement_learner}”</p>
              </div>
              <div class={`${SECTION} mb-0.5`}>the tutor's version</div>
            </Show>
            <p class="mt-0 mb-4 text-[14.5px] leading-relaxed text-ink-dim">{cc().statement}</p>

            <div class="mb-4 rounded-sm border border-rule bg-vellum-night p-3">
              <div class="mb-2 flex items-center gap-3">
                <Pips m={cc().mastery} size="md" />
                <span class="text-[13px] text-ink">
                  {cc().mastery.held
                    ? `held at ${cc().mastery.held_level}${cc().mastery.depth > (cc().mastery.held ?? 0) ? ` · shown once at ${cc().mastery.level}` : ""}`
                    : cc().mastery.level ? `shown once at ${cc().mastery.level} — a second day makes it held` : "not yet shown unaided"}
                </span>
              </div>
              <div class="grid grid-cols-[72px_1fr] gap-x-2 gap-y-0.5 font-mono text-[10.5px] text-ink-faint">
                <For each={LEVELS}>{(l) => <><span>{l}</span><span>{LEVEL_HINT[l]}</span></>}</For>
              </div>
              <Show when={cc().mastery.due}>
                <div class="mt-2 text-[12.5px] text-ember">
                  Due{cc().mastery.miss_confidence === "high" ? " (a confident miss — re-test first)" : ""}: {cc().mastery.reason}
                </div>
              </Show>
              <Show when={cc().mastery.contrast}>
                <div class="mt-1 text-[12.5px] text-ink-dim">Re-test with the contrast: {cc().mastery.contrast}</div>
              </Show>
            </div>

            <div class="mb-5 flex flex-wrap gap-2">
              <button class="rounded-sm border border-gold-deep bg-gold-wash px-3 py-1 font-display text-[14px] text-gold-leaf hover:bg-vellum-edge"
                onClick={() => startSession(`Re-test me cold on ${cc().name} [${cc().id}]`, cc().topics[0])}>re-test me cold</button>
              <button class="rounded-sm border border-rule px-3 py-1 font-display text-[14px] text-ink-dim hover:text-ink"
                onClick={() => startSession(`Teach me ${cc().name} [${cc().id}]: ${cc().statement}`, cc().topics[0])}>teach me this</button>
            </div>

            <Links label="needs first — never shown unaided" ids={cc().blocked_by ?? []} />
            <Links label="builds on" ids={cc().builds_on.filter((b) => !(cc().blocked_by ?? []).includes(b))} />
            <Links label="what builds on it" ids={cc().built_on_by} />
            <Links label="same idea elsewhere" ids={cc().analogs} />
            <Show when={cc().topics.length}>
              <div class="mb-4 font-mono text-[10.5px] text-ink-faint">in: {cc().topics.map((t) => learn()?.topics[t]?.title ?? t).join(" · ")}</div>
            </Show>
            <Show when={cc().code.length}>
              <div class="mb-4">
                <div class={`${SECTION} mb-1.5`}>code</div>
                <For each={cc().code}>
                  {(r) => (
                    <button
                      class="block max-w-full truncate font-mono text-[11px] text-ink-dim hover:text-gold-leaf disabled:hover:text-ink-dim"
                      disabled={!activeSession()}
                      title={activeSession() ? "show in the code pane" : "open a session to see code"}
                      onClick={() => setPin({ path: r.path, ref: r.ref, lines: r.lines ? [r.lines[0], r.lines[1] ?? r.lines[0]] : undefined })}
                    >{r.path}{r.lines ? ` L${r.lines[0]}–${r.lines[1] ?? r.lines[0]}` : ""}</button>
                  )}
                </For>
              </div>
            </Show>

            <div class="mb-5">
              <div class={`${SECTION} mb-1.5`}>your questions</div>
              <For each={questions()}>
                {(x) => (
                  <div class="flex items-baseline gap-2 py-1 text-[13px]">
                    <span class="flex-1" classList={{ "text-ink": x.status === "open", "text-ink-faint line-through": x.status !== "open" }}>{x.text}</span>
                    <button class="font-mono text-[10.5px] text-ink-faint hover:text-ink"
                      onClick={() => postJSON("/learning-question", { op: x.status === "open" ? "close" : "reopen", id: x.id }).then(refreshLearn)}>
                      {x.status === "open" ? "answered" : "reopen"}
                    </button>
                  </div>
                )}
              </For>
              <form class="mt-1.5 flex gap-2" onSubmit={(e) => { e.preventDefault(); ask(q(), cc()).then(() => setQ("")).catch((x) => setErr(String(x))); }}>
                <input
                  class="min-w-0 flex-1 rounded-sm border border-rule bg-vellum-night px-2 py-1 text-[13px] text-ink outline-none focus:border-gold-deep"
                  placeholder={activeSession() ? "ask the tutor about this…" : "ask — starts a session on it"}
                  value={q()}
                  onInput={(e) => setQ(e.currentTarget.value)}
                />
                <button class="font-mono text-[11px] text-ember hover:text-gold-leaf" type="submit">ask</button>
              </form>
              <Show when={err()}><div class="mt-1 font-mono text-[11px] text-del">{err()}</div></Show>
            </div>

            <div>
              <div class={`${SECTION} mb-1`}>evidence · newest first</div>
              <div class="mb-2 text-[11.5px] text-ink-faint">Depth comes only from this. Toggle hit/miss, change level or credit, or cut a row.</div>
              <Show when={evidence().length} fallback={<div class="text-[12.5px] text-ink-faint">None yet.</div>}>
                <For each={evidence()}>{(e) => <EvidenceRow e={e} />}</For>
              </Show>
            </div>
          </div>
        )}
      </Show>
    </aside>
  );
}

const LANG_BY_EXT: Record<string, string> = {
  ts: "typescript", tsx: "typescript", mts: "typescript", cts: "typescript",
  js: "javascript", jsx: "javascript", mjs: "javascript", cjs: "javascript",
  py: "python", json: "json", sh: "bash", zsh: "bash", bash: "bash", sql: "sql", css: "css",
  html: "xml", xml: "xml", svg: "xml", yml: "yaml", yaml: "yaml", md: "markdown", diff: "diff", patch: "diff",
};
const HIGHLIGHT_MAX = 300_000;

const escapeHtml = (t: string) => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

// Highlight the WHOLE file (so a multi-line comment or string colors correctly), then cut the HTML
// into lines, closing the spans still open at each newline and reopening them on the next line.
function highlightLines(text: string, path: string): string[] {
  const lang = LANG_BY_EXT[path.split(".").pop()?.toLowerCase() ?? ""];
  let html: string;
  if (text.length > HIGHLIGHT_MAX) {
    html = escapeHtml(text);
  } else if (lang && hljs.getLanguage(lang)) {
    html = hljs.highlight(text, { language: lang, ignoreIllegals: true }).value;
  } else {
    html = hljs.highlightAuto(text).value;
  }
  const out: string[] = [];
  const open: string[] = [];
  let cur = "";
  for (const m of html.matchAll(/<span[^>]*>|<\/span>|\n|[^<\n]+/g)) {
    const t = m[0];
    if (t === "\n") {
      out.push(cur + "</span>".repeat(open.length));
      cur = open.join("");
    } else if (t.startsWith("<span")) {
      open.push(t);
      cur += t;
    } else if (t === "</span>") {
      open.pop();
      cur += t;
    } else {
      cur += t;
    }
  }
  out.push(cur + "</span>".repeat(open.length));
  return out;
}

function CodePane(props: { pin: Pin | null }) {
  const key = () => (props.pin ? `${props.pin.ref ?? ""}:${props.pin.path}` : null);
  const [src] = createResource(key, () => {
    const p = props.pin!;
    return fetchJSON<SrcReply>(`/tutor-src?path=${encodeURIComponent(p.path)}&ref=${encodeURIComponent(p.ref ?? "")}`);
  });
  let pane: HTMLDivElement | undefined;
  const lines = createMemo(() => highlightLines((src()?.text ?? "").replace(/\n$/, ""), props.pin?.path ?? ""));
  const focused = () => !!props.pin?.lines;
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
                  {/* innerHTML: hljs output — it escapes the file's text, and the file is local code */}
                  <span
                    class="whitespace-pre pr-4 text-ink"
                    classList={{ "opacity-55": focused() && !lit(i() + 1) }}
                    innerHTML={ln || " "}
                  />
                </div>
              )}
            </For>
          </pre>
        </Show>
      </div>
    </div>
  );
}
