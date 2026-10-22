---
title: One store, pushed changes, optimistic commands
section: Canopy v2
order: 52
project: canopy-v2
lede: The client holds the world locally and changes it first; the server confirms behind it. Views are projections of the store, never fetch waterfalls.
---

**1. One local store of the world.** Forests, branches, commits, PRs, gates, the words — hydrated once from a `/state` snapshot into normalized entities every view shares.

**2. The server pushes what changed, by domain.** The server already computes separate fingerprints per change domain: refs, config, PR state, gates, worktrees ([[viewer-derived-state-domains]]). The event stream sends *which entities changed* in each domain. The client patches only those, replacing today's "something changed, refetch 13 queries". Diff text and file sources stay lazy, cached by tree SHA.

**3. Every mutation is an optimistic command:**

- apply locally in the same frame;
- post in the background;
- reconcile when the server confirms;
- roll back with a quiet note on refusal.

Commands queue, so archiving five forests in a row is five keystrokes with no waiting. Each command declares what it touches, so the store knows what to reconcile.

**4. Prefetch on intent.** Hovering a branch, or the cursor landing on it, warms its diff and cold endpoints (`/model`, `/push-preview` take 2.5 s cold). By the time you open it, it's there.

**5. Keep what works:**

- Solid.js (fine-grained reactivity suits a live store);
- Tailwind and the vellum/gold design tokens;
- the Python server, its git logic, and every mutating endpoint.

The rewrite is the client, plus two server additions: `/state` and domain-diff events.

**Budgets enforced in CI-style checks:**

- navigation ≤ 100 ms to meaningful paint;
- action feedback ≤ 16 ms;
- initial bundle ≤ 250 KB gzipped;
- fonts self-hosted.
