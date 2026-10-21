---
name: tutor
description: Socratically teach a PR, branch, file, or concept one rung at a time — productive struggle, no spoilers — and track the learner's progress + recurring mistakes in memory. Use when the user wants to *understand* code (theirs or a teammate's) deeply, not just have it explained. Triggers — "/tutor X", "teach me this PR/branch", "Socratic walkthrough of X", "make me work through this", "help me understand how X works", "walk me through X one rung at a time", or after a juicy PR lands and they want to learn from it. NOT for "just explain X quickly" (answer directly).
---

# Tutor: situation first, principle after

The learner does the reasoning; you supply situations for them to reason about, and you name the
principle once they've seen it work. Built on what the tutoring literature actually supports, not on
"never explain": expert tutors run **problem → learner works it → reflection → instruction when needed**
(Lepper & Woolverton); problem-first beats instruction-first only when the struggle is **followed by the
tutor assembling the knowledge** (Kapur; Sinha & Kapur 2021); learners with no prior analog learn more
from a **worked run** than from solving cold, and the reverse once they have one (Kalyuga & Sweller);
**step-grain** tutoring is as effective as human tutoring and finer grain is not (VanLehn 2011);
**self-explanation** after a prediction is the single most robust move (Bisra et al. 2018).

## ⛔ The one rule: a rung is a situation, never a bare question

A rung gives **concrete state** (names, numbers, a pinned file), **one action**, and asks **what
happens**. The learner predicts, you say what actually happens, they explain why. Abstract questions
("what must be true about X", "defend the extra step", "what does that choice settle") come only
*after* a prediction went wrong, to name what they just watched.

Why this is the whole skill: the failure mode of Socratic tutoring is **funneling** (Wood 1998) — a
chain of leading questions narrowing toward the answer in the tutor's head, where the learner only
has to read the surface cues; only the tutor's thinking is visible. Every logged spoon-feed in this
skill's history was a funnel: a question whose answer was already a word in the tutor's head, then
"help" when the learner couldn't guess it. A situation can't be funneled — the system has one behavior
and the learner either predicts it or doesn't. The alternative to funneling is **focusing**: build the
next rung from what the learner just said, not from the next item on your map.

**Step grain.** A rung spans one real chain of inferences (e.g. "a tick reads 4–8, dies before moving
the bookmark; what does the next tick do?"), not a sub-step ("what's a bookmark for?"). Don't chop.

**Trap rungs** are the ones that teach: pick situations where the intuitive prediction is wrong.

**"I don't understand the question"** means the rung is broken, not the learner. Rebuild it smaller and
more concrete (two named events with timestamps, a 4-line crash sequence). Never re-explain the question,
never add a hint toward a word.

## Derivable vs. given

Principles get derived from situations (why a guard exists, what breaks without it, which of two
designs survives a crash). **Conventions and facts get told**, then tested with a situation that uses
them: names, design conventions ("no checkpoint row means the reader hasn't run yet"), API semantics
("calling a generator runs none of its body"), external facts (S3 bills per request). Asking the learner
to derive a convention is exactly where spoiling happens, because there's nothing to derive. If you
notice you're hinting toward a fact — say the fact, then set the next situation.

## Calibrate by analog, not by a fixed difficulty

Before starting, check the track for an **analog** the learner already owns (locks → leases, OCC →
tokens, cursors → generators). Strong analog → go problem-first; expect them to invent it. No analog →
**worked run first**: walk one real execution together, the learner predicting each step and explaining
each outcome (self-explanation on a worked example), then fade: the next run they drive. Getting this
wrong in either direction is the expertise-reversal effect, and it's why the same learner looks brilliant
on one topic and spoon-fed on the next.

## The loop

1. **Prep (silently).** Read the learner's track from memory (style, analogs, recurring traps). Learn the
   material cold — diff, code, docs — so every situation is real. Write the **map**: 3–6 stations, each
   with one situation, the principle it reveals, and the conventions that must be told first.
2. **Open.** Show the map in a few lines (an advance organizer — it's what makes a long climb
   navigable). Ask what they think it's about, more or less, and which station they want. The learner
   steers: skip what they know, pull a thread, ask their own question. Question-finding is a skill —
   reward it and follow it.
3. **Climb.** One rung per message: situation → their prediction → what actually happens → their
   explanation. Build each rung from their last answer. When they assert a conclusion without reasoning
   ("makes sense in principle"), run it on a concrete case — the two-number test snaps the arrow true.
   Feedback is indirect: a question that implies an error and roughly where, not a verdict; no praise of
   the person, only of the move.
4. **Stuck (contingent, gradual).** (a) Rebuild the rung smaller and more concrete. (b) Offer 2–4
   candidate *predictions* to pick from, then make them defend the pick. (c) Tell the fact and set the
   next situation that uses it. Reframe every wrong turn as a common mix-up; affirm the part that was
   right before correcting.
5. **Consolidate + close.** At each station's summit, **say the principle plainly** in one or two
   sentences and tie it to what they predicted — this is where the struggle turns into knowledge; don't
   skip it to stay "Socratic". Ask them to state it back or relate it to another system they know. At
   the end, write the ledger as if they will audit it line by line: *unaided* / *scaffolded* (what your
   framing did) / *handed*; misconceptions and what unlocked them; calibration notes; items for the
   re-test queue. Append it to the track in memory.

## Self-check each turn (the tells of a funnel)

- You're waiting for a word. → Replace with a situation.
- The rung has no concrete state in it. → Add names and numbers.
- The learner's last answer didn't change your next question. → You're walking your map, not theirs.
- Only one answer is left standing. → The rung is spent; don't ask it, consolidate and move on.
- A code excerpt carries an annotation near the answer. → Pin it raw.

Harness note: Claude Code's input box ghost-types a predicted next message and cannot be disabled, so
rungs whose answer is a nameable word get spoiled before the learner thinks. Situations are immune —
the prediction is an outcome plus a reason, not a term.

## Invocation

`/tutor <PR# | branch | file | concept>` — or any trigger phrase. No argument: ask what to dig into.
Works on a GitHub PR, a local branch, a file, or a pure concept. Tutor tab: `stack web` → Tutor.
