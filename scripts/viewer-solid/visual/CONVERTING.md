# Converting a surface to Tailwind — the rules

The reference conversions are `ServersDrawer.tsx` and `Activity.tsx` (their `.css` files are
deleted). Mimic them exactly. The goal of a conversion commit is **pixel parity**, not redesign.

## Gates (all must pass before commit)

```sh
npx tsgo --noEmit
npm run build
npm run visual:serve   # in another shell, or already running
npm run visual:shot && npm run visual:diff
```

`visual:diff` must report every surface under threshold. Sub-threshold text-antialiasing noise
(tens–hundreds of px at DSF2) is acceptable; geometry shifts are not — if a diff PNG shows a
*layout* move, fix it, don't rationalize it.

## Rules

1. **Exact values, not grid-snapping.** Old `padding: 3px 11px` → `px-[11px] py-[3px]`, never
   `px-3 py-1`. Old `font-size: 13.5px` → `text-[13.5px]`. Snapping to the 4px grid is a later
   taste pass, done deliberately — parity commits keep the old metrics.
2. **Never named text sizes.** `text-xs` injects a line-height; the legacy CSS almost never set
   one. Always `text-[Npx]` and let line-height inherit — unless the old rule set line-height,
   then add `leading-[...]` explicitly.
3. **`font: inherit` on old buttons means `leading-[1.55]`.** The `@layer base` button reset
   pins `line-height: normal` (UA value). Any old rule that had `font: inherit` on a button was
   inheriting the body's 1.55 — add `leading-[1.55]` or the element shrinks ~3px.
4. **Marker classes stay.** Keep the old semantic class names (`activity-row`, `card`,
   `servers-drawer`, …) as inert markers alongside utilities — the visual harness, tests, and
   grep depend on them. They carry no styles once the CSS file is gone.
5. **Ledger colors only.** The stock palette is disabled (`--color-*: initial`); everything is
   `text-ink-dim`, `border-rule`, `bg-vellum-raise`, etc. Raw rgba only via arbitrary values for
   shadows/washes that were already raw in the old CSS.
6. **Keyframes move to `@theme`** as `--animate-<name>` (see `breathe`); use
   `animate-<name> motion-reduce:animate-none`. Do NOT inline `@keyframes` in component files.
7. **Repeated intra-component bundles become local consts** (`BTN`, `ROW`) in that component
   file. No shared ui library, no cross-file abstractions — co-location beats DRY here.
8. **State variants via `classList`** with whole utility strings per state (see the HEALTH map).
   Never stack conflicting utilities (`border-rule border-del`) — the generated order, not the
   class order, would decide the winner.
9. **Delete the component's `.css` file and its import in the same commit.** A conversion that
   leaves the old file half-alive is worse than no conversion.
10. **Solid, not React**: `class=`/`classList=`, `<Show>`/`<For>` — don't let Tailwind examples
    drag `className` in.

## Keep-list — never convert these

- The foil-sweep bless choreography (`.entry.foil` block in `index.css`)
- The diff2html re-tint block (`.d2h-*` rules in `index.css`)
- The unfold grammar (`.nh-strip`/`interpolate-size` block in `index.css`)
- Anything driving third-party DOM (d2h, marked-rendered markdown)

These are art-directed set pieces; utilities can't express them and the pixel differ can't
fully check them (animations are frozen in shots).

## Adding a surface to the harness

New/changed interactive flows need a `surfaces.json` entry (route + clicks + waitFor on marker
classes). Re-record fixtures only when an API shape changes (`--record` against a live server);
re-baseline (`--out visual/baseline`) only on a commit that *deliberately* changes pixels.
