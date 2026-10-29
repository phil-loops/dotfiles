---
title: Domain enforcement
section: Sending domains
order: 20
project: domain-enforcement
ask: models/sending-domain.ts
lede: At any moment we can answer — why can't this team send, who decided that, and what would change it?
---

**The problem.** When a sending domain is disabled, the reason is lost the moment it happens. Detectors flip `SendingDomain.disabled` and log a free-text `disableCriterion` nobody reads; the `DisableDomainEvent` they leave says only "a domain was disabled". Reviewers reconstruct the why from inlined account-limit-notice cards, customers see one generic "contact support", Reenable overrides every flagged email the team ever sent, approving one email re-enables a domain disabled for something unrelated, Unleash grants a permanent exemption, and every ruling overwrites `decision` in place.

The walkthroughs live in Show: `show ~/.dotfiles/show/domain-enforcement-principles.json` (principles, for sign-off) and `show ~/.dotfiles/show/domain-enforcement.json` (MVP and phases). This page is the same design in prose.

## Guiding question

**At any moment we can answer: why can't this team send, who decided that, and what would change it?** Every table, column and feature earns its place by helping answer it — for the reviewer, the customer, or us later. The question is about *standing* state; a one-off rejection of a single send is answered in the error the customer sees.

## Rules

1. **A restriction is a claim with a reason and a decider.** The reason is a category (the kind of problem) and, for an automation, the exact rule; the finding names the specific thing (`email:<id>`, `word:crypto`); the decider is a person or a named, versioned automation. No "admin judgment" reason — a person who blocks says why.
1b. **Policies decide; restrictions record.** A policy changes sending state only by writing a restriction and reads allowances as an input. Enforcement never reads a policy.
2. **The remedy matches the finding.** Restrict and allow at the grain of what was found: a word, an email, the domain's behavior, the team.
3. **A detector's verdict is provisional; a person's is binding.** A person lifts with a verdict (wrong / fixed) and a note, and can leave an allowance so the same finding doesn't restrict again. Allowances expire on their own.
4. **Record what happened once; compute everything else.** Lift and revoke fields are written once; "in effect", the queue and the false-positive rate are queries; `SendingDomain.disabled` is a cache.
5. **Add a concept only when a real case needs it** and restriction, lift and allowance can't express it.

## Three nouns

```prisma
model Restriction {
  id              String    @id @default(cuid())
  createdAt       DateTime  @default(now())
  teamId          String
  sendingDomainId String?   // null = the whole team
  category        String
  ruleId          String?   // an automation's rule
  findingKey      String?   // email:<id> | word:<lowercased>
  deciderKind     String    // person | automation
  deciderName     String    // user id, or "health-cron@3"
  liftedAt        DateTime? // the lift fields are written once
  liftedByUserId  String?
  liftVerdict     String?   // wrong | fixed
  liftNote        String?
}

model Allowance {
  id              String    @id @default(cuid())
  createdAt       DateTime  @default(now())
  teamId          String
  category        String?   // selectors: category + findingKey | ruleId | category | none = all checks
  ruleId          String?
  findingKey      String?
  until           DateTime
  grantedByUserId String
  note            String
  revokedAt       DateTime? // written once
  revokedByUserId String?
}
```

- **Disabled** = the domain or its team has a restriction with no `liftedAt`.
- **A lift** is `UPDATE … WHERE liftedAt IS NULL`; a second lift, or one from a stale page, does nothing.
- **Dedupe:** an automation's repeat claim with the same rule + finding is skipped under a row lock; a person's claim is never deduped against an automation's.
- **The registry** (TS) holds categories and rules — subject, label, the finding type each rule produces. Rule ids are immutable; a rule whose meaning changes gets a new id.

**Allowances are one of three judgments, matched exactly:** this finding was wrong (category + finding, any rule); this rule is wrong for this team (rule); this category is wrong for this team (category). Any matching allowance suppresses; there is no precedence. A finding allowance survives replacing the classifier with new rules; a rule allowance doesn't.

**Not reasons:** classifier `spam` / `safe` (accepted today), mail-smell (rejects creation — a one-off), Apple Private Relay notices, the volume/age gate (decides whether a claim restricts), facets (evidence until a rule uses them).

## Phases

1. **Restrictions (MVP).** The table and registry; every disable site records a restriction with category, rule, finding and decider (SES, signup patterns and deletion restrict the team; a new domain under a restricted team starts disabled); every enable is a lift; admins pick a category when blocking; the review page shows what's keeping a domain disabled; approving an email lifts only that email's restrictions, and a domain disabled before phase 1 needs a real review. `DisableDomainEvent` is still written on a flip, as history.
2. **Lift verdicts and allowances.** The lift dialog (wrong / fixed + optional allowance, narrowest first); automations check allowances; allow a banned word for a team.
3. **Notes and snooze**, when the queue needs them; the account-limit-notice chart.
4. **One entry point for detectors** (`enforce` = policy decide + write restrictions); evidence linked; `handleDisableNewDomain` deleted.
5. **Customer surfaces** worded by subject.

Later, when a case needs it: content holds by content hash, team publishing blocks, idempotency keys, policy replay, retiring `safetyClassification = "override"`.

## Open

- Default allowance length per category.
- Is `DISABLE_SPAMMY_SENDING_DOMAINS` on in prod? It re-disables on every cron run today.
- After a team is hard-deleted, does its enforcement history survive (abuse record) or go (privacy)?
- How much to tell customers about content flags.
