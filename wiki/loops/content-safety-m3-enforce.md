---
title: M3, enforce one operation by config
section: Content safety
order: 50
project: safety-enforce
lede: Transactional publish first, hold-first, with the classifier as fallback and a config row as the way back.
---

Part of [[content-safety-epic]]. Starts only after M2's replay passes.

1. **add-the-safety-config-table.** In the safety database ([[content-safety-m-packages]]): append-only rows versioned per key: thresholds, disabled rule ids, per-operation mode of legacy, shadow, or enforce, sampling rates, budgets, model name. Code defaults apply when no row exists. Read through the settings package's injected storage adapter, cached in process for seconds. Never Valkey; the current settings hash is not durable.
2. **gate-transactional-publish-by-safety-mode.** When the mode row for transactional publish is `enforce`, the shadow decision gates: a hold blocks publish and opens a review item, a reject behaves as today's unsafe-content error. Any other mode leaves the classifier in charge. Rollback is the row.
3. **add-the-safety-decision-dashboard.** Per operation: agreement with the classifier, hold rate, unknown rate, p95 latency at publish. A milestone advances when these are flat for a week.

Transactional publish goes first on the assumption that false positives there, a blocked password-reset flow, are the louder pain today. If misses on campaigns are louder, campaign send goes first instead; the mechanism is the same row.

Done when: thresholds change by a config row; every decision is explainable in the admin from facts and quoted evidence; the false-block rate on transactional publish is lower than the baseline from M0, measured on the labeled set and on the override rate; and the queue clears holds faster than the operation creates them. A desk that makes better decisions but can't handle the patients it asks to wait hasn't earned the operation.
