// The tutor's state: the learner's concept graph (GET /learning-state, re-read after every turn and
// every audit), the sessions this browser keeps, and the turn streaming now. A turn is POST /tutor,
// answered as server-sent events — a headless read-only claude, so starting or answering one spends
// a model call; a reload re-attaches to a turn still running (a body with only its turn id never
// starts one). The graph itself is written by the server, never here.
import { createMemo, createRoot, createSignal } from "solid-js";
import { createStore, produce } from "solid-js/store";
import { latest, segments, simResultFence, type CodeSrc, type Concept, type ImportReply, type LearnState, type Pin, type Seg, type Session, type TerminalSession } from "./lesson";
import { navigate, routeArg, surface, tutorPath } from "./router";
import { getJSON, streamPost } from "./sync";
import { createSim, type Kernel } from "./sim";
import { scenario } from "./simScenarios";

const STORE_KEY = "tutor:sessions:v1";
export const ckey = (id: string) => `c:${id}`;
export const skey = (id: string) => `s:${id}`;
const touched = (s: Session) => s.lastActive ?? s.created;
const uuid = () => crypto.randomUUID();
const worktreeName = (cwd: string) => cwd.split("/").pop() || cwd;

function loadSessions(): Session[] {
  try {
    return JSON.parse(localStorage.getItem(STORE_KEY) || "[]") as Session[];
  } catch {
    return [];
  }
}

