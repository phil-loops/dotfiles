# loops-dev-provenance — agent notes

Curated summary for whoever regenerates `loops-dev-provenance.patch` after drift.
Read this FIRST; when done, rewrite it as a compact summary (curate, don't append forever).

## What the patch does (the contract — keep this, not the exact diff)

Dev-only provenance stamp so the browser proves which checkout a port serves:
every response carries `X-Dev-Worktree: <branch>@<shortsha> <abs worktree path>`,
computed once at server boot. Never ships: it lives ONLY as a working-tree patch
applied by `~/.dotfiles/scripts/loops-provenance`; never commit it to loops.

## Where it lands (as of 2026-08-30)

- `next.config.js` (repo root, CommonJS, `module.exports = nextConfig`).
- Block inserted above `const nextConfig = {`: an IIFE `devWorktreeStamp` —
  `null` when `NODE_ENV === "production"` or git fails; else
  `` `${branch}@${shortsha} ${__dirname}` `` via `execSync` with `cwd: __dirname`.
- Injected into the existing `async headers()` catch-all `source: "/(.*)"` entry,
  spread-prepended before `X-Robots-Tag`:
  `...(devWorktreeStamp ? [{ key: "X-Dev-Worktree", value: devWorktreeStamp }] : [])`.

## Verify after regenerating

```sh
node -e 'process.env.NODE_ENV="development"; require("<dir>/next.config.js").headers().then(h=>console.log(h.find(x=>x.source==="/(.*)").headers[0]))'
```
Expect `{ key: 'X-Dev-Worktree', value: '<branch>@<sha> <dir>' }`. Then regenerate
the patch from a PRISTINE baseline (`git diff next.config.js` with only this change),
confirm `git apply --check --3way` passes on an unmodified checkout, and leave the
target checkout stamped.

## Gotchas

- Detached HEAD → branch reads `HEAD`; fine, the sha carries the identity.
- If `headers()` moves/splits (e.g. next.config.ts, or middleware takes over
  headers), re-anchor to whatever emits the catch-all response headers — the
  header name and value format are the stable contract (whoport greps for them).

## Drift log

- (none yet — patch born 2026-08-30 against wt-114340 @ 31f2d452a3)
