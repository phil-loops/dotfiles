# GitHub → nvim (Chrome extension)

Routes a GitHub PR into the local forest viewer's warm nvim. Backend is the
viewer's `POST /from-github` (import the PR → optionally open a file at a line).
See `../design-github-to-nvim-extension.md` for the full design.

## Status

- **Step 2 (this):** MV3 skeleton + a floating `→ nvim` button that imports the
  current PR and reports the local `review/pr-N` branch. Proves the
  content → background → `localhost:62333/from-github` → git round-trip.
- Steps 3–4 (next): per-file `⬚ nvim` buttons in the diff file headers, and
  ⌥-click on a diff line to open that exact file+line in nvim.

## Load it

1. Make sure the viewer is serving the new endpoint (restart it so `/from-github`
   is live), then smoke-test:
   ```
   curl -s localhost:62333/from-github -d '{"number":"__nope__"}'
   # → {"ok": false, "err": "no pr number"}   (400)
   ```
2. `chrome://extensions` → enable **Developer mode** → **Load unpacked** →
   pick this `gh-to-nvim/` directory.
3. Open any PR on github.com. A `→ nvim` pill appears bottom-right. Click it:
   it imports the PR and flips to `✓ review/pr-<N>` (or `✗ <error>`).

## Notes

- The button is fixed-position on purpose for this step — robust to GitHub's
  virtualized React diff DOM. Precise in-header placement comes with the per-file
  buttons.
- Only `http://localhost:62333` is in `host_permissions`; nothing leaves the
  machine.
