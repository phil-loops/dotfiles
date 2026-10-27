// The tutor's moves. Starting or answering a session spends a model call (POST /tutor, streamed);
// a question you raise and every audit of a credit are graph writes (POST /learning-question,
// /learning-evidence), each with its undo where one exists. Forgetting a saved session and cutting
// a credit take a second press.
import { CONFIDENCES, type Evidence } from "../lesson";
import { command, type Write } from "../registry";
import { navigate, tutorPath } from "../router";
import { armed, menuOpen, setArmed, setCursor, setMenuOpen, setSheetOpen, sheetOpen } from "../ui";
import { ckey, tutor } from "../tutoring";

const known = (id: string | undefined) => !!tutor.concept(id);
const kept = (id: string | undefined) => !!id && tutor.sessions.some((s) => s.id === id);
const idle = () => !tutor.streaming();

// ── going places ──

command({
  id: "tutor.concept",
  label: "open",
  title: "Open the concept: its depth, evidence and questions",
  scope: "concept",
  budget: "local",
  keys: ["ret"],
  available: known,
  local: (id) => tutor.setDrawer(id),
});
command({
  id: "tutor.open",
  label: "open",
  title: "Open the session",
  scope: "lesson",
  budget: "local",
  keys: ["ret"],
  v1: ["click:continue"],
  available: kept,
  local: (id, e) => {
    tutor.setDrawer(undefined);
    navigate(tutorPath(id), e);
  },
});
command({
  id: "tutor.home",
  label: "home",
  title: "Leave the session for your graph",
  scope: "session",
  budget: "local",
  keys: ["h", "left"],
  v1: ["click:your graph"],
  local: (_t, e) => {
    tutor.setDrawer(undefined);
    navigate(tutorPath(), e);
  },
});
command({
  id: "tutor.back",
  label: "back",
  title: "Back out",
  scope: "tutor",
  budget: "local",
  keys: ["esc"],
  quiet: true,
  v1: ["click:close (esc)"],
  local: () => {
    if (menuOpen() || sheetOpen()) {
      setMenuOpen(false);
      setSheetOpen(false);
    } else if (armed()) setArmed(undefined);
    else if (tutor.drawer()) tutor.setDrawer(undefined);
    else if (tutor.evidenceOpen()) tutor.setEvidenceOpen(false);
    else throw new Error("nothing to close");
  },
});
command({
  id: "find.concept",
  title: "Open a concept you found",
  scope: "global",
  budget: "local",
  quiet: true,
  local: (_t, e, id) => {
    navigate(tutorPath(), e);
    setCursor(ckey(id as string));
    tutor.setDrawer(id as string);
  },
});

// ── starting and answering (each spends a model call) ──

const startable = () => idle();
command({
  id: "tutor.start",
  title: "Start a session on what's typed",
  scope: "tutor",
  budget: "slow-io",
  v1: ["click:start"],
  available: () => startable() && !!tutor.target().trim(),
  local: () => {
    tutor.start(tutor.target().trim());
    tutor.setTarget("");
  },
});
command({
  id: "tutor.retest",
  label: "re-test",
  title: "Re-test me cold on the concept",
  scope: "concept",
  budget: "slow-io",
  keys: ["T"],
  v1: ["click:re-test cold", "click:re-test me cold"],
  available: (id) => known(id) && startable(),
  local: (id) => {
    const c = tutor.concept(id)!;
    tutor.start(`Re-test me cold on ${c.name} [${c.id}]`, c.topics[0]);
  },
});
command({
  id: "tutor.teach",
  title: "Teach me the concept",
  scope: "concept",
  budget: "slow-io",
  v1: ["click:teach me this"],
  available: (id) => known(id) && startable(),
  local: (id) => {
    const c = tutor.concept(id)!;
    tutor.start(`Teach me ${c.name} [${c.id}]: ${c.statement}`, c.topics[0]);
  },
});
command({
  id: "tutor.topic",
  title: "Continue a topic from its weakest concept",
  scope: "tutor",
  budget: "slow-io",
  quiet: true,
  available: (id) => !!id && !!tutor.learn()?.topics[id] && startable(),
  local: (id) => {
    const t = tutor.learn()!.topics[id!];
    tutor.start(`Continue ${t.title} [${t.id}] — start from what my graph says is weakest`, t.id);
  },
});
command({
  id: "tutor.pursue",
  title: "Pursue an open question in a session",
  scope: "tutor",
  budget: "slow-io",
  quiet: true,
  v1: ["click:pursue"],
  available: (id) => !!tutor.learn()?.questions.some((q) => q.id === id) && startable(),
  local: (id) => {
    const q = tutor.learn()!.questions.find((x) => x.id === id)!;
    tutor.start(`My open question: ${q.text}`, q.topic || undefined);
  },
});

