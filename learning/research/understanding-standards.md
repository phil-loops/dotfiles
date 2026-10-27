# Standards, holistic assessment and markers of understanding: the authorities

Research for the tutor redesign (~/.claude/skills/tutor/SKILL.md, `learn` graph), 2026-10-22.
Planned additions: per-topic **standards** (can-do statements), per-level **observable markers** with
**anchor responses**, an **assessor pass** over the whole conversation that cites quotes ("talk first, tag
later"), and **spoken answers** via voice transcripts.

**Verification key** (every citation carries one):
- **[V]** found the primary source, or a publisher/repository record with the abstract, and the claim
  checked against it.
- **[B]** the bibliographic record is confirmed; the content claim comes from secondary summaries (it agrees
  with my own reading but I didn't re-read the primary here).
- **[M]** from memory, not verified in this session. Treat as a lead, not a citation.

---

## 0. What exists today (so the recommendations fit)

| Today's field | What it measures | Closest framework idea |
|---|---|---|
| `level`: predict / explain / transfer / critique | **kind** of performance | UbD facets (application, explanation, application-in-new-context, perspective); Bloom process dimension |
| `credit`: unaided / scaffolded / handed | **independence** | Vygotsky/assistance; Wood funnel. Not in any rubric framework, and an asset: most frameworks don't record it |
| `outcome`: hit / miss + misconception + contrast | **correctness** + **diagnosis** | Concept-inventory distractor logic; KiP "contrast cases" |
| `confidence` | **self-knowledge** | UbD facet 6; hypercorrection |
| held = unaided on 2 days | **retention** | spaced retrieval |
| `restate` (learner's own sentence) | **explanation quality** (unscored today) | SOLO is the obvious scale for it |

**What's missing:** a statement of *what the topic is for* (a standard), a **quality** scale for an answer
that is correct but shallow, or rich but partly wrong (hit/miss can't express "multistructural"), and an
interpretation rule that turns a pile of rows into a judgment ("does Phil meet S3?"). The NRC/ECD
literature below says that missing piece is the *interpretation* vertex.

---

## 1. Learning sciences and assessment: what understanding *is*, and how it's evidenced

### 1.1 NRC, *Knowing What Students Know* (Pellegrino, Chudowsky & Glaser, eds., 2001): the assessment triangle [V]
National Research Council (2001). *Knowing What Students Know: The Science and Design of Educational
Assessment.* National Academy Press. doi:10.17226/10019. https://www.nationalacademies.org/read/10019/chapter/5
- **Claim:** every assessment is reasoning from evidence and rests on three coordinated vertices:
  **cognition** (a model of how competence develops in the domain), **observation** (tasks that elicit
  revealing performances), and **interpretation** (methods that turn observations into inferences). The report
  says cognitive research should "guide the determination of what observations it is sensible to undertake
  and what sense can be made of those observations" (ch. 1). The cognition model is the cornerstone. [V]
- **For the tutor:** the graph's concept map plus misconceptions is the cognition vertex. Rungs are the
  observation vertex. **Interpretation is the weak vertex today:** depth = "highest level shown unaided" is an
  interpretation rule, but it ignores answer quality. Standards + markers + an assessor are an interpretation
  model.

### 1.2 Evidence-centered design (Mislevy, Steinberg & Almond, 2003) [B]
Mislevy, R. J., Steinberg, L. S., & Almond, R. G. (2003). On the structure of educational assessments.
*Measurement: Interdisciplinary Research and Perspectives*, 1(1), 3–62. CRESST CSE Report 597:
https://cresst.org/publication/on-the-structure-of-educational-assessments/ · Mislevy, Almond & Lukas (2003),
*A Brief Introduction to Evidence-Centered Design*, ETS RR-03-16, doi:10.1002/j.2333-8504.2003.tb01908.x
https://www.ets.org/research/policy_research_reports/publications/report/2003/hsgs.html
- **Claim:** design an assessment as an explicit **argument** (claim ← evidence ← task). The *Conceptual
  Assessment Framework* has three models [B; the definitions below are from memory of the papers, [M] for exact
  wording]:
  - **Student (competency) model:** the variables you want to make claims about.
  - **Evidence model:** *evaluation rules* (what in a work product counts as evidence, i.e. **observable
    markers**) plus a *measurement model* (how observables update the student model).
  - **Task model:** the features of situations that elicit those observables.
  Upstream of the CAF sits domain analysis/modeling. ECD descends from Messick's three questions: what
  knowledge should be assessed, what behaviors reveal it, what tasks elicit those behaviors (Messick 1994,
  *Educational Researcher* 23(2) 13–23 [B]; exact wording of the questions [M]).
- **For the tutor:** this is the cleanest scaffold for the redesign. **Standards = student model**; **markers
  + anchor responses = evaluation rules**; **"held", SOLO aggregation and spaced re-tests = measurement
  model**; **rung types (predict / invent / transfer / critique, trap, contrast) = task model**. See §4.2.

### 1.3 Wiggins & McTighe, *Understanding by Design* (1998; 2nd ed. 2005): six facets, backward design [B]
Wiggins, G., & McTighe, J. (2005). *Understanding by Design* (expanded 2nd ed.). ASCD. Facets handout:
https://sites.duke.edu/aagc/files/2022/08/C9-SixFacetsUnderstanding.pdf · ASCD 1998 article:
https://www.ascd.org/el/articles/understanding-by-design-Decermber-1998
- **Claim:** understanding is revealed by **transfer**: using knowledge autonomously in new situations, not by
  recall. Evidence comes through six facets: **explain** (justified accounts of *why/how*), **interpret** (make
  meaning of data or situations), **apply** (use in new contexts), **perspective** (see other points of view,
  critique), **empathy**, and **self-knowledge** (know the limits of your own understanding). The facets are not
  a hierarchy. **Backward design** has three stages: (1) desired results (enduring understandings + essential
  questions), (2) acceptable evidence (performance tasks), (3) the learning plan. [B]
- **For the tutor:** the standards are Stage 1 ("can-do" = enduring understanding + transfer goal). Markers and
  anchors are Stage 2, written *before* rungs; the existing plan file is Stage 3. The facets mostly coincide with
  existing `level`s: explain = explain; apply = predict (near) / transfer (far); perspective = critique (judging
  code, weighing designs); self-knowledge = **confidence calibration** (already captured, so score it).
  Empathy is irrelevant here.

### 1.4 SOLO taxonomy (Biggs & Collis, 1982) [B]
Biggs, J. B., & Collis, K. F. (1982). *Evaluating the Quality of Learning: The SOLO Taxonomy.* Academic Press.
Summary: https://edu.rsc.org/ideas/what-is-solo-taxonomy/3008902.article
- **Claim:** the **structure** of a response grades its quality, not its count of correct facts:
  **prestructural** (misses the point) → **unistructural** (one relevant aspect) → **multistructural**
  (several aspects, unconnected) → **relational** (aspects integrated into a coherent whole, so it can explain
  and predict) → **extended abstract** (the integrated whole generalized to new domains or principles). [B]
- **Why it fits best for free talk:** SOLO judges *any* open response holistically, with no item bank. It
  separates "knows lots of SQS facts" (multistructural) from "has a working model" (relational), which is
  exactly the difference hit/miss can't record. Lister et al. (§2.1) showed it works on programming
  explanations.

### 1.5 Revised Bloom (Anderson & Krathwohl, 2001; Krathwohl, 2002) [B]
Krathwohl, D. R. (2002). A revision of Bloom's taxonomy: An overview. *Theory Into Practice*, 41(4), 212–218.
https://www.bu.edu/provost/files/2013/10/Anderson-Krathwohl-Revision-to-Blooms-Taxonomy-of-Educational-Objectives.pdf
- **Claim:** an objective is a **verb × noun**: cognitive process (remember, understand, apply, analyze,
  evaluate, create) × knowledge type (**factual, conceptual, procedural, metacognitive**). The steps are not
  strictly cumulative. [B]
- **For the tutor:** use it for the *statement grammar* of standards (a verb plus a knowledge type), and for
  the SKILL.md's existing **derivable-vs-given** split: "conventions/facts get told" = factual knowledge;
  "principles get derived" = conceptual. Don't use it as the level scale: Bloom labels the *task*, SOLO grades
  the *response*.

### 1.6 Chi: self-explanation, ICAP, conceptual change [V/B]
- Chi, M. T. H., de Leeuw, N., Chiu, M.-H., & LaVancher, C. (1994). Eliciting self-explanations improves
  understanding. *Cognitive Science*, 18(3), 439–477. https://pcl.sitehost.iu.edu/rgoldsto/courses/cogscilearning/chiselfexplanation.pdf [V]:
  prompted self-explainers gained more, and high explainers more often reached the **correct mental model**.
  Understanding = a correct, runnable mental model. Self-explanation is how flawed models get repaired.
- Chi, M. T. H., & Wylie, R. (2014). The ICAP framework: Linking cognitive engagement to active learning
  outcomes. *Educational Psychologist*, 49(4), 219–243. doi:10.1080/00461520.2014.965823
  https://chilab.asu.edu/sites/default/files/lcl/chiwylie2014icap_2.pdf [V]: classifies **overt behavior**
  as Passive < Active < Constructive (generates beyond the given) < Interactive (co-constructs with a partner),
  and predicts learning rises in that order. Replications are mixed [B].
- Chi, M. T. H. (2005). Commonsense conceptions of emergent processes: Why some misconceptions are robust.
  *Journal of the Learning Sciences*, 14(2), 161–199. https://education.asu.edu/sites/default/files/lcl/emergjlspdf_3.pdf [V]:
  misconceptions that miscategorize an **emergent** process as a **direct** one are robust, and fixing them
  takes an ontological (category) shift, not a fact correction.
- Chi (2008), "Three types of conceptual change: belief revision, mental model transformation, categorical
  shift," in Vosniadou (ed.), *International Handbook of Research on Conceptual Change* [M].
- **For the tutor:** (a) ICAP gives a **transcript-observable** marker of engagement: an utterance that adds
  an inference not in the rung is *constructive*, and building on the tutor's counter-case is *interactive*.
  The assessor can tag this from quotes. (b) Chi 2005 explains Phil's two sticky misses:
  "lock prevents concurrent execution" treats a *lease* (a promise about who may be handed work) as a *direct
  causal agent* (a guard that stops execution). That's a category error, so expect it to recur. It needs
  repeated contrast in new settings (croon → SQS → svix), not one correction. The plan already does this.

### 1.7 Misconceptions: knowledge-in-pieces (diSessa) vs framework theory (Vosniadou) [V/B]
- diSessa, A. A. (1993). Toward an epistemology of physics. *Cognition and Instruction*, 10(2–3), 105–225 [B].
  Smith, J. P., diSessa, A. A., & Roschelle, J. (1993/94). Misconceptions reconceived: A constructivist analysis
  of knowledge in transition. *Journal of the Learning Sciences*, 3(2), 115–163. doi:10.1207/s15327809jls0302_1
  https://www.sri.com/publication/education-learning-pubs/misconceptions-reconceived-a-constructivist-analysis-of-knowledge-in-transition/ [V]
  - **Claim (KiP):** intuitive knowledge is many small, context-cued elements (p-prims). A "misconception" is a
    productive element applied out of its range. Novice ideas are **resources to refine, not replace**. [V]
- Vosniadou, S., & Brewer, W. F. (1992). Mental models of the earth: A study of conceptual change in childhood.
  *Cognitive Psychology*, 24(4), 535–585. doi:10.1016/0010-0285(92)90018-W [B]
  - **Claim (framework theory):** learners hold coherent presuppositions, and instruction produces
    **synthetic models** (hybrids of intuition and taught fact), which are diagnosable by consistent patterns
    across generative questions. [B]
- **For the tutor, two operational consequences:**
  1. **Record misconceptions with their cueing context** (KiP). "Lock prevents execution" may fire in croon and
     not in SQS, or the reverse. The contrast field already encodes "same situation, one variable changed".
     Add the *setting* where it fired so the assessor can tell a stable framework belief from a context-bound
     fragment.
  2. **Look for synthetic models** (Vosniadou). An answer like "visibility extension stops the second worker
     *until the first finishes*" is a hybrid: taught fact (extension) + intuitive frame (lock = exclusion). The
     assessor should name a hybrid as such rather than score it hit or miss. It is *multistructural with an
     intrusion*. Generative questions (situations with no taught answer) expose hybrids best, which is the case
     for invent rungs.

### 1.8 Formative assessment: Black & Wiliam [V/B]
Black, P., & Wiliam, D. (1998). Inside the black box: Raising standards through classroom assessment. *Phi
Delta Kappan*, 80(2), 139–148.
https://people.bath.ac.uk/edspd/Weblinks/MA_Ass/Resources/Using%20assessment%20formatively/Black%20&%20Wiliam%201998%20PDK.pdf [V].
The underlying review is Black & Wiliam (1998), "Assessment and classroom learning," *Assessment in Education*
5(1), 7–74 [M: the title wasn't confirmed in search]. Wiliam (2011), *Embedded Formative Assessment*,
Solution Tree [B]: five strategies, (1) clarify learning intentions and success criteria, (2) engineer
discussions and tasks that **elicit evidence**, (3) feedback that moves learning forward, (4) peers as
resources, (5) learners as owners. "Hinge questions" (one diagnostic item whose wrong options map to
misconceptions) [M].
- **Claim:** assessment is formative only when the evidence is *used* to adapt the next step. Its large
  effects come from that loop, not from grading.
- **For the tutor:** strategy 1 says **show the standards to Phil up front**. The advance organizer should
  list the 3–5 can-do statements, not just stations. Strategy 5 says **let him self-assess against the
  markers** before the assessor does, then compare: the comparison is a calibration signal (UbD
  self-knowledge). A trap rung is a hinge question.

### 1.9 Feedback: Hattie & Timperley (2007) [V/B]
Hattie, J., & Timperley, H. (2007). The power of feedback. *Review of Educational Research*, 77(1), 81–112.
doi:10.3102/003465430298487. https://www.uky.edu/~gmswan3/575/Hattie_Timperley_2007.pdf [V for citation; B
for detail]
- **Claim:** effective feedback answers *Where am I going? How am I going? Where to next?* (feed up / back /
  forward). It operates at four levels: task, process, self-regulation, self. Feedback about the **self**
  (praise) is least effective. [B]
- **For the tutor:** the skill already bans praise of the person. Standards make "where am I going" explicit.
  The assessor's per-standard output should end with *where to next* (the next marker up, plus the rung that
  would show it), which is feed-forward at the process level.

### 1.10 Learning progressions (NRC; Corcoran, Mosher & Rogat, 2009) [B]
Corcoran, T., Mosher, F. A., & Rogat, A. (2009). *Learning Progressions in Science: An Evidence-based
Approach to Reform* (CPRE RR-63). https://repository.upenn.edu/cpre_researchreports/ · see also NRC (2007)
*Taking Science to School* [M].
- **Claim:** progressions are "empirically grounded and testable **hypotheses** about how students'
  understanding of, and ability to use, core … concepts … grow and become more sophisticated over time"
  (p. 8, quoted via secondary source [B]). Each has anchors at both ends and intermediate levels, *including
  predictable intermediate wrong models*.
- **For the tutor:** a station ladder is a **hypothesized progression** for one learner. Writing the SOLO
  markers per standard *is* writing a mini-progression. Because the evidence rows are timestamped, the
  hypothesis is testable: if Phil reaches relational on S3 without passing multistructural on S2, the
  ordering was wrong, and that should feed back into the plan.

### 1.11 Verbal protocols: Ericsson & Simon (1980; 1993), directly relevant to voice [V/B]
Ericsson, K. A., & Simon, H. A. (1980). Verbal reports as data. *Psychological Review*, 87(3), 215–251.
https://www3.nd.edu/~ghaeffel/Ericsson&Simon(1980).pdf [V] · Ericsson & Simon (1993). *Protocol Analysis:
Verbal Reports as Data* (rev. ed.). MIT Press [B].
- **Claim:** verbal reports are valid data when you model how they're produced. Verbalizing changes cognition
  only when instructions require verbalizing information that wouldn't otherwise be attended to [V]. Three
  levels: (1) vocalizing contents already in verbal form; (2) recoding non-verbal content (describing what
  you're doing), which slows the task but doesn't alter it; (3) **explaining, justifying, reasons**, which is
  *reactive* and changes the process [B, via MeasuringU summary].
- **For voice transcripts:**
  1. **"Explain why" is level 3 by design.** It changes the thinking, which is the point (self-explanation,
     §1.6), but it means a spoken explanation is *partly constructed in the act*. Score the final model
     stated, not the path. Treat a self-correction mid-utterance as **evidence of reorganization** (often the
     most valuable signal), not as a miss.
  2. **Separate the prediction from the explanation in the transcript.** Ask for the prediction first (a short
     level-1/2 utterance), then the why. The assessor tags the predict and explain levels from different
     spans.
  3. **Think-aloud while solving** (an invent rung done aloud) is a level-2 protocol. It reveals *process*,
     the order of inferences, which a typed answer hides. Code it as process, separately from correctness.
  4. **Don't read hesitation as low confidence.** Fillers and restarts are speech production. Keep the
     explicit confidence ask.

### 1.12 Rubrics and standards: Sadler, Brookhart, Jonsson & Svingby, single-point [B/V]
- Sadler, D. R. (1987). Specifying and promulgating achievement standards. *Oxford Review of Education*,
  13(2), 191–209 [B: record confirmed, content via secondaries]. **Claim:** verbal standard descriptors are
  inherently fuzzy. Standards become shareable only through **verbal descriptors + exemplars + tacit
  knowledge (rater experience)** together. Sadler (2014), "The futility of attempting to codify academic
  achievement standards," *Higher Education* [B], goes further: codification alone cannot fix a standard.
  → **This is the strongest single argument for anchor responses.**
- Brookhart, S. M. (2018). Appropriate criteria: Key to effective rubrics. *Frontiers in Education*, 3:22.
  doi:10.3389/feduc.2018.00022 https://www.frontiersin.org/journals/education/articles/10.3389/feduc.2018.00022/full [V].
  **Claim:** a rubric = **criteria** suited to the purpose + **performance-level descriptions** along a
  continuum. Levels must describe *quality*, not count occurrences or use rating-scale words ("good",
  "excellent"). Analytic rubrics score criteria separately and holistic rubrics score the whole (her earlier
  book, Brookhart 2013, *How to Create and Use Rubrics*, ASCD [M]).
- Jonsson, A., & Svingby, G. (2007). The use of scoring rubrics: Reliability, validity and educational
  consequences. *Educational Research Review*, 2(2), 130–144 [B]. **Claim:** rubrics raise reliability most
  when they are **analytic, topic-specific, accompanied by exemplars, and raters are trained**. Holistic
  judgments are less reliable [B for citation; the intra-/inter-rater reliability framing is confirmed via a secondary source; the specific conclusions listed here are [M]].
- Single-point rubric: Fluckiger, J. (2010). Single point rubric: A tool for responsible student
  self-assessment. *Delta Kappa Gamma Bulletin*, 76(4), 18–25. https://digitalcommons.unomaha.edu/tedfacpub/5
  [V]. One column describes the **proficient** standard, with open "concerns" and "advanced" columns either
  side. It is designed for **self-assessment and feedback**, not ranking.
- **For the tutor:** use **analytic per-standard** judgments (each standard scored separately on SOLO) with an
  explicit holistic summary on top. Pure holistic scoring is the least reliable option, and a model judge
  makes that worse (§4.3). Write each SOLO level as a **quality description of the mechanism stated**, never
  "mentions 3 of 5 facts". The single-point form suits the learner-facing view: show the relational marker as
  "the standard", and record the evidence above or below it as free text.

### 1.13 Concept inventories: the Force Concept Inventory as a model [V]
Hestenes, D., Wells, M., & Swackhamer, G. (1992). Force Concept Inventory. *The Physics Teacher*, 30(3),
141–158. doi:10.1119/1.2343497. https://physport.org/assessments/FCI · https://davidhestenes.net/modeling/R&E/FCI.PDF
- **Claim:** commonsense beliefs about force are incompatible with Newtonian concepts, and instruction that
  ignores them is largely ineffective. The FCI uses **everyday language** and **distractors that are real
  commonsense alternatives**, so a wrong answer *diagnoses* a belief. [V]
- **For the tutor:** (a) a trap rung is an FCI item without the multiple choice. Its "intuitive wrong
  prediction" should be one **named misconception** in the graph, not ad hoc. (b) **Stuck step 4(b)** (offer
  2–4 candidate predictions) should draw the candidates from the misconception catalogue, so the pick is
  diagnostic like an FCI distractor. (c) The **misconception catalogue per standard** (§5) is the inventory's
  distractor bank.

---

## 2. Computing education research

### 2.1 SOLO applied to programming: Lister et al. (2006) [V]
Lister, R., Simon, B., Thompson, E., Whalley, J. L., & Prasad, C. (2006). Not seeing the forest for the trees:
Novice programmers and the SOLO taxonomy. *ITiCSE '06*, 118–122. https://opus.lib.uts.edu.au/handle/10453/4043
- **Claim:** asked to explain a code fragment "in plain English", **educators answer relationally** (what the
  code *does* as a whole: "returns true if the array is sorted"), while **students answer multistructurally**
  (a line-by-line narration). Data were written answers plus **think-aloud**. [V]
- Follow-up: Whalley et al. (2006), "An Australasian study of reading and comprehension skills in novice
  programmers, using the Bloom and SOLO taxonomies," *ACE 2006* (CRPIT 52) [B].
  https://openrepository.aut.ac.nz/handle/10292/15405
- **For the tutor:** this is the marker template. *Multistructural = narrates the steps; relational = states
  the invariant or behavior the steps produce.* For SQS: "receive, then 20s timer, then extend, then delete"
  (M) vs "a live handler keeps re-leasing its message with 10s slack. When the beats stop, for any reason, the
  message is someone else's within 30s" (R). A critique row on real code is a Lister-style "explain in plain
  English" task.

### 2.2 Notional machines: du Boulay (1986); Sorva (2013) [B/M]
- du Boulay, B. (1986). Some difficulties of learning to program. *Journal of Educational Computing Research*,
  2(1), 57–73 [M: title/venue not confirmed in this session. The term "notional machine" ("the idealised
  model of the computer implied by the constructs of the programming language") attributed to du Boulay is
  confirmed via secondary source [B]].
- Sorva, J. (2013). Notional machines and introductory programming education. *ACM TOCE*, 13(2), 8:1–8:31.
  doi:10.1145/2483710.2483713 [B]. **Claim:** understanding a language means holding a runnable model of the
  machine it implies. Learners often hold several, sometimes contradictory, models.
- **For the tutor:** **the notional machine for this topic is the SQS message state machine**: stored →
  in flight (deadline, receipt handle, receive count) → stored | deleted | DLQ, plus the consumer's local
  machine (handler running, heartbeat timer, delete-in-finally). "Relational" for S1–S4 means *Phil can run
  this machine forward on a timeline*. Make that explicit in the standards: a relational answer is one that
  correctly **simulates** a new timeline.

### 2.3 Threshold concepts: Meyer & Land (2003); Boustedt et al. (2007) [B]
Meyer, J. H. F., & Land, R. (2003). Threshold concepts and troublesome knowledge: Linkages to ways of thinking
and practising within the disciplines. ETL Project Occasional Report 4 [B; Perkins's "troublesome knowledge"
lineage confirmed via secondary]. Boustedt, J., Eckerdal, A., McCartney, R., Moström, J. E., Ratcliffe, M.,
Sanders, K., & Zander, C. (2007). Threshold concepts in computer science: Do they exist and are they useful?
*SIGCSE Bulletin*, 39(1), 504–508 [B].
- **Claim:** some concepts are **transformative** (change how the domain looks), **irreversible**,
  **integrative** (expose hidden connections), **bounded** and **troublesome**. Learners sit in a "liminal"
  state, often mimicking the right words before crossing. [B]
- **For the tutor:** in this topic **"a lease is a promise about delivery, not control of execution"**
  (visibility-is-not-a-job-timeout ≈ lock-guards-holders-not-execution) behaves like a threshold concept. It
  integrates locks, leases, SQS and svix timeouts, and Phil has missed it before. Liminality predicts
  **mimicry**: correct words, wrong predictions. So **an explanation marker is only credited if a prediction on
  a new timeline agrees with it**. That's the main structural rule in §4.2.

### 2.4 CS concept inventories [V/B]
Taylor, C., Zingaro, D., Porter, L., Webb, K. C., Lee, C. B., & Clancy, M. (2014). Computer science concept
inventories: Past and future. *Computer Science Education*, 24(4), 253–276. doi:10.1080/08993408.2014.970779
https://works.swarthmore.edu/fac-comp-sci/42 [V]. **Finding:** as of 2014 there were **no widely used,
validated CS concept inventories**, apart from groundwork (core concepts, misconception studies) and the Digital
Logic CI (Herman, Zilles & Loui, 2014, same issue [B]). An ICER 2023 systematic review, "Taking Stock of
Concept Inventories in Computing Education", updates the picture
(https://icer2023.acm.org/details/icer-2023-papers/29/) [B]. **No concept inventory for message queues or
distributed delivery semantics was found.** Any inventory here would be home-made: the misconception
catalogue in §5.

### 2.5 Concurrency / distributed systems understanding [V/B]
- Ben-David Kolikant, Y. (2001). Gardeners and cinema tickets: High school students' preconceptions of
  concurrency. *Computer Science Education*, 11(3), 221–245
  https://openscholar.huji.ac.il/yifat-kolikant/publications/gardeners-and-cinema-tickets-high-school-students-preconceptions [B].
  **Claim:** students bring everyday models of concurrency (the cinema-ticket seller) that are reasonable but
  faulty. Kolikant (2004), "Learning concurrency: Evolution of students' understanding of synchronization,"
  *IJHCS* [B]: students develop **pattern-based** techniques that solve the problems without the underlying
  model, a mimicry warning that matches §2.3. Lewandowski et al. (2010, CACM), "Commonsense understanding of
  concurrency: computing students and concert tickets"
  https://cacmb4.acm.org/magazines/2010/7/95044-commonsense-understanding-of-concurrency-computing-students-and-concert-tickets [B]:
  untrained students identify most race conditions in an everyday ticket-selling scenario. Intuition is a
  resource (the KiP view).
- Lönnberg, J., & Berglund, A. (2007). Students' understandings of concurrent programming. *Koli Calling
  2007*, CRPIT 88 https://crpit.scem.westernsydney.edu.au/abstracts/CRPITV88Lonnberg.html [B]; Lönnberg,
  Berglund & Malmi (2009), "How students develop concurrent programs," *ACE 2009* [B]: phenomenographic
  categories of how students understand and debug concurrent programs.
- **No assessment-of-understanding work specific to at-least-once delivery / idempotency was found.** The
  nearest are the concurrency studies above plus the ontological-category account (Chi 2005).
- **For the tutor:** start from Phil's everyday or analog model (the croon lock, the mail-queue claim) and
  use it as a resource. The plan's "enter via analog" is this. Pattern-solving without the model is the
  risk, so require predictions on novel timelines.

---

## 3. Domain authorities: SQS visibility timeout, at-least-once delivery, idempotent consumers

### 3.1 AWS SQS documentation (primary; fetched 2026-10-22) [V]
- **Visibility timeout**: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-visibility-timeout.html
  - Received ≠ removed: "it remains in the queue but becomes temporarily invisible". Unless deleted before the
    timeout, it "becomes visible again in the queue and can be retrieved by another consumer". Default 30s.
  - "due to the at-least-once delivery model … there's no absolute guarantee that a message won't be delivered
    more than once **during** the visibility timeout period" (standard queues). Even a healthy lease doesn't
    guarantee exclusivity.
  - Failures ("application errors, crashes, or connectivity problems") all go the same way: the message
    reappears. Too high a timeout "can delay the reappearance of unprocessed messages".
  - Best practice: set the timeout to typical max processing time and "implement a **heartbeat** mechanism to
    periodically extend". There is a **12-hour cap from first receive**, and extending doesn't reset it.
  - Setting `VisibilityTimeout` to 0 via ChangeMessageVisibility releases the message immediately (an
    alternative to waiting out a throw).
- **ChangeMessageVisibility API**: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/APIReference/API_ChangeMessageVisibility.html
  - **Relative to the call** (confirms plan F3): "the 10 seconds begin to count from the time that you make the
    ChangeMessageVisibility call".
  - The changed value is **not remembered**. On the next receive the timeout "reverts to the original timeout
    value".
  - Errors include `MessageNotInflight` and `ReceiptHandleIsInvalid`.
- **ReceiveMessage API**: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/APIReference/API_ReceiveMessage.html
  - `ApproximateReceiveCount`: "the number of times a message has been received … but not deleted".
  - "A message that isn't deleted or a message whose visibility isn't extended before the visibility timeout
    expires counts as a **failed receive**. Depending on the configuration of the queue, the message might be
    sent to the dead-letter queue."
  - In the FIFO-specific notes: "If a caller … still processes messages when the visibility timeout expires …
    another worker … can receive the same messages and therefore process **duplicates**. Also, if a consumer
    whose message processing time is longer than the visibility timeout tries to delete the processed messages,
    the action fails with an error. … ensure that your application observes a **safe threshold** before the
    visibility timeout expires and extend". (This is the AWS fact behind plan R3.2's "old receipt handle". The
    statement appears in the FIFO paragraph, so tell it as such.)
- **Dead-letter queues**: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html
  - "`maxReceiveCount` is the number of times a consumer can receive a message from a source queue before it
    is moved to a dead-letter queue". Set it "high enough to allow for sufficient retries". (Supports plan F4
    and R4.1, "moved on the receive that would exceed". The docs don't state the exact instant of the move, so
    keep the rung's answer as "after the 3rd receive fails, not delivered a 4th time".)
  - For standard queues with `maxReceiveCount > 3`, a message received 3+ times without delete is moved to the
    back of the queue.
  - DLQ retention is measured from the **original enqueue** (standard queues), so make the DLQ's retention
    longer than the source's.
- **At-least-once delivery**: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/standard-queues-at-least-once-delivery.html
  - A server holding a copy can be unavailable during receive/delete, so "you might get that message copy
    again". "Design your applications to be **idempotent** (they should not be affected adversely when
    processing the same message more than once)."
  - **Note:** AWS names a *second* source of duplicates beyond the consumer-crash story in plan R1.2:
    infrastructure-level redelivery. Worth one sentence so S1 isn't framed as "duplicates only come from
    crashes".

### 3.2 Kleppmann, *Designing Data-Intensive Applications* (O'Reilly, 2017) [B/M]
- Ch. 8 "The Trouble with Distributed Systems": **process pauses** (GC, VM suspension) mean a lease holder
  can keep acting after its lease expired, and the cure is **fencing tokens** checked by the resource.
  Verified in his companion essay: Kleppmann (2016), "How to do distributed locking"
  https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html [V]: a paused client "may …
  go ahead and make some unsafe change", and "You cannot fix this problem by inserting a check on the lock
  expiry just before writing"; the fix is to "include a fencing token with every write request".
  → the domain authority behind **visibility-is-not-a-job-timeout** and **lock-guards-holders-not-execution**.
- Ch. 11 "Stream Processing" § fault tolerance: exactly-once *processing* means making the **final effect**
  equal a fault-free run despite retries, achieved via idempotence or atomic commit. Broker-level guarantees
  don't stop a user from resubmitting after a timeout, so **end-to-end** idempotence is still needed [B: via
  reader highlights; chapter/section [M]].
- Ch. 12 "The Future of Data Systems" § "The end-to-end argument for databases": **operation identifiers**
  (a unique request ID generated at the client, carried end to end) make duplicate suppression work across
  every layer [M: section title from memory].
- Essential ideas: delivery ≠ processing; exactly-once *delivery* is unattainable, effectively-once *effect*
  is attainable; leases don't fence; dedup keys must originate at the end that retries.

### 3.3 Hohpe & Woolf, *Enterprise Integration Patterns* (Addison-Wesley, 2003) [V for site excerpts]
- **Idempotent Receiver** https://www.enterpriseintegrationpatterns.com/patterns/messaging/IdempotentReceiver.html:
  "Even when a sender application only sends a message once, the receiver application may receive the message
  more than once." Two remedies: **explicit de-duplication** (track message identity) or **idempotent message
  semantics** (design the message so reapplying has the same effect).
- **Guaranteed Delivery** https://www.enterpriseintegrationpatterns.com/patterns/messaging/GuaranteedMessaging.html:
  store-and-forward persistence, where a message "is not deleted from one data store until it is successfully
  forwarded". The source of at-least-once: the delete follows the forward, so a crash between them
  duplicates.
- **Dead Letter Channel** https://www.enterpriseintegrationpatterns.com/patterns/messaging/DeadLetterChannel.html:
  where a system moves messages it "cannot or should not deliver". The current site page cites SQS's receive
  count limit as the example.
- Essential ideas: at-least-once is the *price* of guaranteed delivery; the receiver owns duplicates; poison
  messages need an exit.

### 3.4 Respected practitioner and foundational sources
- Saltzer, J. H., Reed, D. P., & Clark, D. D. (1984). End-to-end arguments in system design. *ACM TOCS*,
  2(4), 277–288. https://www.cs.princeton.edu/courses/archive/fall10/cos597B/papers/e2e-tocs84.pdf [V for
  abstract]: duplicate message suppression is one of the paper's examples. Low-level mechanisms are justified
  only as performance enhancements, because the application can originate duplicates through its own retries.
  → the root authority for **idempotency-key-minted-before-retry-boundary** and **nested-retry-layers**.
- AWS Builders' Library, "Making retries safe with idempotent APIs" (Malcolm Featonby)
  https://aws.amazon.com/builders-library/making-retries-safe-with-idempotent-APIs/ [V]: a caller-provided
  **client request token**, generated once by the SDK and **reused across retries**. Return a "semantically
  equivalent response" for the same token. Same token with different parameters → validation error. Tokens
  are kept for a bounded window. → the canonical *where to mint the key* source. Note the contrast with svix
  (F5): the SDK reuses its key across *its own* retries, but the outer SQS retry is outside its scope.
- Treat, T. (2015). "You cannot have exactly-once delivery." Brave New Geek
  https://bravenewgeek.com/you-cannot-have-exactly-once-delivery/ [B]: the Two Generals argument. Rebuttal on
  terminology: Kreps, J. "Exactly-once one more time" https://medium.com/@jaykreps/exactly-once-one-more-time-901181d592f9 [B].
  Useful as an **invent/critique prompt**: "who's right, and what does each mean by *delivery*?" That's
  UbD's perspective facet.

### 3.5 What the authorities agree an engineer must understand
1. **Receive is a lease, delete is the only commit.** (AWS visibility; EIP Guaranteed Delivery)
2. **Therefore duplicates are normal**: from consumer crash-before-delete, lease lapse during slow work, and
   broker-internal redelivery. Exactly-once *delivery* is not on offer. (AWS at-least-once; EIP Idempotent
   Receiver; Kleppmann; Treat)
3. **Timing is deadline arithmetic**: deadline = time of last receive or extend + timeout; failures don't
   speed up redelivery; heartbeats need margin; there's a 12h cap. (AWS visibility + ChangeMessageVisibility)
4. **A lapsed lease doesn't stop the holder**: concurrent execution is possible, and only the resource can
   fence. (AWS ReceiveMessage note; Kleppmann fencing)
5. **Poison messages need a bounded exit**: receive count, maxReceiveCount, DLQ, and retention from original
   enqueue. (AWS DLQ; EIP Dead Letter Channel)
6. **Make the effect idempotent end to end**: a stable operation ID minted where the outermost retry
   originates, carried through; your timeout doesn't cancel their write. (Saltzer et al.; Builders' Library;
   Kleppmann ch. 12; EIP Idempotent Receiver)

---

## 4. Synthesis

### 4.1 Which frameworks fit a 1:1 adult-engineer tutor scored from free talk
Ranked by leverage for *this* tutor:

1. **ECD** (with the NRC triangle as its summary): the architecture. It forces the missing interpretation
   layer and maps one-to-one onto the graph (§4.2).
2. **SOLO** (via Lister): the **quality scale** for open, spoken answers. It needs no item bank, and judging
   integration rather than fact count suits transcripts.
3. **UbD**: backward design (standards before rungs) and facets as **evidence channels**. The current
   `level` field already is a facet set. Add self-knowledge (calibration).
4. **Sadler + Brookhart + Jonsson & Svingby**: **anchors are not optional**. Fuzzy descriptors only become
   reliable with exemplars and calibrated raters. Score analytically per standard, describe quality, not
   counts.
5. **Ericsson & Simon**: the **rules of evidence for voice**. Separate prediction from explanation; "why" is
   reactive by design; self-corrections are signal; disfluency isn't doubt.
6. **KiP / framework theory / Chi's ontological categories**: how to **record and interpret misses**. Keep
   the cueing setting, detect synthetic hybrids, and expect category errors (lease ≠ guard) to recur across
   settings.
7. **Concept-inventory logic (FCI) + threshold concepts**: misconceptions become a named distractor bank, and
   threshold concepts get the mimicry guard: *no explanation credit without a prediction that agrees with it*.

Bloom (revised) is useful only for phrasing standard verbs. ICAP and Hattie & Timperley inform the tutor's
moves more than its scoring.

### 4.2 Recommended structure: ECD over the existing graph

```
Topic
 └─ Standard S_k   (student-model variable; UbD Stage 1)
      can-do:      "<verb> <object> <condition>"  — one sentence, behavior not vocabulary
      big idea:    the transferable principle (UbD enduring understanding)
      concepts:    [graph concept ids it aggregates]
      authorities: [doc refs from §3]
      markers:     SOLO ladder U / M / R / EA, each = observable description + 1–2 anchor responses
      misconceptions: named, each tied to the SOLO level it caps and a contrast case
      tasks:       which rung types can yield evidence at which level (task model)
Evidence row (unchanged fields + three new ones)
      concept, level, credit, outcome, confidence, rung, note     ← per-turn, tutor-tagged
      + standard: S_k
      + solo: pre|uni|multi|rel|ext        ← assessor-tagged, after the session
      + quote: "<verbatim span>" + turn ref ← the data in the Toulmin claim
Standard judgment (measurement model, per standard per session)
      solo_level, credit floor, facets covered, quotes[], gaps, next-marker rung
```

Rules of the measurement model (interpretation):
- **Met at level L** = (a) ≥1 **explain**-level quote judged at L, **and** (b) ≥1 **predict or transfer** on
  an *unseen* timeline consistent with that explanation, both **unaided**. (Mimicry guard, §2.3; Lister's
  relational = "says what it does as a whole" and also runs it.)
- **Held** stays as today (unaided on two days), now per *standard at a SOLO level*, not per concept.
- **Relational** is the target for S1–S5. **Extended abstract** is earned only by a transfer row via an
  analog *in a different system* (croon, svix) or a critique that generalizes (e.g. "this is the fencing
  problem"). EA is the existing transfer/critique levels, scored for structure.
- **Credit caps the level**: scaffolded evidence can show at most "M (with help)". Handed evidence shows
  nothing about the standard. Keep the learner audit.
- **Confidence × outcome → calibration** per standard (UbD self-knowledge): report hits at low confidence and
  misses at high confidence. These already drive re-tests; now they also appear in the judgment.

**Talk first, tag later** (assessor pass), in ECD terms: the per-turn rows are the tutor's live *provisional
observables*. The assessor re-derives observables from the transcript independently, then the two are
reconciled. Disagreements are surfaced to Phil, not averaged.

### 4.3 Keeping model-judged holistic scoring reliable
Human-rater literature (Sadler; Jonsson & Svingby; Brookhart) plus LLM-judge findings:
- Zheng, L., et al. (2023). Judging LLM-as-a-judge with MT-Bench and Chatbot Arena. *NeurIPS 2023 Datasets
  & Benchmarks*. https://arxiv.org/abs/2306.05685 [V]: strong judges reach ~80% agreement with humans, the
  same as human-human, but show **position bias**, **verbosity bias** and **self-enhancement bias**.
- Kim, S., et al. (2024). Prometheus: Inducing fine-grained evaluation capability in language models.
  *ICLR 2024*. https://arxiv.org/abs/2310.08491 [V]: judges approach human correlation **when given a score
  rubric and reference answers**. Reference answers matter.

Recommendations:
1. **Anchors per level, per standard: two each**, one clean and one *borderline* (just in, just out). Write
   them before the first session (backward design). Replace them over time with **real Phil quotes** that he
   has agreed with. Exemplars from the learner's own history are Sadler's "tacit knowledge" made explicit.
2. **Quote first, judge second.** Pass 1 extracts verbatim spans relevant to each standard, with turn refs
   and no scoring. Pass 2 scores each span against the marker ladder with anchors in context. Pass 3 gives
   the per-standard holistic judgment, citing pass-2 scores. Quotes must be verbatim: verify them with a
   string match against the transcript and drop any judgment whose quote doesn't match.
3. **Score structure, not length** (verbosity bias). The marker text should say what a short relational
   answer looks like. Include a terse relational anchor and a long multistructural one.
4. **Blind the assessor to the tutor's per-turn tags**, then reconcile. That makes the two judgments
   independent (two raters).
5. **Two passes with shuffled anchor order** (position bias). Accept a level only if both agree. Otherwise
   record "between M and R" with both quotes and let Phil decide.
6. **A calibration set**: ~10–15 transcript excerpts that Phil labels himself once. Re-run the assessor on
   them whenever the prompt or markers change, and track agreement (exact + adjacent-level, or Cohen's κ).
   This is rater training (Jonsson & Svingby) for a model.
7. **Analytic per standard, then holistic.** Never score "understands SQS" in one go.
8. **The learner audits** (already a norm): every judgment shows its quotes, so Phil can strike one. Struck
   judgments become negative anchors.

### 4.4 Voice-transcript specifics
- Ask for **prediction, then confidence, then why** as separate utterances (Ericsson & Simon level 2 vs
  level 3). The transcript then segments cleanly into predict and explain spans.
- Treat **self-repair** ("wait, no, the extension died with the pod, so 40 plus 30") as positive evidence of a
  relational model, and quote the repaired form.
- **ASR errors on jargon** ("D.L.Q.", "receipt handle" → "receipt candle"): the assessor judges the mechanism,
  never the lexical form. Conventions are *told* anyway (SKILL.md).
- **Thinking aloud during an invent rung** is process data. Tag the order of considerations (did he reason
  about crash before slowness?), not just the final rule.
- **Keep the explicit confidence ask.** Prosody and hesitation are not reliable confidence measures, and
  nothing in this literature licenses inferring them.

---

## 5. Draft standards for `sqs-visibility-timeout` (aligned with the five stations)

SOLO markers: **U** unistructural, **M** multistructural, **R** relational (the target), **EA** extended
abstract. Anchors are *illustrative* drafts to replace with Phil's real quotes. Each standard lists the
misconceptions that cap it (the distractor bank).

### S1. Explain why every SQS message can be processed more than once
*Can-do:* given any consumer timeline, say whether a duplicate is possible and why, starting from "receive
hides, only delete removes."
Concepts: `sqs-in-flight-invisible`, `sqs-at-least-once` · Stations 1 · Rungs R1.1, R1.2
Authorities: AWS visibility timeout; AWS at-least-once (server-copy redelivery, "design … idempotent"); EIP
Guaranteed Delivery and Idempotent Receiver; Kleppmann ch. 11; Saltzer et al.
- **U:** "SQS can deliver duplicates." (a fact, no mechanism)
- **M:** "Receive hides it for 30s; if you don't delete it, it comes back; delete removes it." (correct parts,
  not linked to *why the queue can't know*)
- **R:** "The queue only learns 'done' from DeleteMessage, so 'did the work and died before delete' looks
  exactly like 'never did it'. It has to redeliver, and the side effect happens twice." Must be paired with
  a correct R1.2-type prediction on a new crash point.
- **EA:** generalizes: "any ack-after-effect protocol has this window; moving the ack before the effect
  trades duplicates for loss", or names AWS's second source (an unavailable replica during delete) as the same
  class.
- Caps: *"received = removed"* (pre); *"a successful handler means no duplicate"* (U/M); *"duplicates only
  come from crashes"* (M, misses the AWS infrastructure case).

### S2. Predict when an undeleted message next becomes visible after a success, throw, retry or crash
*Can-do:* given receive and extension times and the handler outcome, compute the reappearance time from the
deadline rule (last receive or extend + timeout).
Concepts: `throw-waits-out-visibility`, `crash-recovery-is-visibility` (+ opener `ttl-vs-renewal-interval`)
· Station 2 · Rungs O1, R2.1–R2.3
Authorities: AWS visibility timeout ("Handling failures"); ChangeMessageVisibility API (relative to call;
VisibilityTimeout=0 releases); ReceiveMessage (failed receive)
- **U:** "A thrown job comes back after the timeout."
- **M:** gets single cases right (throw → ~30s; crash → ~30s) as separate rules, without the common deadline
  model; misses the case where the throw comes after an extension.
- **R:** a single rule, *"deadline = last receive-or-extend + 30; nothing else moves it"*, applied correctly
  to an unseen timeline (throw at t=25 after an extension at t=20 → visible at t=50; crash after the last
  extension at t=45 → t=75). Explains why the extension interval doesn't set recovery time.
- **EA:** proposes and justifies changing behavior, e.g. "on a known-transient throw, ChangeMessageVisibility(0)
  to retry now, or N for backoff", weighing the receive-count cost (links to S4); or maps it onto croon TTL
  unprompted.
- Caps: *"a throw retries immediately"*; *"recovery time = renewal interval"* (open miss
  `ttl-vs-renewal-interval`); *"{retry:true} differs from a throw to SQS"*.

### S3. Distinguish holding a message from controlling its execution, and size a heartbeat to the timeout
*Can-do:* show that when a visibility lapses a second consumer can run the message while the first is still
running, and choose an extension interval with enough margin.
Concepts: `visibility-heartbeat`, `visibility-is-not-a-job-timeout` (+ `lock-guards-holders-not-execution`) ·
Station 3 · Rungs O2, R3.1–R3.3 (invent)
Authorities: AWS visibility (heartbeat best practice; "no absolute guarantee … during the visibility timeout
period"); ReceiveMessage "Important" (duplicates; delete fails after lapse; "safe threshold"); Kleppmann
ch. 8 and the 2016 fencing essay
- **U:** "Extend the visibility so it doesn't time out."
- **M:** lays out the deadline column for a long job correctly (R3.1), but predicts that a failed extension
  *stops* or *fails* the first handler, or that the second worker waits.
- **R:** "Visibility only decides who gets *handed* the message. When it lapses, W2 receives a copy and both
  run; nothing stops W1, and W1's later delete or extend may fail. So the margin per beat must cover one
  failed beat plus call latency." Must agree with a correct R3.2-type prediction on a new timeline.
- **EA:** names the general pattern, *a lease doesn't fence: only the resource can reject a stale holder*, and
  proposes a fencing or idempotency check at the side-effect (links to S5); or transfers it to croon or any
  lease without prompting.
- Caps (threshold concept, expect mimicry): *"visibility timeout = job timeout"*; *"the lock / lease prevents
  concurrent execution"* (open miss); *"extending adds N to the old deadline"* (vs. now + N).

### S4. Trace a repeatedly failing message to the dead-letter queue and set the retry budget
*Can-do:* given failure timing, compute receive counts and when a message lands in `dlq-<queue>`; explain
what counts as a receive; choose a maxReceiveCount and DLQ retention for a queue.
Concepts: `receive-count-redrive` · Station 4 · Rungs R4.1, R4.2
Authorities: AWS DLQ guide (maxReceiveCount semantics; "high enough"; retention from original enqueue);
ReceiveMessage (`ApproximateReceiveCount`; failed receive); EIP Dead Letter Channel
- **U:** "After 3 failures it goes to the DLQ."
- **M:** builds the timeline (receives at ~0/30/60) but treats `{retry:true}` or a deliberate wait-and-retry as
  not counting, or can't say why the DLQ exists.
- **R:** "Every receive without a delete counts, whatever the handler meant. After the 3rd it isn't delivered
  again: it moves to the DLQ. So maxReceiveCount × visibility is the total retry window, and a job that
  *intends* to retry by not deleting burns the same budget as a crash."
- **EA:** sets policy with reasons: a higher count for deliberately polling jobs vs 1 for non-retriable
  deployers (monotoad override); DLQ retention > source retention because the age is measured from the
  original enqueue; DLQ alarm and redrive as the operational loop.
- Caps: *"DLQ after N throws only"*; *"DLQ age restarts on move"* (true only for FIFO).

### S5. Design a consumer so redelivery and retries cannot duplicate a side effect
*Can-do:* for a handler with an external side effect, show where duplicates arise across nested retry layers,
and place an idempotency key so that every retry of the same logical operation reuses it.
Concepts: `timeout-doesnt-cancel-remote`, `idempotency-key-minted-before-retry-boundary`, `nested-retry-layers`
· Station 5 · Rungs R5.1, R5.2 (invent), R5.3; critique row on `jobs/svix-dispatch.ts`
Authorities: AWS at-least-once ("design … idempotent"); EIP Idempotent Receiver (dedup vs idempotent
semantics); AWS Builders' Library (client token reused across retries; equivalent response; parameter
mismatch); Saltzer, Reed & Clark (end-to-end duplicate suppression); Kleppmann ch. 11–12 (operation
identifiers)
- **U:** "Use an idempotency key."
- **M:** knows that the svix client sends a key and that SQS redelivers, but treats them as separate facts:
  proposes a per-call or per-handler-run key, or a payload hash, without testing it against the contrast
  cases.
- **R:** "A key dedupes only the retries that reuse it. SQS redelivery re-runs the handler, so a key minted
  inside the handler is new each time. Mint it once at enqueue and carry it in the message. Also, my timeout
  doesn't cancel their write, so 'it threw' doesn't mean 'it didn't happen'." Must survive the three R5.2
  contrast cases unaided.
- **EA:** the layered model as a general principle, "each retry layer dedupes only inside the scope where its
  key was minted; mint at the outermost boundary, and an inner timeout must outlast the server's idempotency
  lock". Also knows the retention-window and parameter-mismatch caveats (Builders' Library), or critiques real
  code against it.
- Caps: *"timing out the promise cancels the request"*; *"a payload hash is a safe key"* (collapses genuinely
  distinct identical events); *"the SDK's auto key covers SQS redelivery"*.

**Alignment notes for the plan file** (no changes made):
- The plan's F3 (now + N) and F4 (maxReceiveCount) are confirmed by AWS primary docs; cite them there.
- Add to S1/R1.2 one sentence on AWS's non-crash duplicate source, so the summit isn't "duplicates come from
  crashes".
- R3.2's "stale handle" detail: AWS says a delete after the lapse "fails with an error" (FIFO paragraph of
  ReceiveMessage). Tell it as a fact if asked.
- AWS's `VisibilityTimeout=0` release and the "changed visibility isn't remembered on the next receive" note
  are good *told facts* for S2/S4 (EA material).
- The SOLO markers make the plan's summits checkable: each station summit's restate sentence should be scored
  against the R marker, and the next rung chosen to test it on an unseen timeline.

---

## 6. Gaps and unverified items
- No message-queue / distributed-delivery concept inventory or assessment study exists that I could find. The
  §5 misconception lists are home-made distractor banks.
- [M] items to verify before quoting: du Boulay (1986) title/venue; Black & Wiliam (1998) *Assessment in
  Education* title; Messick's three questions' wording; Chi (2008) chapter; ECD model definitions' exact
  wording; Kleppmann chapter/section titles and the "operation identifiers" section; Wiliam's "hinge
  questions"; Brookhart (2013) book; NRC (2007) *Taking Science to School*.
- The ICAP replication record is mixed. Don't treat its ordering as a scoring rule.
