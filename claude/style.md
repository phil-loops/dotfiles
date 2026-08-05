# Code Style

## Layering: queries → models → wiring

- **Queries** are thin data-access wrappers — one DB call per function, no business logic, no authorization, no cross-table joins or transactions
- **Models** contain business logic with dependency injection — validation, authorization, cross-entity operations, cascading deletes
- **Wiring** (tRPC routers, API routes, job handlers) integrates models — minimal glue; it calls models, never queries directly
- A function that touches multiple tables, branches, or authorizes belongs in models, not queries

## Naming conventions

- **File names** follow the team's kebab-case convention: `goal-contact-window.ts`, not `goalContactWindow.ts`
- **Query imports** use namespace imports with the full name: `import * as GoalContactWindowQueries from "..."` — never shorthand like `GCWQueries`. Bare function names are fine in tests where context is obvious; model/wiring code uses the qualified name.

## Type style

- **Inline object-parameter type literals in function signatures** — `function update(input: { id: string; name?: string })`, never a standalone `type UpdateInput = { … }` alias readers must scroll to resolve. Inlining keeps the contract at the call site, even with 5+ fields; `Deps<typeof fn>` / `Parameters<typeof fn>` extract from the function itself, so tests don't break. Don't refactor pre-existing aliases unless asked.
- **A deps parameter needs only the `typeof`, never the value.** Type each dep `typeof realFn` with `import type`; make `deps` required and let wiring pass the real implementations. Never default a deps object to the real functions when that default is the only thing forcing a runtime import — it couples heavy modules and invites cycles (sesUtils once pulled in transactionalEmails just to name a default); `import type` erases the edge. Exception: a same-module thin default-deps wrapper (the script-runner pattern) — there the wrapper IS the wiring.

## Comments

**Default to zero comments.** Code carries the *what*; names and types carry intent and shape. Most commits add **no** comments — a diff dotted with explanatory prose is the smell this rule exists to kill.

A comment must clear **every** bar — fail any, delete it:

- **Misleading without it** — its absence would lead a competent reader to a wrong change or a bug; "helpful context" doesn't qualify.
- **Unrecoverable from the code** — if a sharper name, a named constant, or an extracted function would carry the fact, do that instead, always.
- **One line** — two-plus lines of prose means the *code* is wrong, not under-documented; restructure until the note is trivial or unnecessary.

**"Why" is not a license to narrate.** Restating the adjacent code with "so that…" / "because…" bolted on is still narration. A genuine *why* points **outside** this code: an external constraint, a bug worked around, an invariant enforced elsewhere, a deliberate deviation from the obvious approach. (Narration, delete: `// disable sole members so the Loops sync stops pushing them`. Why, keep: `// sole members only — multi-team users get disabled via <other path>; double-disabling races it`.) Banned outright: restating the next line, section headers (`// fetch users`), step narration, anything that silently rots when the code beside it moves.
