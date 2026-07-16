# stack-branch.* → branch.<b>.stack-* namespace migration

## Why

`stack-branch.<b>.*` lives outside the one config namespace git manages. `git branch -D`
deletes the whole `branch.<b>.*` section (including custom keys — verified empirically,
git 2.x); `git branch -m` moves it. Our keys get neither, so they outlive their branch —
36 dangling keys by 2026-07-16, `stack-doctor --prune` exists only to sweep that rot.
Moving every per-branch key under `branch.<b>.stack-*` makes git GC it for free, kills the
rot class, and shrinks the rename checklist to children's parents + registry entry.

`stack-project.<p>.*` stays — there is no git-managed "project" namespace. Out of scope.

## Key mapping (mechanical: prefix the suffix with `stack-`)

| old                                     | new                                  |
|-----------------------------------------|--------------------------------------|
| `stack-branch.<b>.parent`               | `branch.<b>.stack-parent`            |
| `stack-branch.<b>.requires` (multivar)  | `branch.<b>.stack-requires`          |
| `stack-branch.<b>.project`              | `branch.<b>.stack-project`           |
| `stack-branch.<b>.base`                 | `branch.<b>.stack-base`              |
| `stack-branch.<b>.story`                | `branch.<b>.stack-story`             |
| `stack-branch.<b>.summary`              | `branch.<b>.stack-summary`           |
| `stack-branch.<b>.summary-patchid`      | `branch.<b>.stack-summary-patchid`   |
| `stack-branch.<b>.trunk` (bool)         | `branch.<b>.stack-trunk`             |
| `stack-branch.<b>.gates-green-tree`     | `branch.<b>.stack-gates-green-tree`  |
| `stack-branch.<b>.ambient-ignore` (bool)| `branch.<b>.stack-ambient-ignore`    |

(`stack-branch.<b>.interest` does not exist — a stale comment in stack-review-server.py
claims it; the real key is `stack-project.<p>.interest`. Fix the comment, migrate nothing.)

## Phases (additive lattice; the writer flip is the ONE keystone)

1. **Dual-read, everywhere** — every reader prefers the new key and falls back to the old.
   Dark: nothing writes new keys yet, so behavior is bit-identical. Lands file-by-file,
   lane-by-lane, in any order.
2. **Keystone** — `stack-config-move --apply` sweeps every existing `stack-branch.*` key to
   its new home (idempotent, values verbatim — moving a recorded `gates-green-tree` verdict
   is not forging one), THEN writers flip to the new namespace in the same commit window.
   **Must not run until every reader in every lane is dual-read** — a flipped writer plus a
   legacy-only reader silently loses new branches.
   Keystone checklist beyond the sweep: flip every legacy write/unset (grep `stack-branch`
   across scripts/ — each remaining hit is one); the contract/rewire paths in stack-restack
   and restack-daemon currently READ merged but WRITE legacy (fine dark, shadowed after the
   sweep), and their `requires` rewrite is warn-and-skip on new-namespace keys — both need
   the new-namespace write path in the same window.
   Also (found in the forest-lane dual-read's scratch tests, 2026-07-16): a branch whose
   `.stack-project` tag says `newproj` but whose LEGACY `stack-project.oldproj.branch`
   registry entry survives still seeds `oldproj` — the branch shows in BOTH forests.
   Harmless while writes stay legacy; the sweep must delete the stale legacy registry
   entry in the same pass as the retag, or a retagged branch double-lists post-keystone.
3. **Fallback removal** — after a quiet period, drop the legacy read arms + delete this
   fallback machinery. `stack-doctor --prune`'s stack-branch arm becomes vestigial (keep the
   stack-project arm).

## Canonical dual-read idioms (use these shapes verbatim)

**Bash, single value** (`|| :` where the caller tolerates unset):

    parent=$(git config "branch.$b.stack-parent" || git config "stack-branch.$b.parent")

**Bash, bool**: same shape with `--bool` on both arms.

**Bash, multivar — new wins wholesale, never union** (union double-counts after the sweep):

    reqs=$(git config --get-all "branch.$b.stack-requires") \
      || reqs=$(git config --get-all "stack-branch.$b.requires")

**Bash, enumerator** — normalize both namespaces to `<branch> <value>` lines, new wins
per branch (`!seen[$1]++` keeps the FIRST occurrence, so new lines go first):

    { git config -z --get-regexp '^branch\..*\.stack-parent$' \
        | tr '\0\n' '\n ' | sed -E 's/^branch\.(.*)\.stack-parent /\1 /'
      git config -z --get-regexp '^stack-branch\..*\.parent$' \
        | tr '\0\n' '\n ' | sed -E 's/^stack-branch\.(.*)\.parent /\1 /'
    } | awk 'NF && !seen[$1]++'

    (Scripts that already parse the non-`-z` form may keep their existing sed/awk and just
    add the new-namespace arm first + dedupe — match the file's idiom, keep the ORDER.)

**Python, single value**: read new, fall back to old when empty.

**Python, `--local --list` parser** (stack-forest, srv/review.py sig): match BOTH
`^stack-branch\.(.+)\.(parent|requires|project)$` and `^branch\.(.+)\.stack-(parent|requires|project)$`;
collect into separate dicts, then overlay new onto old per (branch, kind) — for multivar
`requires`, a branch present in the new dict REPLACES its old list, never extends it.

**Section removal** (`stack-rm`, `cw-warm`, `restack-daemon`): keep the legacy
`--remove-section "stack-branch.$b"`, and ALSO unset the new keys — never
`--remove-section "branch.$b"` (that kills description/upstream):

    git config --name-only --get-regexp "^branch\.$(sed -e 's/[.[\\*^$()+?{|]/\\&/g' <<<"$b")\.stack-" \
      | while IFS= read -r k; do git config --unset-all "$k"; done

**Existence probe** (srv/sync.py L682 shape): check new regex first, then old.

## Watch-outs (from the 2026-07-16 inventory)

- Branch names contain dots — every name-extraction must strip the FIXED prefix/suffix
  (`${k#branch.}` + `${k%.stack-parent}`), never split on `.`.
- srv/review.py's `_MODEL_CFG` sig regex must gain the new-namespace alternates or the
  viewer stops repainting on stack config changes after the keystone.
- `stack-doctor` enumerates `^stack-branch\..*\.` generically — needs the new-namespace arm
  for its orphan scan, but its PRUNE arm only ever targets legacy keys (new keys can't
  orphan; git GCs them).
- Test fixtures (`test-stack-bless.sh`, `test-stack-facts.sh`) write legacy keys — leave
  them until phase 3; they double as fallback-arm regression tests.
- Docs to update at keystone time: claude/forests.md (rename checklist, config-keys list),
  .claude/skills/reforest+land-forest SKILL.md.

## Execution ledger (2026-07-16)

- Inventory: ~45 files; enumerators/section-ops listed above are the risky class.
- Lanes: [stack]+[review]+unowned = this session; [forest] (6 scripts) and [viewer]
  (srv/*, stack-review-server.py) get patches/handoff against this doc.
- Dirty files (concurrent WIP — patch protocol regardless of lane): .zshrc, scripts/cw,
  scripts/stack-integrate.
- Tool: `scripts/stack-config-move` (dry-run default; `--apply`; `--check` exits 1 while
  legacy keys remain — the keystone gate).
