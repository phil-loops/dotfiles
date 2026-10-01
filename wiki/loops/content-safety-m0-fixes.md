---
title: M0, fix the path that exists
section: Content safety
order: 20
project: safety-fixes
lede: Five bugs in the current classifier's input and interpretation, each its own PR, each a false-positive cut with no new system.
---

Part of [[content-safety-epic]]. Five siblings off `main`, no ordering between them.

1. **compile-mjml-before-classifying.** `getMjml` returns the raw MJML source under the name `htmlBody` and the classifier text-converts it. Button links in MJML aren't anchors, so their destinations vanish. Delivery compiles MJML separately. Compile before classifying so the classifier reads what the recipient gets.
2. **stop-doubling-the-from-address-in-hydrated-scans.** Render builds the from address with its domain, then the hydrated scan's formatter appends the domain again. Every async scan today reads `name@domain@domain`.
3. **parse-the-classifier-tag-with-a-schema.** The primary model path returns free text; production blocks anything that isn't exactly one of four strings, so `SAFE` and a trailing newline both block. The shadow pipeline trims and lowercases. One structured tag, one interpretation, shared.
4. **disable-the-failing-domain-on-workflow-start.** Workflow preflight disables the team's first sending domain, not the domain of the message that failed.
5. **uncap-the-delivered-email-count.** The delivered-count query stops at 5,000 rows, so the domain-disable threshold cannot be raised above that without changing the query.

Done when: each lands as a standalone PR; the labeled corpus from M2 is collected against this baseline, not the old one.
