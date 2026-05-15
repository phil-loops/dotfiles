---
name: trpc-patch
description: Apply or remove the @trpc/server type patch in the loops repo to make tsgo type-checking ~1500x faster. The patch collapses the `Serialize<...>`/transformer conditional in `inferTransformedProcedureOutput` (loops always uses superjson, so the conditional is dead weight). Use when the user says "patch trpc", "unpatch trpc", "apply trpc patch", "speed up tsgo", "restore trpc types", or asks about tRPC type-check perf. Source: PR Loops-so/loops#8406.
---

# tRPC Server Type Patch

Toggles a patch on `node_modules/@trpc/server/dist/unstable-core-do-not-import.d-*.{d.mts,d.cts}` that collapses the bloated `Serialize<inferProcedureOutput<...>>` conditional. The patch is applied directly to `node_modules` — it does **not** modify `package.json` or add `patch-package`. It is volatile: any `npm install` or `task npm:install` will undo it, and the user must re-run the skill.

## When to use

- "Patch trpc" / "Apply the trpc patch" → action = `apply`
- "Unpatch trpc" / "Remove the trpc patch" / "Restore trpc types" → action = `remove`
- "Is the trpc patch applied?" → action = `status`
- The user reports tsgo / tsc is unbearably slow on loops and hasn't applied this yet
- After running `npm install`, when the user wants to re-apply

If the user's intent is ambiguous (just says "trpc patch"), check current state first (status) and ask which action they want.

## Repo + version preconditions

This skill is loops-specific. Before doing anything:

1. **Verify cwd is the loops repo.** Check `package.json` exists and `"name": "loops"`. If not, stop and tell the user.
2. **Verify tRPC version is `11.16.0`.** Read `node_modules/@trpc/server/package.json`. The patch is keyed to this version's hashed dist filenames (`unstable-core-do-not-import.d-Bl-_61JQ.d.mts` and `unstable-core-do-not-import.d-Dm2ii-ih.d.cts`). If the version differs, stop and tell the user — the patch needs to be regenerated against the new version (see "Regenerating" below).
3. **Verify both target files exist** under `node_modules/@trpc/server/dist/`. If either is missing, the install is incomplete — tell the user to reinstall first.

## Detecting current state

The patched line in either `.d.mts` or `.d.cts` looks like:

```
type inferTransformedProcedureOutput<TInferrable extends InferrableClientTypes, TProcedure extends AnyProcedure> = TProcedure extends { _def: { $types: { output: infer O } } } ? O : never;
```

The unpatched line contains `inferClientTypes<TInferrable>['transformer'] extends false ? Serialize<...>`.

Quick check:

```bash
grep -qF 'TProcedure extends { _def: { $types: { output: infer O } } } ? O : never' \
  node_modules/@trpc/server/dist/unstable-core-do-not-import.d-Bl-_61JQ.d.mts \
  && echo patched || echo unpatched
```

Use `grep -F` (fixed string) — the `?` in `? O : never` is a regex metacharacter and `grep` without `-F` will silently miss the match. The `inferProcedureOutput` line contains the same pattern, so this single grep is sufficient.

## Apply

From the loops repo root:

```bash
patch -p1 -N --dry-run < ~/.claude/skills/trpc-patch/trpc-server-11.16.0.patch \
  && patch -p1 -N < ~/.claude/skills/trpc-patch/trpc-server-11.16.0.patch
```

- `-p1` strips the leading `a/` so paths land on `node_modules/...`.
- `-N` (`--forward`) means "skip hunks that look already applied" — safe to run twice.
- Run the `--dry-run` first to surface failures cleanly before mutating anything.

If the dry-run fails with "Reversed (or previously applied) patch detected", the patch is already applied — report that and stop.

## Remove

From the loops repo root:

```bash
patch -p1 -R --dry-run < ~/.claude/skills/trpc-patch/trpc-server-11.16.0.patch \
  && patch -p1 -R < ~/.claude/skills/trpc-patch/trpc-server-11.16.0.patch
```

- `-R` reverses the patch.
- If the dry-run fails, the patch wasn't applied — report that and stop.

A clean alternative if `patch -R` fails for any reason: `rm -rf node_modules/@trpc/server && npm install` will restore the upstream files (heavier but bulletproof).

## Reporting back

After any action, tell the user:

- What state we started in (patched / unpatched)
- What action ran
- What state we ended in (verify with the grep above)
- Reminder if applied: "This is volatile — `npm install` will undo it."

Keep it to 2-3 lines.

## Regenerating the patch (rare)

If tRPC bumps to a new version, the dist filenames will change (the hash component) and this patch will not apply. To regenerate:

1. Find the new dist filenames: `ls node_modules/@trpc/server/dist/ | grep unstable-core`
2. Apply the same two edits manually (`inferProcedureOutput` and `inferTransformedProcedureOutput`)
3. Run `git diff` from inside `node_modules/@trpc/server/dist/` (after `git init` there if needed) — or just author the unified diff by hand using the existing patch as a template
4. Save the new patch alongside this skill, and update the version + filenames referenced above

The transform itself doesn't change between versions — just the line numbers and dist hashes.
