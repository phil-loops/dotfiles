---
title: Content safety, the epic
section: Content safety
order: 10
project: safety-fixes
lede: Facts from code, a model that observes rather than judges, rules in TypeScript, and every decision stored so a human verdict becomes a label.
---

Today's check is one prompt returning one word; `phishing` blocks. Nobody can see why, and the only override turns the check off for a whole team. Four milestones replace it, each a forest, each shippable alone.

**The shape.** A frozen evidence bundle per message, hashed. Deterministic detectors turn it into facts: link text versus href, confusable hosts, free-mail reply-to, hidden text, forms, cross-team reuse, feed hits. One model call observes three things with quoted evidence: the claimed sender, a request for credentials or personal data, a request for money or a change in where it goes. Code decides whether the claim is authorized from what is on file. Rules in code compose facts with team context into allow, hold, or reject. Thresholds live in a versioned Postgres table. Every decision records the rules, waivers, and version that produced it.

**The discipline.** A model field exists only if a rule reads it. An `unknown` holds only when a rule needs it. Rules hold first and earn automatic reject on a labeled holdout. Overrides waive one rule for one scope, with a reason and an expiry.

**Milestones.** [[content-safety-m0-fixes]] cuts false positives on the existing path. [[content-safety-m-packages]] adds the packages and their own database. [[content-safety-m1-overrides]] gives the queue scoped overrides. [[content-safety-m2-shadow]] runs the new judgment beside the old and replays a labeled corpus. [[content-safety-m3-enforce]] enforces transactional publish by a config row.

**Not here.** Fingerprint families, the campaign ramp, the render-time delta path, team profiles; each earns a milestone from shadow data. Full design: `~/daily-log/2026-09-30-content-safety-redesign.md`. The shelved `eval-findings` and `safety-facets` forests were earlier passes.