export const tutor = createRoot(() => {
  const [sessions, setSessions] = createStore<Session[]>(loadSessions());
  const save = () => {
    try {
      localStorage.setItem(STORE_KEY, JSON.stringify(sessions));
    } catch {
      /* private window, or full: sessions just won't survive a reload */
    }
  };
  const at = (id: string) => sessions.findIndex((s) => s.id === id);
  const recent = createMemo(() => [...sessions].sort((a, b) => touched(b) - touched(a)));
  /** The session the URL names (/v2/tutor/<id>), or undefined on the home page. */
  const active = createMemo(() => (surface().id === "tutor" && routeArg() ? sessions.find((s) => s.id === routeArg()) : undefined));

  const [learn, setLearn] = createSignal<LearnState | undefined>();
  const [learnErr, setLearnErr] = createSignal("");
  let reading = false;
  function refresh(): void {
    if (reading) return;
    reading = true;
    getJSON<LearnState>("/learning-state")
      .then((s) => {
        setLearn(s);
        setLearnErr("");
      }, (e) => setLearnErr(String(e)))
      .finally(() => (reading = false));
  }
  /** Read the graph if it hasn't been yet — the menu's finder asks too. */
  const load = () => void (learn() || refresh());
  const concept = (id: string | undefined): Concept | undefined => (id ? learn()?.concepts[id] : undefined);
  const nameOf = (id: string) => concept(id)?.name ?? id.replace(/-/g, " ");
  const titleOf = (s: Session) => (s.topic && learn()?.topics[s.topic]?.title) || s.target;
  const due = () => learn()?.due ?? [];
  const openQuestions = () => (learn()?.questions ?? []).filter((q) => q.status === "open");

  const [drawer, setDrawer] = createSignal<string | undefined>();
  const [pin, setPin] = createSignal<Pin | undefined>();
  const [code, setCode] = createSignal<CodeSrc | undefined>();
  const [streaming, setStreaming] = createSignal(false);
  const [status, setStatus] = createSignal("");
  const [evidenceOpen, setEvidenceOpen] = createSignal(false);
  const [mapOpen, setMapOpen] = createSignal(false);
  const [historyOpen, setHistoryOpen] = createSignal(false);
  const [expanded, setExpanded] = createSignal<number | undefined>();
  const [allDue, setAllDue] = createSignal(false);
  const [confidence, setConfidence] = createSignal<string | undefined>();
  const [askedConfidence, setAskedConfidence] = createSignal(false);
  /** what's typed: the home page's "dig into", the answer box, the drawer's question */
  const [target, setTarget] = createSignal("");
  const [draft, setDraft] = createSignal("");
  const [question, setQuestion] = createSignal("");
  const [terminal, setTerminal] = createSignal<TerminalSession[]>([]);
  const [error, setError] = createSignal("");

  /** The home page's rows: what's due (as many as show), then the sessions you keep; in a session, its map's concepts. */
  const rows = createMemo(() => {
    const s = active();
    if (s) {
      const t = s.topic ? learn()?.topics[s.topic] : undefined;
      return (t?.stages ?? []).flatMap((st) => st.concepts.map(ckey));
    }
    return [...(allDue() ? due() : due().slice(0, 8)).map(ckey), ...recent().map((x) => skey(x.id))];
  });

  // the code pane follows the pin
  let pinned = "";
  function showPin(p: Pin | undefined): void {
    setPin(p);
    const key = p ? `${p.ref ?? ""}:${p.path}` : "";
    if (key === pinned) return;
    pinned = key;
    setCode(undefined);
    if (!p) return;
    getJSON<CodeSrc>(`/tutor-src?path=${encodeURIComponent(p.path)}&ref=${encodeURIComponent(p.ref ?? "")}`).then(
      (c) => pinned === key && setCode(c),
      (e) => pinned === key && setCode({ path: p.path, ref: p.ref ?? "", text: "", err: String(e) }),
    );
  }

  /** The current rung asks for a confidence rating before the reveal. */
  const wantsConfidence = () => {
    const s = active();
    const last = s?.msgs[s.msgs.length - 1];
    if (!last || last.role !== "tutor") return false;
    return !!(segments(last.text).find((x) => x.kind === "rung") as Extract<Seg, { kind: "rung" }> | undefined)?.confidence;
  };
  /** The concept the current rung tests — "you are here" on the map. */
  const here = () => {
    const s = active();
    return s ? (latest(s.msgs, "rung")?.concept ?? undefined) : undefined;
  };

  let leaving = false;
  window.addEventListener("pagehide", () => (leaving = true));

  async function runTurn(id: string, body: Record<string, string>, reattach = false): Promise<void> {
    const i = () => at(id);
    setSessions(i(), { pendingTurn: body.turn, lastActive: Date.now(), error: undefined });
    save();
    setStreaming(true);
    setStatus("thinking");
    const s = sessions[i()];
    body = { ...body, tab: id };
    if (s.topic) body.topic = s.topic;
    if (s.cwd) body.cwd = s.cwd;
    if (s.forkNext && body.resume) body.fork = "1";
    if (typeof s.primed === "string") body.primed = s.primed;
    let tutorIdx = s.msgs.length - 1;
    let reset = reattach;
    try {
      await streamPost("/tutor", body, (event, p) => {
        if (event === "session" && p.session_id) {
          setSessions(i(), "sessionId", String(p.session_id));
          if (p.session_id !== sessions[i()].importedFrom) setSessions(i(), "forkNext", false);
        } else if (event === "token") {
          if (reset) {
            setSessions(i(), "msgs", tutorIdx, "text", "");
            reset = false;
          }
          setStatus("");
          setSessions(i(), "msgs", tutorIdx, "text", (t) => t + String(p.t ?? ""));
        } else if (event === "tool") {
          setStatus(`reading · ${String(p.arg || p.name)}`);
        } else if (event === "status") {
          if (p.s === "thinking") setStatus("thinking");
        } else if (event === "graph") {
          if (p.topic) setSessions(i(), "topic", String(p.topic));
          if (p.protocol) setSessions(i(), "primed", String(p.protocol));
          const errors = p.errors as string[] | undefined;
          if (errors?.length) setSessions(i(), "error", "graph: " + errors.join("; "));
          refresh();
        } else if (event === "gone") {
          setSessions(i(), "error", "that turn was lost (the server restarted) — send your answer again");
          setSessions(i(), "msgs", produce((m) => void (m[tutorIdx]?.role === "tutor" && !m[tutorIdx].text && m.splice(tutorIdx, 1))));
          tutorIdx = -1;
        } else if (event === "error") {
          setSessions(i(), "error", String(p.err || "the turn failed"));
        } else if (event === "done" && p.stopped) {
          setSessions(i(), "msgs", produce((m) => void (m[tutorIdx]?.role === "tutor" && !m[tutorIdx].text && m.splice(tutorIdx, 1))));
        }
        return event === "done" || event === "error" || event === "gone";
      });
    } catch (e) {
      if (!leaving) setSessions(i(), "error", String(e));
    } finally {
      // a reload aborts the stream mid-turn: keep pendingTurn so the next load re-attaches
      if (!leaving) {
        setSessions(i(), "pendingTurn", undefined);
        save();
        setStreaming(false);
        setStatus("");
      }
    }
  }

  /** A new session on `goal` (a PR, a branch, a concept, a re-test) — it opens at once and streams in. */
  function start(goal: string, topic?: string): void {
    const id = uuid();
    setSessions(produce((s) => void s.unshift({ id, target: goal, topic, created: Date.now(), sessionId: "", msgs: [{ role: "tutor", text: "" }] })));
    setDrawer(undefined);
    navigate(tutorPath(id));
    void runTurn(id, { turn: uuid(), target: goal });
  }

  /** Send an answer (or a question) into a session — a rung that froze a sim plays it now, and the
   *  answer carries what the system did for the tutor to record. */
  function answer(id: string, text: string): boolean {
    const s = sessions[at(id)];
    if (!s || streaming() || !text.trim()) return false;
    text += played(s.msgs[s.msgs.length - 1]?.role === "tutor" ? s.msgs[s.msgs.length - 1].text : "");
    setSessions(at(id), "msgs", produce((m) => void m.push({ role: "me", text }, { role: "tutor", text: "" })));
    void runTurn(id, { turn: uuid(), answer: text, resume: s.sessionId });
    return true;
  }

  function played(turn: string): string {
    const sim = segments(turn).find((x) => x.kind === "sim");
    if (sim?.kind !== "sim") return "";
    try {
      const r = createSim(scenario(sim.scenario), Object.fromEntries(sim.off.map((k) => [k as Kernel, false]))).runToEnd();
      return "\n\n" + simResultFence({ scenario: sim.scenario, off: sim.off, outcome: r.outcome, divergence: r.divergence });
    } catch {
      return "";
    }
  }

  function forget(id: string): void {
    setSessions((all) => all.filter((x) => x.id !== id));
    save();
  }

  /** A terminal /tutor session, continued here as a fork; its own transcript is left alone. */
  async function pickUp(session: string): Promise<void> {
    const kept = sessions.find((s) => s.importedFrom === session && !s.saved);
    if (kept) return navigate(tutorPath(kept.id));
    const r = await getJSON<ImportReply>(`/tutor-import?session=${encodeURIComponent(session)}`);
    if (r.err) throw new Error(r.err);
    const id = uuid();
    setSessions(
      produce((s) =>
        void s.unshift({
          id,
          created: Date.now(),
          msgs: r.msgs,
          sessionId: r.session,
          cwd: r.cwd,
          forkNext: true,
          importedFrom: r.session,
          target: r.target || `picked up from the terminal · ${worktreeName(r.cwd)}`,
        }),
      ),
    );
    save();
    navigate(tutorPath(id));
  }

  const listTerminal = () => void getJSON<TerminalSession[]>("/tutor-terminal").then(setTerminal, () => setTerminal([]));
  const pickable = () => {
    const ours = new Set(sessions.flatMap((s) => [s.sessionId, s.importedFrom ?? ""]));
    return terminal().filter((t) => !ours.has(t.session));
  };

  let attached = false;
  /** Once per page load: re-attach to turns a reload interrupted, so their replies still land. */
  function reattach(): void {
    if (attached) return;
    attached = true;
    for (const s of sessions) if (s.pendingTurn) void runTurn(s.id, { turn: s.pendingTurn }, true);
  }

  let box: (() => void) | undefined;
  /** The page's writing box registers itself; `i` focuses it. */
  const setBox = (fn: (() => void) | undefined) => (box = fn);
  const focusBox = () => {
    if (!box) return false;
    box();
    return true;
  };

  return {
    sessions,
    recent,
    active,
    learn,
    learnErr,
    refresh,
    load,
    concept,
    nameOf,
    titleOf,
    due,
    openQuestions,
    rows,
    drawer,
    setDrawer,
    pin,
    code,
    showPin,
    streaming,
    status,
    evidenceOpen,
    setEvidenceOpen,
    mapOpen,
    setMapOpen,
    historyOpen,
    setHistoryOpen,
    expanded,
    setExpanded,
    allDue,
    setAllDue,
    confidence,
    setConfidence,
    askedConfidence,
    setAskedConfidence,
    wantsConfidence,
    here,
    target,
    setTarget,
    draft,
    setDraft,
    question,
    setQuestion,
    error,
    setError,
    start,
    answer,
    forget,
    pickUp,
    listTerminal,
    pickable,
    reattach,
    setBox,
    focusBox,
  };
});

export { touched };
