---
title: The two throttles
section: Stores
order: 26
ask: lib/mail-send-tokens.ts
lede: Valkey — a global token balance, and a per-team sliding window.
---

**`low-tokens`** is a single global integer: the allowance low-priority mail may spend. It is [scaled by 1000](src:lib/mail-send-tokens.ts#LOW_PRIORITY_TOKEN_SCALE) so it can be adjusted in fractions without floats.

It is funded by transactional health. Every send inside the SLA deposits a little; every send that misses [multiplies the balance by 0.9](src:lib/mail-send-tokens.ts#DECREASE_LOW_PRIORITY_TOKENS_SCRIPT). Decay is a Lua script rather than a read-modify-write for the same reason the peek is — see [[hop-peek]].

**`scheduled-rate:<teamId>`** is the other axis: a rolling one-second log, member = email id, score = when it was scheduled.

Why a log rather than a counter? A counter with a one-second expiry gives you **fixed** windows, and fixed windows leak: 1,000 sends at 0.99s plus 1,000 at 1.01s is 2,000 in 20ms, both "legal." Scoring each id by its own timestamp makes the window **slide** — trim everything older than a second and what remains is, exactly, the last second. Any 1,000ms interval you pick holds at most the cap.

Both are read and written inside the same script that does the peek, because a check-then-act split across replicas would let two workers spend the same allowance.
