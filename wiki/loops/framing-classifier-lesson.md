---
title: What the gate teaches us about our own classifiers
section: Working with safety classifiers
order: 20
project: classifier-framing
lede: A gate that reads vocabulary instead of intent blocks its own security team and waves through a reworded abuser. We ship gates like that.
---

The [[framing-reframe]] episode is a working demo, in miniature, of a tradeoff we face building abuse and safety classifiers for the sending platform.

## The failure mode

A classifier keyed on **surface vocabulary** — does this say `exploit`, does this look adversarial — has two costs that arrive together:

- **False positives on legitimate actors.** It bounced our own security team doing authorized work; it would bounce a researcher reporting a bug in good faith. The friction lands on the people trying to help.
- **False negatives on motivated bad actors.** They do not need the flagged words. They rephrase once — as we did — and walk through. The gate filtered tone, not behavior.

Worst of both: you tax the honest and miss the adversary, because the thing measured was never the thing that mattered.

## Gate on the property, not the proxy

The real discriminators are relational and behavioral: **ownership/authorization** (does the actor own, or have consent for, the assets in play), **target** (a third party they do not control), **behavior shape** (mass, non-consensual, evasion-driven, regardless of wording), and **requested effect** (a fix, or operational harm).

This is the same error as a bug we just found: the empty-token consent check keyed on a shallow signal — `token === ""` — instead of the real property, a proven token bound to a contact and team. Our abuse classifiers can make the identical mistake higher up: gate on the words in a campaign instead of whether the account has consent for these recipients and whether the pattern is harm-shaped.
