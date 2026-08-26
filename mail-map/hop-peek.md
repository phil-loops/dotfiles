---
title: 4 · Peek
section: The six hops
order: 33
ask: lib/valkey-mail-queue.ts
lede: scheduler, one Lua script per team — the single atomic doorway every email passes through.
---

[The peek script](src:lib/valkey-mail-queue.ts#PEEK_SCHEDULABLE_MAIL_SCRIPT) is the choke point. It is Lua; the same logic reads like this, and runs **atomically** inside Valkey:

    trim scheduled-rate of entries older than 1s
    available = rateLimit − size(scheduled-rate)
    if available <= 0: return []          # no headroom this second

    limit = min(batchSize, available)
    ids = queue entries scoring <= highMax, take limit    # high priority first

    room = limit − ids.length
    if room > 0:
      affordable = min(room, floor(tokens / scale))       # only what tokens cover
      ids += queue entries scoring >= lowMin, take affordable
      spend (that many) × scale tokens

    stamp every taken id into scheduled-rate at `now`
    return ids

`scale` (×1000) makes the token balance a fixed-point integer, so [[throttles]] can decay it by fractions; dividing gives a real count.

**Two gates, in order.** First a *rate ceiling*: the top three lines ask how many this team may still send this second — its per-second cap minus what it just sent — and return nothing if none are left. Priority-blind, it sizes the batch ([[throttles]] has the detail). **Then priority fills the slots** — high priority can take the entire batch, low priority only the leftover, and only what tokens cover. So transactional can starve workflow mail — by design.

**Why Lua, not TypeScript.** The throttles are shared counters. `GET` … decide … `DECRBY` is three round trips: two workers both read "1,000 left" and both spend it. Lua runs atomically, so read-decide-mutate is one step — the rule: **a decision on shared state must execute where the state lives.**
