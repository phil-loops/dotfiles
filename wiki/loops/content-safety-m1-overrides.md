---
title: M1, scoped overrides on the existing classifier
section: Content safety
order: 30
project: safety-overrides
lede: Replace the team-wide skip and the per-message magic string with rows that have a scope, a reason, an author, and an expiry.
---

Part of [[content-safety-epic]]. One spine of four.

Today an admin has two levers: `Team.skipSafetyChecks`, which turns off every check for a team, and writing the string `override` into a message's classification, which also re-enables the domain and skips the banned-word scan. Neither carries a reason or expires, and a domain re-enable rewrites every phishing-tagged message on the team.

1. **add-the-safety-override-table.** Scope of team, domain, or message; the rules waived; reason; author; `expiresAt`; `revokedAt`. Queries and factory.
2. **read-overrides-in-the-safety-checks.** The existing checks consult override rows beside the legacy flag and string. Dual-read, so nothing changes for a team until a row exists.
3. **write-overrides-from-the-admin-router.** The toggle, the message override, and the domain assessment write rows. Re-enabling a domain becomes its own explicit action. Copying a message no longer copies an override.
4. **backfill-legacy-overrides.** A script-runner job turns every existing skip flag and override string into a row, without expiry, source marked legacy.

Done when: a reviewer can waive one check for one team for ninety days with a reason, and the other checks keep running. The legacy fields are removed in a later milestone once the rows have carried production for a while.
