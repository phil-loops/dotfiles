---
title: An evaluation is a row
section: Email safety evaluation
order: 40
project: eval-findings
ask: models/safety-evaluation.ts
lede: The tell was three columns nobody could fill honestly.
---

The first version stored each evaluation as a JSON document inside a table that already existed for a different job: comparing a production decision against a candidate. Reusing it felt thrifty. It was not.

The tell was small and damning. That table requires three columns describing a *production* decision, and this pipeline has none to describe. The seeding script wrote `"{}"`, `true` and `0` into them. **When you are inventing values to satisfy a schema, the schema is describing something other than what you have.**

Everything followed. The email was stored twice — once as a column, once inside the document. The things you would actually want to ask — which candidate produced this, what did it decide, what did it know — were inside a string, so no question could be answered in SQL. About a hundred lines existed purely to write that string and validate it coming back.

That last part was the answer to *why doesn't reading the code explain the code?* The schema said `rawOutput: String`; the meaning lived in a decoder elsewhere. A reader could not learn what an evaluation **is** without finding the parser.

Why fix it rather than ship it, and what a column still cannot promise: [[eval-row-limits]].
