---
name: retest
description: One-minute spaced re-test from the learner's concept graph — pose ONE situation on the top due concept, take the prediction and confidence, say what really happens, record the evidence. Use on "/retest", "/retest <system>", "quiz me", "re-test me", or when Phil accepts a re-test offered after a learning nudge. NOT a tutoring session (that's /tutor) and never offered mid-task.
---

# Re-test: one situation, one row

The graph only knows Phil retains something when he shows it **unaided, days later**. This skill is
the cheapest way to produce that evidence: one situation, about a minute, then back to work.

## Steps

1. **Pick.** `learn retest` (or `learn retest --system <id>` when one was named; skip this if the
   nudge already ran `learn retest --claim` and you have the brief). `"due": 0` → say nothing is due
   and stop.
2. **Build one situation** from the brief, in the tutor's situation shape: concrete state (real names,
   numbers, timestamps like t=0 / t=5 / t=30), one action, "what happens?".
   - Use real Loops code: open the concept's `code` refs, or the code of the system its `standards`
     belong to. Never a toy example.
   - Open miss with a `contrast` → the situation **is** the contrast. Open miss without one → the
     situation that would have exposed the miss (`history` says what he believed).
   - A `held_analogs` entry → you may pose it in that analog's setting instead; that row is a
     transfer, with `via`.
   - Never name the concept, its principle, or a hint in the question.
3. **Ask for the prediction and his confidence (low / medium / high) in one line, then STOP.** Wait.
4. **Reveal and consolidate in 2–3 lines:** what actually happens, the principle in one sentence, and
   on a miss the one variable that separates his model from the real one.
5. **Record** one row (two if you asked a single "why?" and he explained):
   `learn evidence '<json>' --session retest:<YYYY-MM-DD>`
   - `concept`, plus `standard` when the situation exercised one of the brief's standards.
   - `level`: predict (explain only for an answered "why?"; transfer when posed through an analog).
   - `credit`: unaided unless you hinted — any hint is scaffolded, telling him is handed. Under-claim.
   - `outcome`, `confidence`, a short `note` in plain words of what he said, and on a miss a
     `contrast` for next time.
6. **Offer "another?" once.** A yes repeats from step 1; anything else ends it.

## Don'ts

- Don't offer it in the middle of Phil's task, and drop it for the session if he declines.
- Don't chain into teaching. A miss gets the 2–3 line consolidation and a contrast for the next
  re-test, not a lesson; offer `/tutor <topic>` if he wants depth.
