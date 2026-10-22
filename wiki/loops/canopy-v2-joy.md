---
title: What makes it feel good
section: Canopy v2
order: 54
project: canopy-v2
lede: Joy is mostly the absence of friction — then a few moments that are crafted on purpose.
---

**Calm by default.** The page at rest shows titles and one action each. Metadata comes on hover, focus or selection. One accent color (gold) means "you can act here"; ember means "the clock matters"; red only means something broke.

**Motion that explains.** Short, springy transitions (150–200 ms) that show where things went:

- archiving slides the row down into the archive count;
- focusing lifts it into the focus lane;
- a pushed branch's row settles into "in review".

Motion never delays an action; it plays while the next keypress is already accepted. `prefers-reduced-motion` turns it off.

**Moments worth crafting:**

- A forest whose last PR lands gets a brief "canopy closed" flourish before it folds away.
- The first green gate on a branch, and a clean push, each get a small, satisfying confirmation instead of a toast.
- The words column shows your edited subject settling into the "lands on main as" title as you type.

**Typography and space.** Keep Fraunces for display and the mono for metadata, but give reading more room: a comfortable diff measure, generous line height, and one consistent spacing scale (4 px base). Fonts are self-hosted, so the page never reflows when they arrive.

**Never punish.** No dead ends, no "are you sure" dialogs (undo instead), no spinners without words, no layout shift. If something fails, say what to do next in one line.
