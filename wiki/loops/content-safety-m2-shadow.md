---
title: M2, run the new judgment in shadow
section: Content safety
order: 40
project: safety-shadow
lede: Freeze evidence, start labeling, and run facts, the claim extractor, and rules beside the classifier, recording every decision and enforcing none.
---

Part of [[content-safety-epic]]. The largest forest; nothing in it changes what a customer sees. A spine from tables to replay, plus the verdict tab as a sibling off the tables node, since labels must start first.

1. **Tables.** Evidence by hash; a signal row per detector run; decisions separate from signals so re-evaluation never overwrites; labels with the ARF feedback type, a fraud assessment, observation corrections, and a holdout split hashed from team and template family.
2. **Evidence bundle.** Pure: compiled HTML and headers in; segments, link table, placeholders, coverage, hash out.
3. **Capture.** Every existing check writes the bundle as a side effect.
4. **Verdict tab.** Three-way verdict on flagged messages, as label rows.
5. **Deterministic detectors.** The fact vocabulary, the detectors, the catalogues.
6. **Claim extractor.** One model call: `claimed_sender`, `sensitive_request`, `payment_request`, each with quoted evidence that code validates. Authorization is computed by code from what is on file. The legacy tag stays as a detector emitting a fact.
7. **Rules.** Functions with ids and a `POLICY_VERSION`; the first set reproduces today's decision, then hold-first rules over the new observations. An `unknown` holds only when a rule needs it.
8. **Shadow decisions.** Same triggers as today, cached by evidence hash, legacy verdict beside the new gate.
9. **Replay.** Script-runner: a candidate over frozen holdout evidence, bare; agreement, block precision with an interval, false blocks per ten thousand, unknown rate. See [[content-safety-measure-bare]].

Done when the two diff lists, newly allowed and newly held, match a reviewer's judgment at an acceptable hold rate. If it mostly holds, M3 waits.
