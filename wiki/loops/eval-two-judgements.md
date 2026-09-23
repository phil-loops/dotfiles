---
title: Two kinds of human judgement
section: Email safety evaluation
order: 12
project: eval-findings
ask: packages/safety-eval/src/feedback.ts#AssertionLabel
lede: One is durable evidence forever; the other expires the moment the detector answers differently.
---

This distinction took a while to see clearly, and blurring it quietly corrupts every number downstream.

**"Would I have sent this email?"** is a judgement about the email. It is durable — it stays true no matter which detector you run next week, so it is reusable evidence indefinitely. It is pinned to the exact version of the email that was read, because an edited email is a different email and an old verdict must not silently carry over.

**"Was this specific claim the detector made correct?"** is a judgement about one answer. Run the same detector twice and it may word its claims differently; change the prompt and it certainly will. So this is evidence about **that one answer only**.

Scoring a new answer with an old verdict would punish a candidate for fixing the very mistake you flagged. That is why a claim judgement records which evaluation produced the claim and a fingerprint of the claim itself — a candidate's name alone is not enough, because two runs of one candidate differ.

The two also differ in what they feed. Email judgements drive the rules; claim judgements drive the prompt. That split is the whole reason [[eval-replay-asymmetry]] is worth exploiting.

A consequence that took a correction to notice: because email judgements are durable and claim judgements are not, the pool of answers still needing claim judgements **shrinks as you review** unless eligibility is asked separately for each. It is.
