---
title: Snowshoe detection
section: Safety loops
order: 160
project: content-fingerprints
lede: One actor spread across many young teams looks harmless one email at a time. The signal is that the pieces are related.
---

**Two layers of evidence.** The *content fingerprint* is an email facet: a pure function of one email, stored once per distinct content as MinHash band keys and a link-destination key. The *content family* is a sender fact derived from those rows: how many other teams, and how many young ones, sent near-identical content or links to the same domains.

**As of the check.** A family fact counts only fingerprints whose content existed before the check, and ages teams at the check's time, so replaying a past check never sees teams that appeared later. Each row is dated by when its content was observed, not when it was written: a backfill dates rows by when the message last changed. Rows carry the fingerprint version, and only rows of the same version are compared. `observeContentFamily` computes it; it is recorded with the decision like any other evidence. Fingerprint rows are append-only, so the count can always be recomputed.

**Facets count, policies decide.** The fact reports counts over fixed windows; how many young teams make a family suspicious is fitted, not set by hand. Other teams' disables and flags count only when they happened before the check.

**Respond to the cluster, carefully.** One false positive must not cascade: a disable raises the evidence against related teams, so the response table holds related young teams for review rather than disabling them. A reviewer judges the cluster once; "a shared agency template" becomes a trusted fact that exempts it, like any per-team exemption.

**Measure on history.** For families formed by a date, compare how often their teams were disabled afterwards with unrelated young teams. `reportContentFamilies` is the first, offline cut.

See [[safety-loops-facets]] and [[safety-loops]].
