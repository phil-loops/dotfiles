import { test } from "node:test";
import assert from "node:assert/strict";
import { askOf, latest, questionOf, rungsOf, segments, sseFrames } from "./lesson.ts";

const turn = [
  "Here is the setup.",
  "```tutor-rung",
  '{"concept": "cursor-redelivery", "level": "predict", "rung": "predict", "confidence": true}',
  "```",
  "```tutor-pin",
  '{"path": "scripts/srv/chat.py", "ref": "origin/main", "lines": [428, 470]}',
  "```",
  "The tick dies after 8. What does the next tick read first?",
  "```tutor-options",
  '["4–8 again", "9 onward"]',
  "```",
].join("\n");

test("a turn splits into prose and the blocks the page draws", () => {
  const kinds = segments(turn).map((s) => s.kind);
  assert.deepEqual(kinds, ["prose", "rung", "prose", "pin", "prose", "options"]);
  const pin = segments(turn).find((s) => s.kind === "pin");
  assert.deepEqual(pin, { kind: "pin", pin: { path: "scripts/srv/chat.py", ref: "origin/main", lines: [428, 470] } });
  const rung = segments(turn).find((s) => s.kind === "rung");
  assert.equal(rung?.kind === "rung" && rung.confidence, true);
});

test("a fence still streaming in is held back, never shown as JSON", () => {
  const half = 'Setup.\n```tutor-evidence\n[{"concept": "x", "lev';
  assert.deepEqual(segments(half), [{ kind: "prose", text: "Setup.\n" }]);
});

test("a fence that isn't JSON stays prose; calibration is quiet", () => {
  assert.equal(segments("```tutor-pin\nnot json\n```")[0].kind, "prose");
  assert.equal(segments('```tutor-calibration\n["slow down"]\n```')[0].kind, "quiet");
});

test("a folded rung shows the question it asked; the card shows its paragraph", () => {
  assert.equal(askOf(turn), "What does the next tick read first?");
  assert.equal(questionOf("Intro.\n\nSo: what happens **next**?\n\n"), "So: what happens next?");
});

test("rungs pair each tutor turn with the answer after it; latest finds the newest block", () => {
  const msgs = [
    { role: "tutor" as const, text: turn },
    { role: "me" as const, text: "9 onward" },
    { role: "tutor" as const, text: "Not quite." },
  ];
  assert.deepEqual(rungsOf(msgs), [
    { n: 1, tutorIdx: 0, answer: "9 onward" },
    { n: 2, tutorIdx: 2, answer: undefined },
  ]);
  assert.equal(latest(msgs, "rung")?.concept, "cursor-redelivery");
  assert.equal(latest(msgs, "map"), null);
});

test("server-sent frames come off whole; a partial one waits", () => {
  const { frames, rest } = sseFrames('event: token\ndata: {"t":"a"}\n\n: ping\n\nevent: done\ndata: {}\n\nevent: tok');
  assert.deepEqual(frames, [
    { event: "token", data: '{"t":"a"}' },
    { event: "done", data: "{}" },
  ]);
  assert.equal(rest, "event: tok");
});
