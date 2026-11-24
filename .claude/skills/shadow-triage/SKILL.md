---
name: shadow-triage
description: Review a shadow evaluator's disagreements with prod (EvalResult rows, e.g. sol_layered_block_or_allow_v1 flips) — label them yourself in a Show deck, or send the team a Google Forms quiz where each person calls Block/Allow before seeing Sol's reasoning. Use when Phil pastes or exports EvalResult rows, or says "triage the shadow flips", "review the shadow", "false positives?", "how did the shadow do", "make a quiz / form for the team", "announce the shadow results".
---

# shadow-triage

One script, `~/.dotfiles/scripts/shadow-triage` (on PATH), two outputs from the same stored rows:

- **Phil alone → a Show labelling deck.** One section per sending domain; 1 sol right · 2 sol wrong · 3 unsure.
- **The team → a Google Forms quiz.** One email per page, Block/Allow, then a page with Sol's reasoning and a note box.

Rows live in `~/.local/share/shadow-triage/<pipeline>/rows.json` (deduped by EvalResult id); labels in `labels.json`, keyed by root domain. Decks live in `~/.local/share/show`, outside every repo.

## Recipe: a team quiz from yesterday's flips

1. **Export.** `shadow-triage sql` prints the query (last day, completed, `rawOutput` present, `decision` ≠ `prodDecision`). Phil runs it in his SQL client and copies the rows as CSV, with or without headers.
2. **Store.** `shadow-triage` reads the clipboard, adds the rows, and rebuilds the Show deck. Optional: Phil labels domains there first, and a **sol wrong** label flips that question's answer key.
3. **Build.** `shadow-triage form [--day YYYY-MM-DD]` (default: the newest day stored) writes `form-<day>.gs` beside the rows and puts it on the clipboard. Re-copy it with `pbcopy < ~/.local/share/shadow-triage/<pipeline>/form-<day>.gs` whenever Phil asks; his clipboard gets overwritten often.
4. **Run.** Phil opens `script.google.com/create`, pastes over the editor, runs `buildShadowQuiz` and allows access. The log prints **Share this** (respondent link) and **Edit / responses**.
5. **Check settings once in the editor.** Settings → Responses → Collect email addresses = **Verified**. The script tries to set this, but older Apps Script builds ignore it. Also confirm "Release grades: immediately after each submission", or "Later" if the end-of-quiz repeat of Sol's reasoning is noise.
6. **Share** the viewform link in Slack. The post carries only the link and a count, never email text.
7. **Read back.** Responses land in the form's Sheet: one Block/Allow column and one "Anything off about this reasoning?" column per email. Split calls and notes form the sharp set for the next prompt run.

What the quiz is: titled "<M/D> Disagreements", description "block or send". One question per sending domain (its newest email as plain text), in random order, each followed by a **What Sol said** page (Sol's call, prod's call, request / relies on / why) and an optional note box. A catch-all note comes last. Quiz mode: 1 point per question, answer key = Phil's label else Sol's call, the same reveal text as feedback. One response per person (forces sign-in), progress bar, published summary, edits after submit.

## Google Forms facts this cost us to learn

- Quiz feedback shows only **after the whole form is submitted**, never per click. The per-email reveal is a page break after each question; a respondent can still go Back and change the vote.
- `Form.moveItem` takes `(fromIndex, toIndex)` or `(Item, index)`, and a freshly created `PageBreakItem` is not an `Item`: use `moveItem(pb.getIndex(), idx)`. A throw after `add…Item()` leaves the item appended at the end.
- Text passed through `json.dumps` must contain real newlines; a `\\n` in the Python source arrives as a literal `\n` in the form.
- "One response per person" requires Google sign-in. `setCollectEmail(true)` adds a typed **Email** box on top of that, so never use it.
- The Apps Script log truncates large output; anything long goes to a Doc (`DocumentApp.create`).
- Forms shuffle only within a page, so with one email per page the generator randomises the order itself.
- To change a form Phil has already hand-edited, never regenerate it. Write an idempotent fixer that opens it by id (`FormApp.openById`), skips work already done, and logs the resulting layout. Test it in node against a stub `FormApp` from several starting states, running it twice.

## Also

- `shadow-triage results [PIPELINE]` folds the deck's (or the archived deck's) `.signoff.json` into `labels.json` and writes `sharp-set.json` (evalResultId, emailMessageId, domain, label, note).
- A domain labelled once comes back as the proposed choice (`a`) in later decks, under "Seen before".
- Grouping is by From root domain, so the quiz shows fewer questions than distinct email texts (Nov 24: 10 texts, 6 questions). An `--every-text` mode doesn't exist yet; build it if Phil wants every variant.

Data rule: rows are template scans (placeholders unresolved), which Claude may read for prompt work. Hydrated/sent-scan rows are not: don't open those decks or forms. Never publish this content as a claude.ai artifact. The quiz puts template text in Phil's Google Drive by his choice.
