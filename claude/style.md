# Code Style

**Team style wins.** The loops repo's `AGENTS.md` and `.agents/skills/` are the source of truth for layering, DI/deps shape, comments, naming, and tests — read them there, never restate them here. If a rule here turns out to conflict with repo guidance, the repo is right and this file is stale: delete the local rule. (2026-09-03: this file's typeof-only deps rule contradicted the repo's inline-default-deps convention for over a month.)

Only rules no repo doc carries live here:

- **Inline object-parameter type literals in function signatures** — `function update(input: { id: string; name?: string })`, never a standalone `type UpdateInput = { … }` alias readers must scroll to resolve. Inlining keeps the contract at the call site, even with 5+ fields; `Deps<typeof fn>` / `Parameters<typeof fn>` extract from the function itself, so tests don't break. Don't refactor pre-existing aliases unless asked.
