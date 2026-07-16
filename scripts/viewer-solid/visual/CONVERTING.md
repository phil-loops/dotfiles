# Converting a surface to Tailwind — the rules

The reference conversions are `ServersDrawer.tsx` and `Activity.tsx` (their `.css` files are
deleted). Mimic them exactly. The goal of a conversion commit is **pixel parity**, not redesign.

## Gates (all must pass before commit)

```sh
npx tsgo --noEmit
npm run build
npm run visual:serve        # in another shell, or already running
npm run visual:shot && npm run visual:diff
npm run visual:invariants   # identity facts, not drift — see below
```

`visual:diff` must report every surface under threshold. Sub-threshold text-antialiasing noise
(tens–hundreds of px at DSF2) is acceptable; geometry shifts are not — and the differ enforces
that mechanically: shot-all emits a `<surface>.rects.txt` geometry snapshot (positional paths —
tag + child index — so class renames don't show up) beside every PNG, and diff compares it
**byte-for-byte** against the committed baseline. The pixel threshold absorbs AA noise, which
means it also absorbs small real shifts (a 3px UA border hid under it); the geometry gate is
exact where pixels are fuzzy, so a "passing" pixel diff with rect drift still FAILS. A
deliberate geometry change re-baselines rects the same way as pixels:
`node visual/shot-all.mjs --out visual/baseline --rects-only --only <surface>`.

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
11. **Local CSS-variable aliases don't survive — resolve them.** An old component that locally
    redefined a token (Hearth's `--ember: var(--del)`) gets utilities for what the alias
    *pointed at* (`del`-family), not the token it shadowed. Raw local hexes stay raw arbitrary
    values. Keyframes that referenced local vars get the resolved value hardcoded in `@theme`.
12. **Re-derive old rule-order ties before folding states into classList strings.** Where two
    old rules of equal specificity overlapped, file order picked the winner (NodeSpine's
    `.slot-push` after `.pending`); encode the *winner*, not the naive reading of each class.
13. **`.parent:hover .child` → `group` on the parent + `group-hover:` on the child.**
14. **Utility strings must be literal.** The scanner can't see `stroke-[${VAR}]` — interpolation
    only ever joins whole literal strings (see ForestMap's class helpers).
15. **A CSS variable that parameterizes children is not an alias to resolve** (NextQueue's
    `--nq`): keep it — `[--x:value]` arbitrary properties per state, `text-(--x)` readers.
    Rule 11 is about shadowing aliases, not parameterization.
16. **An entrance animation with a forwards fill forces `!` on later states for that property.**
    Animations outrank normal declarations; the old CSS's `!important`s were load-bearing —
    they survive translation (ForestMap opacity).
17. **`var(--undefined-token)` with no fallback computes to *initial*** — translate to nothing
    and note it in the commit; never substitute a guessed token.
18. **Uncovered components get FORCED-RENDER probes** — seed the state that gates them
    (localStorage anchor, intercepted API response with a synthetic payload) and capture
    before/after geometry + a screenshot; see `visual/probe-reentry.mjs` and
    `visual/probe-diverged.mjs` as templates. Plain `probe-rects` parity is the fallback when
    forcing a render isn't cheap — and the report says which method was used.
19. **Single-side non-solid borders on non-buttons must zero the other sides.**
    `border-dashed` sets border-style on all four sides, and with Preflight off any side
    without an explicit width resurrects the UA `medium` (3px). Buttons are masked by the
    `@layer base` reset; divs are not — `border-t border-dashed` needs `border-x-0 border-b-0`.
20. **Parent-contextual rules can ride the child as an arbitrary variant**
    (`[.epic-subrow_&]:mb-0`) instead of surviving as an index.css shim — keeps extractions total.
21. **`:first-of-type` in legacy CSS gets a dead-or-alive check before translating** — it's
    tag-scoped; translate the computed reality, not the selector's apparent intent.
22. **Passing diffs with more than a few hundred px still get a forced-artifact look**
    (`--threshold 0` + a bbox scan of the diff PNG) — that's what catches a real regression
    hiding under the threshold.
23. **Dead CSS colliding with a live class name is part of the computed reality.** Deleting a
    dead block can silently change a living element that shares the name — probe the merged
    computed style and bake THAT in; an accidental fix is still rect drift. Flag the collision
    for a separate deliberate-fix commit (the `.pr-draft` 820px-box case).
24. **An unlayered legacy rule beats any utility on an already-converted component.** A
    converted file's utility may be a shadowed no-op until the legacy rule dies; on extraction,
    encode the computed *winner*, not the utility that was losing.
25. **Nested hover scopes need named groups** — once an inner element carries `group`, an outer
    wrapper's hover reveal must use `group/<name>` + `group-hover/<name>:`.
26. **Dead-by-order rules get deleted, not kept.** Where an equal-specificity later rule wins a
    tie, the loser is a zombie: probe the computed style to confirm it never applies, then delete
    it in the extraction — left alive, it will beat your utilities the moment the winner converts
    (the gold `.nh-editor-save` that always rendered del-red). Flag the never-rendered intent as
    a deliberate-fix candidate.
27. **`@starting-style` entrance fades translate to the `starting:` variant** (outside the
    keep-list); verify the built CSS emits `@starting-style`.

## Behavior probes — pixels can be green with the feature dead

The pixel/geometry/invariant gates verify a RENDERED STATE; they cannot see interaction.
A conversion that touches a pointer path (drag, hover reveals driving logic, palette
navigation) needs a behavior probe: drive the interaction in puppeteer against a
fixture-server with the network fully owned (hold mutation responses to prove optimistic
paint; capture payloads; never let a POST reach a real server). `behave-focus-drag.mjs`
is the reference (`npm run visual:behave`); it asserts the client contract only — server
reconciliation is out of a CSS conversion's blast radius.

Probe-craft warning from its first run: synthetic pointer events below the viewport fold
silently no-op and read as "feature broken" — that false signal git-bisected cleanly to an
innocent commit that merely made the page taller. A behavior probe must assert its actors
are inside the viewport before concluding anything.

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
re-baseline only on a commit that *deliberately* changes pixels, and re-baseline ONLY the
affected surface: `node visual/shot-all.mjs --out visual/baseline --only <surface>` — a full
re-baseline bakes antialiasing noise into every other surface's reference.

shot-all refuses to run if the server on `--base` is not serving your local `dist/`
(byte-compare of index.html) — that's the guard against gating someone else's build. If it
trips, another checkout's fixture-server owns the port: start yours on a free port and pass
`--base`, don't kill theirs.

**Invariants catch what drift gates can't.** Pixel and geometry gates compare against
baselines shot from *some build* — a defect present when the baseline was made is encoded as
truth and no drift gate will ever flag it (the Fraunces-eyebrow case shipped wrong on arrival;
at 10px letterspaced caps the wrong font is invisible in a reviewed screenshot). `invariants.json`
asserts build-independent identity facts — computed font families and colors per semantic role,
checked on every surface post-clicks. When a conversion establishes a new house truth ("all X
are Y"), add it as an invariant, not a comment.

**A fixture change is a multi-surface re-baseline.** Changing fixture *data* changes pixels on
every surface that renders that data — including surfaces layered above it (the drawer's
backdrop dims the page behind it but doesn't hide it). Enumerate the affected surfaces and
re-baseline all of them in the same commit (the Hearth-tangle fixture invalidated four).