/** The answer box's text, rated when the rung asks for it: Enter without a rating flags the chips
 *  once; a second Enter sends without one rather than trapping the answer. */
command({
  id: "tutor.send",
  title: "Send your answer",
  scope: "session",
  budget: "slow-io",
  hint: ["ret"],
  available: () => !!tutor.active() && idle() && !!tutor.draft().trim(),
  local: () => {
    const text = tutor.draft();
    if (tutor.wantsConfidence() && !tutor.confidence() && !tutor.askedConfidence()) {
      tutor.setAskedConfidence(true);
      return;
    }
    if (tutor.answer(tutor.active()!.id, tutor.confidence() ? `${text} (confidence: ${tutor.confidence()})` : text)) {
      tutor.setDraft("");
      tutor.setExpanded(undefined);
      tutor.setConfidence(undefined);
      tutor.setAskedConfidence(false);
    }
  },
});
command({
  id: "tutor.wrap",
  label: "wrap up",
  title: "Wrap up: say each principle plainly, and record my last answer",
  scope: "session",
  budget: "slow-io",
  keys: ["space q"],
  v1: ["click:ask for the consolidation: each "],
  available: () => !!tutor.active() && idle(),
  local: () => void tutor.answer(tutor.active()!.id, "Let's stop here. Consolidate: say each principle we reached plainly, and record evidence for my last answer."),
});
command({
  id: "tutor.stop",
  label: "stop",
  title: "Stop the tutor's turn",
  scope: "session",
  budget: "local",
  keys: ["C-c"],
  v1: ["click:■ stop"],
  available: () => !!tutor.active()?.pendingTurn,
  write: (): Write => ({ ops: [], path: "/tutor-stop", body: { turn: tutor.active()!.pendingTurn }, settled: () => true, failed: "the turn didn't stop" }),
});

// ── the session's page ──

command({
  id: "tutor.write",
  label: "write",
  title: "Write: the answer box, or what to dig into",
  scope: "tutor",
  budget: "local",
  keys: ["i"],
  local: () => {
    if (!tutor.focusBox()) throw new Error("nothing to write in");
  },
});
command({
  id: "tutor.evidence",
  label: "evidence",
  title: "Show what this session recorded about you",
  scope: "session",
  budget: "local",
  keys: ["space v"],
  v1: ["click:what this session has recorded a"],
  local: () => tutor.setEvidenceOpen((v) => !v),
});
command({ id: "tutor.map", label: "map", title: "Show the topic's map", scope: "session", budget: "local", keys: ["space m"], local: () => tutor.setMapOpen((v) => !v) });
command({ id: "tutor.rungs", title: "Show the earlier rungs", scope: "session", budget: "local", local: () => tutor.setHistoryOpen((v) => !v) });
command({
  id: "tutor.rung",
  title: "Open an earlier rung",
  scope: "session",
  budget: "local",
  quiet: true,
  local: (n) => tutor.setExpanded((e) => (e === Number(n) ? undefined : Number(n))),
});
command({ id: "tutor.pin", title: "Show code in the code pane", scope: "tutor", budget: "local", quiet: true, local: (_t, _e, pin) => tutor.showPin(pin as never) });
command({ id: "tutor.option", title: "Put a suggested answer in the box", scope: "session", budget: "local", quiet: true, local: (_t, _e, o) => void (tutor.setDraft(String(o)), tutor.focusBox()) });
command({
  id: "tutor.confidence",
  title: "Rate how sure you are",
  scope: "session",
  budget: "local",
  quiet: true,
  available: (c) => !!c && CONFIDENCES.includes(c),
  local: (c) => tutor.setConfidence((v) => (v === c ? undefined : c)),
});
command({ id: "tutor.due.all", title: "Show everything that's due", scope: "tutor", budget: "local", local: () => tutor.setAllDue((v) => !v) });

// ── sessions you keep (this browser only) ──

