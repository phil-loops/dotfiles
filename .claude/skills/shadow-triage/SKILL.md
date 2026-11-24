---
name: shadow-triage
description: Label a shadow evaluator's disagreements with prod (EvalResult rows, e.g. sol_layered_block_or_allow_v1 flips) in a Show labelling deck, one section per sending domain, and turn the labels into the sharp set for the next prompt run. Use when Phil pastes or exports EvalResult rows, or says "triage the shadow flips", "review the shadow", "false positives?", "how did the shadow do".
---

# shadow-triage

`shadow-triage [FILE|-] [--focus]` reads an EvalResult export (default: the clipboard; a header row with `emailText`, or headerless rows in schema order), adds the rows to `~/.local/share/shadow-triage/<pipeline>/rows.json` (deduped by id), and writes the labelling deck `~/.local/share/show/shadow-triage-<pipeline>.private.json`: an Overview (disagreement directions, phrases the model's reasons repeat across 3+ domains, ◆ when they echo the prompt on origin/main) and one section per From root domain. Choices: 1 sol right · 2 sol wrong · 3 unsure. Pass `--focus` only when Phil asked to see it now.

- `shadow-triage sql [PIPELINE]` prints the query for the last day's flips.
- `shadow-triage results [PIPELINE]` folds the deck's (or its archived) `.signoff.json` into `labels.json` and writes `sharp-set.json` (evalResultId, emailMessageId, domain, label, note): the 10–20-item set for the next prompt iteration.
- `shadow-triage form [PIPELINE] [--day D]` copies a Google Apps Script that builds a team quiz for one day (one Block/Allow question per sending domain, Sol's call as the answer key, Sol's reasoning as the feedback shown after submit, responses in a Sheet). Phil pastes it at script.google.com/create and runs it; the log prints the share link.
- A domain labelled once comes back as the proposed choice (`a`) in later decks, under "Seen before".

Data rule: rows are template scans (placeholders unresolved), which Claude may read for prompt work. Hydrated/sent-scan rows are not: don't open those decks. Decks stay outside every repo.
