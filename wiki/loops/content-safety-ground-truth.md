---
title: What ground truth is
section: Content safety
order: 46
project: safety-shadow
lede: A versioned rubric applied by people who are measured against each other; the model is scored against the observations, where they agree, not the verdicts, where they sometimes can't.
---

Part of [[content-safety-m2-shadow]]. Companion to [[content-safety-measure-bare]].

**Judge observations, adjudicate verdicts.** The three observations are built to be low-disagreement: what the from-line presents as, whether the reader is asked to supply credentials or data, whether money is requested or redirected, each with a span. The model is measured against those. The fraud verdict is an adjudication; `unknown` is a legal answer.

**Inter-rater agreement is the ceiling.** A random slice of the holdout is labeled twice, blind, by different reviewers. Agreement per observation and per slice is reported beside the model's. A model at 0.91 against a human ceiling of 0.94 is a different finding from 0.91 against 0.80; the second says the rubric is the problem.

**Disagreements write the rubric.** Each double-label disagreement goes to a third reviewer: either one reviewer was right, or the rubric didn't say, and the second kind changes the rubric. Whether "update the card on file" is a sensitive request is settled by sharpening the definition: supplying card details, versus being sent to one's own account page. The rubric is versioned, every label carries its version, and labels under a changed definition are re-adjudicated or excluded.

**Model and humans read the same text.** The rubric's definition of each observation is the one in the model's prompt. When the standard sharpens, both move.

**Reviewers are measured.** Labels carry reviewer, mode (blind or operational), and rubric version. A reviewer often overturned is a calibration conversation.

**Some truth arrives late.** A changed-bank-details message is undecidable from its text. Its verdict stays `unknown`, the policy holds it, and whether the account was compromised is written as a later entry, never backward into what the reviewer knew.
