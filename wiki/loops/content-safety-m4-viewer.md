---
title: M4, the safety viewer and the simulate route
section: Content safety
order: 60
project: safety-viewer
lede: One page per decision, filters across them, a threshold editor, and a way to ask "what would happen if this message were published right now" without publishing it.
---

Part of [[content-safety-epic]]. Rides on M2's decision rows and M3's config table.

**The decision file.** Open any decision and see what the system saw: the evidence segments with the model's quoted spans highlighted in place, the deterministic facts, the three observations, the rules and waivers that fired, the policy version, and the legacy classifier's one-word verdict beside the new gate. A reviewer labels from here. This page is the same view the simulate route renders.

**Simulate.** Pick a message by id or from a team, pick an operation, `campaign.send`, `transactional.publish`, `workflow.start`, or `<type>.preview`, and run. Optional overrides: pretend the team is N days old or has no profile, swap a threshold, disable a rule, or supply sample data variables and a contact to render the hydrated form. The route calls the same safety-check model as production with persistence off and the effects executor stubbed, so nothing is written and nothing is disabled. The model call is cached by evidence hash, so repeated runs on unchanged content are free. Output is the decision file plus a diff against the live decision for that message, if one exists.

**Decisions list.** Filter by team, operation, gate, rule. Per-rule fired counts and agreement with the classifier, which is the number that says a rule is ready to promote.

**Thresholds and rule state.** Edit thresholds, disabled rules, and per-operation mode as versioned config rows, with the previous versions one click away. Each rule shows its state: evidence only, hold, reject, and the precision that earned it.

Done when a reviewer can explain any decision from the page alone, and a developer can answer "what would the system do with this" in one click without touching production state.