const forgetArm = (id: string) => `forget ${id}`;
command({
  id: "tutor.forget",
  label: "forget",
  title: "Forget the session (its evidence stays in the graph)",
  scope: "lesson",
  budget: "local",
  keys: ["X"],
  available: kept,
  route: (id) => (!kept(id) ? null : armed() === forgetArm(id!) ? "tutor.forget.confirm" : "tutor.forget.arm"),
});
command({ id: "tutor.forget.arm", title: "Ready forgetting a session (the next press does it)", scope: "lesson", budget: "local", quiet: true, local: (id) => setArmed(forgetArm(id!)) });
command({
  id: "tutor.forget.confirm",
  title: "Forget a session",
  scope: "lesson",
  budget: "local",
  quiet: true,
  v1: ["click:forget this session (its evidenc"],
  local: (id) => {
    setArmed(undefined);
    tutor.forget(id!);
  },
});
command({
  id: "tutor.pickup",
  title: "Pick up a terminal session here, as a copy",
  scope: "tutor",
  budget: "slow-io",
  quiet: true,
  local: (session) => void tutor.pickUp(session!).catch((e) => tutor.setError(String(e))),
});

// ── the graph's writes ──

function question(op: "close" | "reopen", id: string): Write | null {
  const q = tutor.learn()?.questions.find((x) => x.id === id);
  if (!q) return null;
  return {
    ops: [],
    path: "/learning-question",
    body: { op, id },
    settled: () => true,
    said: op === "close" ? "answered · u undoes" : "reopened",
    failed: `couldn't ${op === "close" ? "close" : "reopen"} the question`,
    inverse: { id: op === "close" ? "tutor.question.reopen" : "tutor.question.close", target: id },
    answered: () => tutor.refresh(),
  };
}
command({ id: "tutor.question.close", title: "Mark the question answered", scope: "tutor", budget: "config-write", quiet: true, v1: ["click:answered"], write: (id) => question("close", id) });
command({ id: "tutor.question.reopen", title: "Reopen the question", scope: "tutor", budget: "config-write", quiet: true, v1: ["click:reopen"], write: (id) => question("reopen", id) });

/** A question of your own about the concept in the drawer: kept open on the graph, then asked in
 *  the session you're in, or a new one on it. */
command({
  id: "tutor.ask",
  title: "Ask the tutor about the concept",
  scope: "tutor",
  budget: "config-write",
  quiet: true,
  v1: ["click:ask"],
  available: (id) => known(id) && !!tutor.question().trim(),
  write: (id): Write => {
    const c = tutor.concept(id)!;
    const text = tutor.question().trim();
    return {
      ops: [],
      path: "/learning-question",
      body: { op: "add", text, concept: c.id, topic: c.topics[0] ?? tutor.active()?.topic ?? "" },
      settled: () => true,
      silent: true,
      failed: "the question wasn't kept",
      answered: (ok) => {
        if (!ok) return;
        tutor.setQuestion("");
        tutor.refresh();
        const msg = `Question about ${c.name} [${c.id}]: ${text}`;
        const s = tutor.active();
        if (s && idle()) {
          tutor.setDrawer(undefined);
          tutor.answer(s.id, msg);
        } else tutor.start(msg, c.topics[0]);
      },
    };
  },
});

const evidence = (id: string) => tutor.learn()?.evidence.find((e) => e.id === id);
command({
  id: "tutor.evidence.edit",
  title: "Correct a credit",
  scope: "tutor",
  budget: "config-write",
  quiet: true,
  v1: ["click:toggle hit / miss"],
  write: (id, arg): Write | null => {
    const e = evidence(id);
    const fields = arg as Partial<Evidence>;
    if (!e || !fields) return null;
    const was = Object.fromEntries(Object.keys(fields).map((k) => [k, e[k as keyof Evidence] ?? ""]));
    return {
      ops: [],
      path: "/learning-evidence",
      body: { op: "edit", id, fields },
      settled: () => true,
      said: "corrected · u undoes",
      failed: "the credit didn't change",
      inverse: { id: "tutor.evidence.edit", target: id, arg: was },
      answered: () => tutor.refresh(),
    };
  },
});
const cutArm = (id: string) => `cut ${id}`;
command({
  id: "tutor.evidence.cut",
  title: "Cut a credit",
  scope: "tutor",
  budget: "local",
  quiet: true,
  route: (id) => (!evidence(id ?? "") ? null : armed() === cutArm(id!) ? "tutor.evidence.delete" : "tutor.evidence.arm"),
});
command({ id: "tutor.evidence.arm", title: "Ready cutting a credit (the next press does it)", scope: "tutor", budget: "local", quiet: true, local: (id) => setArmed(cutArm(id!)) });
command({
  id: "tutor.evidence.delete",
  title: "Cut a credit",
  scope: "tutor",
  budget: "config-write",
  quiet: true,
  v1: ["click:cut this evidence"],
  write: (id): Write | null => {
    setArmed(undefined);
    if (!evidence(id)) return null;
    return { ops: [], path: "/learning-evidence", body: { op: "delete", id }, settled: () => true, said: "cut", failed: "the credit wasn't cut", answered: () => tutor.refresh() };
  },
});
