# Code Style

## Layering: queries → models → wiring

Follow a strict layering pattern:

- **Queries** are thin data-access wrappers — one DB call per function, no business logic, no authorization, no cross-table joins or transactions
- **Models** contain business logic with dependency injection — validation, authorization, cross-entity operations, cascading deletes
- **Wiring** integrates models into handlers/routers/jobs — minimal glue code
- tRPC routers, API routes, and job handlers are all **wiring** — they call models, not queries directly
- If a function touches multiple tables, has conditional logic, or does authorization checks, it belongs in models, not queries

## Naming conventions

- **File names** follow the team's kebab-case convention: `goal-contact-window.ts`, not `goalContactWindow.ts`
- **Query imports** use namespace imports with the full descriptive name: `import * as GoalContactWindowQueries from "..."` — not shorthand like `GCWQueries`. In tests the bare function name (`insert`, `findActiveByContact`) is obvious from context, but in model/wiring code the qualified name (`GoalContactWindowQueries.insert`) improves legibility.

## Type style

- **Inline object-parameter type literals in function signatures.** Don't declare a separate named type alias just to name the input shape. Example: `function update(input: { id: string; name?: string })` — not `type UpdateInput = { ... }; function update(input: UpdateInput)`. Standalone aliases pollute the file's mental context: readers have to scroll up to resolve the alias to understand the contract. Inlining keeps the contract at the call site, even with 5+ fields. Test code that uses `Deps<typeof fn>` / `Parameters<typeof fn>` extracts from the function itself, so inline types don't break it. Don't refactor pre-existing standalone types unless asked.

## Comments

**Default to zero comments.** Code carries the *what*; names and types carry intent and shape. A comment is a last resort for a fact none of those can hold — not a companion to the diff. Most commits should add **no** comments; a diff dotted with explanatory prose is the smell this rule exists to kill.

Before writing a comment, it must clear **every** bar — fail any, delete it:

- **Misleading without it, not merely nice-to-have.** Its absence would lead a competent reader to a *wrong change* or a bug. "Helpful context," "for clarity," or restating the obvious does not qualify.
- **Unrecoverable from the code.** If a sharper name, a named constant, or an extracted well-named function would carry the fact, do **that** instead — always. A comment is an admission the code couldn't say it itself.
- **One line.** Needing two-plus lines of prose means the *code* is wrong, not under-documented — restructure (rename, split, introduce a named intermediate) until the note is trivial or unnecessary. A paragraph above a statement is never the answer.

**"Why" is not a license to narrate.** Restating the adjacent code with "so that…" or "because…" bolted on is still narration — the call and the names already show it. A genuine *why* points **outside** this code: an external constraint, a bug being worked around, an invariant enforced elsewhere, a deliberate deviation from the obvious approach. (Narration, delete it: `// disable sole members so the Loops sync stops pushing them`. Why, keep it: `// sole members only — multi-team users get disabled via <other path>; double-disabling races it`.)

Banned outright: restating the next line, section-header comments (`// fetch users`), step-by-step narration of an obvious sequence, and any comment that will silently rot when the code beside it moves.
