---
title: The MVP and the projects
section: Safety loops
order: 140
project: phishtank-v4
lede: First prove the new system reproduces production exactly, live and on history. Then add facets, then candidates.
---

**The MVP proves parity.** `phishtank-v4` holds the package, the legacy-tag facet and an exact copy of production's banned-word scan, plus `policyV0`, a replica of today's decision. It runs in the existing shadow evaluation with no model call: every live check records v0's decision beside production's, read from production's recorded output. A report shows agreement and every mismatch by cause. The target is 100%.

**The offline replay** (`parity-replay`) does the same over stored history, by date range. Use windows after the last change to the check code (late June 2026); start with a day, then a week. The banned-word list has no change log, so its history is rebuilt from the admin ledger and checked against the snapshots stored with banned-word hits. Models are never re-called: replay reads recordings.

**Then, in order.** `phishtank-facets` (helpers, code facets, segmenter, model readings, fingerprints), then `readings-shadow` (the readings pipeline beside every live check), then candidates fitted offline.

**Promotion.** A frozen candidate runs live in shadow for at least a week and until enough differences in each direction are reviewed. Exit conditions are written before it starts: no confirmed harmful email newly allowed, wrongly blocked mail within tolerance, no errors or latency problems.

**Shelved.** `shadow-observations` used the earlier quote-based design; kept for reference only.
