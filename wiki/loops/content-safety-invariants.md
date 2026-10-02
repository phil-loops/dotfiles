---
title: Invariants of the decision path
section: Content safety
order: 14
project: safety-fixes
lede: Twelve properties every milestone preserves on the path from evidence to gate. A change that breaks one is a design change, not a PR.
---

Part of [[content-safety-epic]]. The loop around the path has its own twelve: [[content-safety-invariants-loop]].

**Evidence and decisions**
1. Every decision is made from a frozen evidence bundle identified by its hash. Detectors accept nothing else.
2. Decisions are append-only rows, separate from signals. No update path.
3. Every decision records rule ids, waiver ids, policy version, thresholds hash, and the legacy verdict during the parallel run.
4. Nothing is written backward; later knowledge is a later entry.

**The model's contract**
5. Observations with quoted evidence, never a verdict. An unresolvable quote rejects the response.
6. `unknown` is always legal and holds only when a rule needs that fact.
7. The model never sees team history, prior verdicts, or overrides.
8. Authorization is computed by code, never asked of the model.

**Policy**
9. Rules are code, thresholds are data, the policy version is the code version.
10. A rule holds first; auto-reject is earned on the holdout and un-earned by its own waiver rate.
11. A hold blocks dispatch exactly as a reject does.
12. An override is scoped, reasoned, attributed, and expiring; it never re-enables a domain and never silences another rule.

Most likely to erode: 10. The first auto-reject without a holdout number always looks obviously safe.
