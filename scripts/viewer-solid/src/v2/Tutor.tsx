// The tutor — the `tutor` skill in the browser, around the learner's concept graph rather than a
// transcript (srv/tutor.py, scripts/learning.py).
//
//   home     what's due, the topics (paths through the graph, shaded by depth), open questions,
//            the sessions this browser keeps, terminal sessions to pick up
//   session  the topic's map ("you are here") · the current rung (earlier ones fold) · pinned code
//   drawer   one concept: its depth and the evidence behind it (each credit correctable), links, questions
import { createEffect, createMemo, For, Index, on, onCleanup, onMount, Show, type JSX } from "solid-js";
import Key from "./Key";
import { ago, CONFIDENCES, CREDITS, LEVEL_HINT, LEVELS, rungsOf, segments, askOf, questionOf, latest, pipsTitle, type Evidence, type Mastery, type Session } from "./lesson";
import { model } from "./model";
import { routeArg } from "./router";
import { renderMarkdown } from "./review/markdown";
import { highlight, langOf } from "./review/highlight";
import { bind, dispatch } from "./runner";
import { armed, setCursor } from "./ui";
import { ckey, skey, touched, tutor } from "./tutoring";

const LABEL = "text-[11px] font-normal uppercase tracking-[0.14em] text-ink-faint";
const LINK = "text-[11px] text-ink-faint hover:text-gold-leaf";

function Pips(props: { m?: Mastery; size?: "sm" | "md" }) {
  const box = () => (props.size === "md" ? "h-[9px] w-[9px]" : "h-[7px] w-[7px]");
  return (
    <span class="inline-flex shrink-0 items-center gap-[2px]" title={props.m ? pipsTitle(props.m) : ""}>
      <For each={LEVELS}>
        {(_, i) => (
          <span
            class={`${box()} rounded-[1px] border`}
            classList={{
              "border-gold-leaf bg-gold-leaf": (props.m?.held ?? 0) > i(),
              "border-gold-leaf bg-gold-leaf/25": (props.m?.held ?? 0) <= i() && (props.m?.depth ?? 0) > i(),
              "border-gold-deep bg-transparent": (props.m?.depth ?? 0) <= i() && (props.m?.assisted ?? 0) > i(),
              "border-rule bg-transparent": (props.m?.assisted ?? 0) <= i(),
            }}
          />
        )}
      </For>
      <Show when={props.m?.open_miss}>
        <span class="ml-[3px] h-[5px] w-[5px] rounded-full bg-del" classList={{ "ring-2 ring-del/40": props.m?.miss_confidence === "high" }} />
      </Show>
    </span>
  );
}

/** A concept: its depth in pips, its name; a click opens it. On a session's map it's a cursor row. */
function Chip(props: { id: string; here?: boolean; wrap?: boolean; row?: boolean }) {
  const c = () => tutor.concept(props.id);
  const on = () => !!props.row && model.selected() === ckey(props.id);
  return (
    <button
      data-row={props.row ? ckey(props.id) : undefined}
      class="inline-flex max-w-full items-center gap-1.5 border px-2 py-[3px] text-left text-[12px] leading-tight transition-colors duration-150 hover:border-gold-deep"
      classList={{
        "border-gold-leaf bg-gold-wash text-ink": !!props.here,
        "border-ink-faint bg-vellum-raise text-ink": on() && !props.here,
        "border-rule text-ink-dim hover:text-ink": !props.here && !on(),
      }}
      title={c()?.statement}
      onClick={bind("tutor.concept", props.id)}
    >
      <Pips m={c()?.mastery} />
      <span classList={{ truncate: !props.wrap }}>{tutor.nameOf(props.id)}</span>
      <Show when={c()?.blocked_by?.length}>
        <span class="shrink-0 text-[11px] text-ink-faint" title={`needs first (never shown unaided): ${(c()?.blocked_by ?? []).map(tutor.nameOf).join(", ")}`}>
          ⊘
        </span>
      </Show>
    </button>
  );
}

/** The selected row's frame, the same on every page. */
const rowClass = (on: boolean) => (on ? "border-gold-leaf bg-gold-wash" : "border-transparent hover:bg-vellum-raise");

// ── home ──────────────────────────────────────────────────────────────────

function Continue(props: { s: Session }) {
  const last = () => [...props.s.msgs].reverse().find((m) => m.role === "tutor" && m.text.trim());
  const here = () => latest(props.s.msgs, "rung")?.concept;
  const waiting = () => props.s.msgs[props.s.msgs.length - 1]?.role === "tutor";
  const rungs = () => props.s.msgs.filter((m) => m.role === "tutor").length;
  return (
    <section class="mb-10 border border-gold-deep bg-gold-wash px-5 py-4">
      <div class={`${LABEL} mb-2`}>continue where you left off</div>
      <div class="mb-2 flex items-baseline gap-3">
        <h2 class="m-0 min-w-0 flex-1 truncate font-display text-[20px] font-normal text-ink">{tutor.titleOf(props.s)}</h2>
        <span class="shrink-0 text-[11px] text-ink-faint">
          rung {rungs()} · {ago(touched(props.s))}
        </span>
      </div>
      <Show when={here()}>{(id) => <div class="mb-2"><Chip id={id()} here /></div>}</Show>
      <Show when={last()}>
        {(m) => (
          <p class="m-0 mb-3 font-[Georgia,serif] text-[15px] leading-relaxed text-ink-dim">
            <span class={LABEL}>{waiting() ? "waiting on you · " : "last question · "}</span>
            {questionOf(m().text)}
          </p>
        )}
      </Show>
      <button class="border border-gold-deep bg-vellum-night px-4 py-1 font-display text-[15px] text-gold-leaf hover:bg-vellum-edge" onClick={bind("tutor.open", props.s.id)}>
        continue
      </button>
    </section>
  );
}

function Home() {
  let input: HTMLInputElement | undefined;
  onMount(() => {
    tutor.listTerminal();
    tutor.setBox(() => input?.focus());
    onCleanup(() => tutor.setBox(undefined));
  });
  const shown = () => (tutor.allDue() ? tutor.due() : tutor.due().slice(0, 8));
  const topics = createMemo(() => Object.values(tutor.learn()?.topics ?? {}).sort((a, b) => (b.updated ?? "").localeCompare(a.updated ?? "")));
  return (
    <div class="mx-auto grid max-w-[1180px] grid-cols-[minmax(0,1fr)_320px] gap-x-12 px-4 pl-11 max-[1060px]:grid-cols-1 max-[640px]:pl-4">
      <div class="min-w-0">
        <Show when={tutor.recent()[0]}>{(s) => <Continue s={s()} />}</Show>
        <h1 class="m-0 mb-4 font-display text-[26px] font-normal leading-tight text-ink">What do you want to dig into?</h1>
        <form
          class="mb-3 flex gap-2"
          onSubmit={(e) => {
            e.preventDefault();
            dispatch("tutor.start", "key", { event: e });
          }}
        >
          <input
            ref={input}
            class="min-w-0 flex-1 border border-rule bg-vellum-raise px-3 py-2 text-[14px] text-ink outline-none focus:border-gold-deep"
            placeholder="a PR number, a branch, a file, or a concept"
            autocomplete="off"
            value={tutor.target()}
            onInput={(e) => tutor.setTarget(e.currentTarget.value)}
          />
          <button type="button" class="border border-gold-deep bg-gold-wash px-4 font-display text-[15px] text-gold-leaf hover:bg-vellum-edge" onClick={bind("tutor.start")}>
            start
          </button>
        </form>
        <p class="m-0 mb-10 text-[11px] text-ink-faint">
          <Key id="tutor.write" /> types here · starting asks the tutor, which reads the code first
        </p>
        <Show when={tutor.error() || tutor.learnErr()}>
          <p class="m-0 mb-6 text-[12px] text-del">{tutor.error() || tutor.learnErr()}</p>
        </Show>

        <section class="mb-10">
          <div class="mb-1 flex items-baseline gap-3">
            <h2 class="m-0 font-display text-[19px] font-normal text-ink">Due</h2>
            <span class="text-[11px] text-ink-faint">{tutor.due().length} concepts</span>
          </div>
          <p class="m-0 mb-2 text-[12px] text-ink-faint">open misconceptions first, then what you've shown only with help, then whatever's gone longest unchecked</p>
          <For each={shown()}>
            {(id) => {
              const c = () => tutor.concept(id);
              const on = () => model.selected() === ckey(id);
              return (
                <div data-row={ckey(id)} class={`flex cursor-default items-center gap-3 border-l-2 px-3 py-1.5 transition-colors duration-150 ${rowClass(on())}`} onClick={bind("cursor.set", ckey(id))} onDblClick={bind("tutor.concept", id)}>
                  <Pips m={c()?.mastery} />
                  <span class="min-w-0 flex-1">
                    <span class="block truncate text-[14px]" classList={{ "text-gold-leaf": on(), "text-ink": !on() }}>
                      {tutor.nameOf(id)}
                    </span>
                    <span class="block truncate text-[11.5px] text-ink-faint">
                      <Show when={c()?.mastery.miss_confidence === "high"}>
                        <span class="mr-1.5 text-del">confident miss ·</span>
                      </Show>
                      {c()?.mastery.reason}
                    </span>
                  </span>
                  <Show when={on()}>
                    <button class="shrink-0 text-[11px] text-ember hover:text-gold-leaf" onClick={bind("tutor.retest", id)}>
                      <Key id="tutor.retest" /> re-test cold
                    </button>
                  </Show>
                </div>
              );
            }}
          </For>
          <Show when={tutor.due().length > 8}>
            <button class={`mt-2 ${LINK}`} onClick={bind("tutor.due.all")}>
              {tutor.allDue() ? "fewer" : `all ${tutor.due().length}`}
            </button>
          </Show>
        </section>

        <section class="mb-10">
          <h2 class="m-0 mb-1 font-display text-[19px] font-normal text-ink">Topics</h2>
          <p class="m-0 mb-4 text-[12px] text-ink-faint">paths through one graph — the same idea met in two topics is one concept, linked as an analog</p>
          <For each={topics()}>
            {(t) => (
              <article class="mb-5 border border-rule px-4 py-3">
                <header class="mb-2 flex items-baseline gap-3">
                  <h3 class="m-0 min-w-0 flex-1 truncate font-display text-[16px] font-normal text-ink">{t.title}</h3>
                  <span class="shrink-0 text-[11px] text-ink-faint" title="at explain or deeper — held: two separate days · shown: once">
                    {t.progress.held} held · {t.progress.shown ?? t.progress.held} shown / {t.progress.total}
                  </span>
                  <button class="shrink-0 text-[11px] text-ember hover:text-gold-leaf" onClick={bind("tutor.topic", t.id)}>
                    continue
                  </button>
                </header>
                <div class="relative mb-3 h-[3px] bg-rule">
                  <div class="absolute inset-y-0 left-0 bg-gold-deep" style={{ width: `${t.progress.total ? (100 * (t.progress.shown ?? t.progress.held)) / t.progress.total : 0}%` }} />
                  <div class="absolute inset-y-0 left-0 bg-gold-leaf" style={{ width: `${t.progress.total ? (100 * t.progress.held) / t.progress.total : 0}%` }} />
                </div>
                <For each={t.stages}>
                  {(st) => (
                    <div class="mb-2 grid grid-cols-[140px_minmax(0,1fr)] gap-3 max-[640px]:grid-cols-1">
                      <div class="pt-1 text-[11.5px] text-ink-faint">{st.name}</div>
                      <div class="flex flex-wrap gap-1.5">
                        <For each={st.concepts}>{(id) => <Chip id={id} />}</For>
                      </div>
                    </div>
                  )}
                </For>
                <Show when={t.source}>
                  <div class="mt-1 text-[10.5px] text-ink-faint">{t.source}</div>
                </Show>
              </article>
            )}
          </For>
        </section>
      </div>

      <aside class="min-w-0 max-[1060px]:mt-2">
        <section class="mb-8">
          <h2 class="m-0 mb-2 font-display text-[17px] font-normal text-ink">Your open questions</h2>
          <Show when={tutor.openQuestions().length} fallback={<p class="m-0 text-[12px] text-ink-faint">none open — ask one from any concept</p>}>
            <For each={tutor.openQuestions()}>
              {(q) => (
                <div class="border-t border-rule py-2">
                  <div class="text-[13px] leading-snug text-ink">{q.text}</div>
                  <div class="mt-1 flex gap-3">
                    <Show when={q.concept}>
                      <button class={LINK} onClick={bind("tutor.concept", q.concept)}>
                        {tutor.nameOf(q.concept)}
                      </button>
                    </Show>
                    <button class="text-[11px] text-ember hover:text-gold-leaf" onClick={bind("tutor.pursue", q.id)}>
                      pursue
                    </button>
                    <button class={LINK} onClick={bind("tutor.question.close", q.id)}>
                      answered
                    </button>
                  </div>
                </div>
              )}
            </For>
          </Show>
        </section>

        <Show when={tutor.sessions.length}>
          <section class="mb-8">
            <h2 class="m-0 mb-2 font-display text-[17px] font-normal text-ink">Sessions</h2>
            <For each={tutor.recent()}>
              {(s) => {
                const on = () => model.selected() === skey(s.id);
                const arming = () => armed() === `forget ${s.id}`;
                return (
                  <div data-row={skey(s.id)} class={`flex cursor-default items-baseline gap-2 border-l-2 px-2 py-1.5 transition-colors duration-150 ${rowClass(on())}`} onClick={bind("cursor.set", skey(s.id))} onDblClick={bind("tutor.open", s.id)}>
                    <span class="min-w-0 flex-1 truncate text-[12.5px]" classList={{ "text-gold-leaf": on(), "text-ink-dim": !on() }} title={s.target}>
                      {tutor.titleOf(s)}
                    </span>
                    <span class="shrink-0 text-[10.5px] text-ink-faint">
                      {s.msgs.filter((m) => m.role === "tutor").length} · {ago(touched(s))}
                    </span>
                    <Show when={on()}>
                      <button class="shrink-0 text-[11px]" classList={{ "text-del": arming(), "text-ink-faint hover:text-del": !arming() }} title="forget this session (its evidence stays in the graph)" onClick={bind("tutor.forget", s.id)}>
                        <Key id="tutor.forget" /> {arming() ? "again forgets it" : "forget"}
                      </button>
                    </Show>
                  </div>
                );
              }}
            </For>
          </section>
        </Show>

        <Show when={tutor.pickable().length}>
          <section class="mb-8">
            <h2 class="m-0 mb-1 font-display text-[17px] font-normal text-ink">Pick up from the terminal</h2>
            <p class="m-0 mb-2 text-[11.5px] text-ink-faint">continues here as a copy; the terminal session is left alone</p>
            <For each={tutor.pickable()}>
              {(t) => (
                <button class="group block w-full border-t border-rule py-2 text-left" onClick={bind("tutor.pickup", t.session)}>
                  <span class="block truncate text-[13px] text-ink group-hover:text-gold-leaf">{t.target || t.cwd.split("/").pop()}</span>
                  <span class="block text-[11px] text-ink-faint">
                    {t.cwd.split("/").pop()} · {t.answers} answers
                  </span>
                </button>
              )}
            </For>
          </section>
        </Show>
      </aside>
    </div>
  );
}

// ── a session ─────────────────────────────────────────────────────────────

function SessionMap(props: { s: Session }) {
  const topic = () => (props.s.topic ? tutor.learn()?.topics[props.s.topic] : undefined);
  return (
    <nav class="flex min-h-0 flex-col overflow-y-auto border-r border-rule px-4 py-3">
      <Show when={topic()} fallback={<p class="m-0 text-[12px] leading-snug text-ink-faint">no map yet — the tutor draws one once it has read the material</p>}>
        {(t) => (
          <>
            <div class={`${LABEL} mb-1`}>map</div>
            <div class="mb-1 font-display text-[15px] leading-snug text-ink">{t().title}</div>
            <div class="mb-4 text-[10.5px] text-ink-faint">
              {t().progress.held} held · {t().progress.shown ?? t().progress.held} shown / {t().progress.total}
            </div>
            <For each={t().stages}>
              {(st) => (
                <div class="mb-4">
                  <div class="mb-1.5 text-[11px] text-ink-faint">{st.name}</div>
                  <div class="flex flex-col gap-1">
                    <For each={st.concepts}>{(id) => <Chip id={id} here={tutor.here() === id} wrap row />}</For>
                  </div>
                </div>
              )}
            </For>
          </>
        )}
      </Show>
      <div class="mt-auto pt-4 text-[10px] leading-relaxed text-ink-faint">
        <div class="flex items-center gap-1.5">
          <Pips m={{ held: 1, depth: 2, assisted: 3, level: "", evidence: 0, last: "", due: false, reason: "", open_miss: "" }} /> predict · explain · transfer · critique
        </div>
        <div>solid held (two days) · faint shown once · outline only with help · red an open misconception · ⊘ needs a prerequisite first</div>
      </div>
    </nav>
  );
}

function Turn(props: { text: string; latest: boolean }) {
  const segs = createMemo(() => segments(props.text));
  return (
    <div class="mb-5">
      <For each={segs()}>
        {(seg): JSX.Element => {
          switch (seg.kind) {
            case "prose":
              return <div class="md wk-prose" innerHTML={renderMarkdown(seg.text)} />;
            case "pin":
              return (
                <button class="my-1.5 inline-flex max-w-full items-baseline gap-2 border border-rule px-2 py-0.5 text-[11px] text-ink-dim hover:border-gold-deep hover:text-gold-leaf" title="show in the code pane" onClick={bind("tutor.pin", undefined, "click", seg.pin)}>
                  <span class="truncate">{seg.pin.path}</span>
                  <Show when={seg.pin.lines}>
                    <span class="shrink-0 text-ink-faint">
                      L{seg.pin.lines![0]}–{seg.pin.lines![1]}
                    </span>
                  </Show>
                </button>
              );
            case "options":
              return (
                <div class="my-3 flex flex-wrap gap-2">
                  <For each={seg.options}>
                    {(o) => (
                      <button
                        class="border border-gold-deep bg-gold-wash px-3 py-1 text-left text-[13px] text-ink hover:bg-vellum-edge disabled:opacity-40"
                        disabled={!props.latest}
                        title="put this in the answer box — then say why"
                        onClick={bind("tutor.option", undefined, "click", o)}
                      >
                        {o}
                      </button>
                    )}
                  </For>
                </div>
              );
            case "rung":
              return (
                <button class="mb-2 inline-flex items-center gap-2 text-[10.5px] text-ink-faint hover:text-gold-leaf" onClick={bind("tutor.concept", seg.concept)}>
                  <Pips m={tutor.concept(seg.concept)?.mastery} />
                  <span>
                    testing {tutor.nameOf(seg.concept)} · {seg.level}
                    {seg.rung === "invent" ? " · invent the rule" : ""}
                    {seg.via ? ` · via ${tutor.nameOf(seg.via)}` : ""}
                    {seg.contrastOf ? " · contrast re-test of a miss" : ""}
                    {seg.confidence ? " · rate your confidence" : ""}
                  </span>
                </button>
              );
            case "evidence":
              return (
                <div class="mb-3 flex flex-col gap-1">
                  <For each={seg.items}>
                    {(e) => (
                      <button
                        class="flex items-baseline gap-2 text-left text-[11px] leading-snug hover:text-gold-leaf"
                        classList={{ "text-add": e.outcome !== "miss", "text-del": e.outcome === "miss" }}
                        title="recorded in your graph — open the concept to audit it"
                        onClick={bind("tutor.concept", e.concept)}
                      >
                        <span>{e.outcome === "miss" ? "✗" : "✓"}</span>
                        <span class="min-w-0">
                          {tutor.nameOf(e.concept)} · {e.level} · {e.credit}
                          {e.confidence ? ` · ${e.confidence} confidence` : ""}
                          {e.via ? ` · via ${tutor.nameOf(e.via)}` : ""}
                          <Show when={e.note}>
                            <span class="text-ink-faint"> — {e.note}</span>
                          </Show>
                          <Show when={e.contrast}>
                            <span class="block text-ink-faint">re-test with: {e.contrast}</span>
                          </Show>
                        </span>
                      </button>
                    )}
                  </For>
                </div>
              );
            case "map":
              return (
                <div class="mb-2 text-[10.5px] text-ink-faint">
                  map drawn · {seg.count} concepts in {seg.title}
                </div>
              );
            case "restate":
              return (
                <button class="my-2 block text-left text-[13.5px] text-gold-leaf hover:underline" onClick={bind("tutor.concept", seg.concept)}>
                  <span class={LABEL}>in your words · {tutor.nameOf(seg.concept)} </span>“{seg.text}”
                </button>
              );
            case "question":
              return (
                <div class="my-2 text-[11px] text-ink-faint">
                  ? your question, kept open{seg.concept ? ` on ${tutor.nameOf(seg.concept)}` : ""}: <span class="text-ink-dim">{seg.text}</span>
                </div>
              );
            default:
              return null;
          }
        }}
      </For>
    </div>
  );
}

function EvidenceRow(props: { e: Evidence; showConcept?: boolean }) {
  const edit = (fields: Partial<Evidence>) => dispatch("tutor.evidence.edit", "click", { target: props.e.id, arg: fields });
  const SELECT = "border border-rule bg-vellum-night px-1 py-0.5 text-[11px] text-ink-dim";
  const arming = () => armed() === `cut ${props.e.id}`;
  return (
    <div class="group border-t border-rule py-2 first:border-t-0">
      <div class="flex flex-wrap items-center gap-1.5">
        <button
          class="text-[12px]"
          classList={{ "text-add": props.e.outcome === "hit", "text-del": props.e.outcome === "miss" }}
          title="toggle hit / miss"
          onClick={bind("tutor.evidence.edit", props.e.id, "click", { outcome: props.e.outcome === "hit" ? "miss" : "hit" })}
        >
          {props.e.outcome === "miss" ? "✗" : "✓"}
        </button>
        <Show when={props.showConcept}>
          <button class="text-[12.5px] text-ink hover:text-gold-leaf" onClick={bind("tutor.concept", props.e.concept)}>
            {tutor.nameOf(props.e.concept)}
          </button>
        </Show>
        <select class={SELECT} value={props.e.level} title="level" onChange={(ev) => edit({ level: ev.currentTarget.value })}>
          <For each={LEVELS}>{(l) => <option value={l}>{l}</option>}</For>
        </select>
        <select class={SELECT} value={props.e.credit} title="credit" onChange={(ev) => edit({ credit: ev.currentTarget.value })}>
          <For each={CREDITS}>{(c) => <option value={c}>{c}</option>}</For>
        </select>
        <select class={SELECT} value={props.e.confidence ?? ""} title="confidence, rated before the reveal" onChange={(ev) => edit({ confidence: ev.currentTarget.value })}>
          <option value="">no rating</option>
          <For each={CONFIDENCES}>{(c) => <option value={c}>{c}</option>}</For>
        </select>
        <span class="text-[10.5px] text-ink-faint">
          {props.e.at}
          {props.e.rung === "invent" ? " · invent" : ""}
          {props.e.via ? ` · via ${tutor.nameOf(props.e.via)}` : ""}
        </span>
        <span class="flex-1" />
        <button
          class="text-[11px]"
          classList={{ "text-del": arming(), "text-ink-faint opacity-0 hover:text-del group-hover:opacity-100": !arming() }}
          title="cut this evidence"
          onClick={bind("tutor.evidence.cut", props.e.id)}
        >
          {arming() ? "again cuts it" : "✕"}
        </button>
      </div>
      <Show when={props.e.note}>
        <div class="mt-0.5 text-[12.5px] leading-snug text-ink-dim">{props.e.note}</div>
      </Show>
      <Show when={props.e.contrast}>
        <div class="mt-0.5 text-[12px] leading-snug text-ink-faint">re-test with: {props.e.contrast}</div>
      </Show>
    </div>
  );
}

function SessionView(props: { s: Session }) {
  let scroller: HTMLDivElement | undefined;
  let box: HTMLTextAreaElement | undefined;
  onMount(() => {
    tutor.setBox(() => box?.focus());
    onCleanup(() => tutor.setBox(undefined));
  });
  const rungs = createMemo(() => rungsOf(props.s.msgs));
  const current = () => rungs()[rungs().length - 1];
  const earlier = () => rungs().slice(0, -1);
  const prevAnswer = () => {
    const i = current()?.tutorIdx ?? 0;
    return props.s.msgs[i - 1]?.role === "me" ? props.s.msgs[i - 1].text : "";
  };
  const mine = createMemo(() => (tutor.learn()?.evidence ?? []).filter((e) => e.session === props.s.id));
  // the session's newest pin wins when it changes; one chosen from a turn or the drawer stays until then
  const newestPin = createMemo(() => JSON.stringify(latest(props.s.msgs, "pin")?.pin ?? null));
  createEffect(on(newestPin, (p) => tutor.showPin(JSON.parse(p) ?? undefined)));
  // the cursor starts on the concept the rung tests
  createEffect(on(tutor.here, (id) => id && setCursor(ckey(id))));
  // a new rung reads from its top — never chase the bottom while it streams
  createEffect(
    on(
      () => current()?.tutorIdx,
      () => {
        queueMicrotask(() => scroller?.scrollTo({ top: 0 }));
        tutor.setConfidence(undefined);
        tutor.setAskedConfidence(false);
      },
    ),
  );
  return (
    <div
      class="grid h-[calc(100vh-3.5rem)] border-t border-rule max-[900px]:h-auto max-[900px]:grid-cols-1"
      classList={{
        "grid-cols-[240px_minmax(0,1fr)_minmax(0,1fr)] max-[1200px]:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]": !!tutor.pin(),
        "grid-cols-[240px_minmax(0,760px)] max-[1200px]:grid-cols-[minmax(0,1fr)]": !tutor.pin(),
      }}
    >
      <div class="flex min-h-0 max-[1200px]:hidden">
        <SessionMap s={props.s} />
      </div>
      <div class="flex min-h-0 flex-col border-r border-rule max-[900px]:border-r-0">
        <header class="flex items-baseline gap-4 border-b border-rule px-5 py-2 text-[11px]">
          <span class="min-w-0 flex-1 truncate font-display text-[15px] text-ink" title={props.s.target}>
            {tutor.titleOf(props.s)}
          </span>
          <button class="hidden shrink-0 text-ink-faint hover:text-gold-leaf max-[1200px]:inline" onClick={bind("tutor.map")}>
            map <Key id="tutor.map" />
          </button>
          <button class="shrink-0 hover:text-gold-leaf" classList={{ "text-gold-leaf": tutor.evidenceOpen(), "text-ink-faint": !tutor.evidenceOpen() }} title="what this session has recorded about you — audit it" onClick={bind("tutor.evidence")}>
            evidence · {mine().length} <Key id="tutor.evidence" />
          </button>
          <button class="shrink-0 text-ink-faint hover:text-ember disabled:opacity-40" disabled={tutor.streaming()} title="ask for the consolidation: each principle said plainly" onClick={bind("tutor.wrap")}>
            wrap up <Key id="tutor.wrap" />
          </button>
        </header>
        <Show when={tutor.mapOpen()}>
          <div class="max-h-[50vh] overflow-y-auto border-b border-rule min-[1201px]:hidden">
            <SessionMap s={props.s} />
          </div>
        </Show>
        <Show when={tutor.evidenceOpen()}>
          <div class="max-h-[45vh] overflow-y-auto border-b border-rule bg-vellum-raise px-5 py-3">
            <div class={`${LABEL} mb-2`}>recorded this session — correct or cut anything over-credited</div>
            <Show when={mine().length} fallback={<p class="m-0 text-[12px] text-ink-faint">nothing yet — evidence lands after each answer</p>}>
              <For each={mine()}>{(e) => <EvidenceRow e={e} showConcept />}</For>
            </Show>
          </div>
        </Show>

        <div ref={scroller} class="min-h-0 flex-1 overflow-y-auto">
          <Show when={earlier().length}>
            <div class="border-b border-rule">
              <button class="flex w-full items-baseline gap-2 px-5 py-2 text-left text-[11px] text-ink-faint hover:text-ink" onClick={bind("tutor.rungs")}>
                <span>{tutor.historyOpen() ? "▾" : "▸"}</span>
                <span>
                  {earlier().length} earlier {earlier().length === 1 ? "rung" : "rungs"}
                </span>
              </button>
              <Show when={tutor.historyOpen()}>
                <ol class="m-0 list-none p-0 pb-2">
                  <For each={earlier()}>
                    {(r) => (
                      <li>
                        <button class="grid w-full grid-cols-[26px_minmax(0,1fr)] gap-x-2 px-5 py-1 text-left hover:bg-vellum-edge" classList={{ "bg-vellum-edge": tutor.expanded() === r.tutorIdx }} onClick={bind("tutor.rung", String(r.tutorIdx))}>
                          <span class="pt-px text-right text-[11px] text-ink-faint">{r.n}</span>
                          <span class="min-w-0">
                            <span class="block truncate text-[12.5px] text-ink-dim">{askOf(props.s.msgs[r.tutorIdx].text)}</span>
                            <Show when={r.answer}>
                              <span class="block truncate text-[12.5px] text-ink">→ {r.answer}</span>
                            </Show>
                          </span>
                        </button>
                        <Show when={tutor.expanded() === r.tutorIdx}>
                          <div class="mx-5 mb-3 mt-1 border-l-2 border-gold-deep pl-4">
                            <Turn text={props.s.msgs[r.tutorIdx].text} latest={false} />
                            <Show when={r.answer}>
                              <div class="mb-2 whitespace-pre-wrap text-[12.5px] text-ink-dim">you: {r.answer}</div>
                            </Show>
                          </div>
                        </Show>
                      </li>
                    )}
                  </For>
                </ol>
              </Show>
            </div>
          </Show>
          <div data-paint="tutor" class="px-5 py-5">
            <Show when={prevAnswer()}>
              <div class="mb-4 border-l-2 border-rule pl-3 text-[12.5px] leading-snug">
                <span class={LABEL}>you said</span>
                <div class="mt-0.5 whitespace-pre-wrap text-ink-dim">{prevAnswer()}</div>
              </div>
            </Show>
            <Show when={current()}>{(c) => <Turn text={props.s.msgs[c().tutorIdx].text} latest />}</Show>
            <Show when={tutor.streaming() && tutor.status()}>
              <div class="animate-breathe truncate text-[11px] text-ink-faint">{tutor.status()}…</div>
            </Show>
            <Show when={props.s.error}>
              <div class="mt-2 text-[12px] text-del">{props.s.error}</div>
            </Show>
          </div>
        </div>

        <div class="border-t border-rule p-4">
          <textarea
            ref={box}
            class="block w-full resize-none border border-rule bg-vellum-raise px-3 py-2 font-[Georgia,serif] text-[14.5px] leading-relaxed text-ink outline-none focus:border-gold-deep"
            rows={3}
            placeholder={tutor.streaming() ? "…" : "your prediction, your why, or your own question"}
            autocomplete="off"
            value={tutor.draft()}
            onInput={(e) => tutor.setDraft(e.currentTarget.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
                e.preventDefault();
                dispatch("tutor.send", "key", { event: e });
              }
            }}
          />
          <Show when={tutor.wantsConfidence() && !tutor.streaming()}>
            <div class="mt-2 flex flex-wrap items-center gap-2">
              <span class="text-[11px]" classList={{ "text-ember": tutor.askedConfidence() && !tutor.confidence(), "text-ink-faint": !tutor.askedConfidence() || !!tutor.confidence() }}>
                {tutor.askedConfidence() && !tutor.confidence() ? "how sure are you? (↵ again to skip)" : "how sure are you?"}
              </span>
              <For each={CONFIDENCES}>
                {(c) => (
                  <button
                    class="border px-2.5 py-0.5 text-[11px]"
                    classList={{ "border-gold-leaf bg-gold-wash text-gold-leaf": tutor.confidence() === c, "border-rule text-ink-dim hover:border-gold-deep hover:text-ink": tutor.confidence() !== c }}
                    onClick={bind("tutor.confidence", c)}
                  >
                    {c}
                  </button>
                )}
              </For>
            </div>
          </Show>
          <div class="mt-1.5 flex justify-between text-[10.5px] text-ink-faint">
            <span>↵ sends · ⇧↵ a new line · esc leaves the box</span>
            <Show when={tutor.streaming()}>
              <button class="hover:text-del" onClick={bind("tutor.stop")}>
                ■ stop <Key id="tutor.stop" />
              </button>
            </Show>
          </div>
        </div>
      </div>
      <Show when={tutor.pin()}>
        <CodePane />
      </Show>
    </div>
  );
}

/** The pinned file, lines lit and scrolled to. Highlighted a line at a time — plain enough to read by. */
function CodePane() {
  let pane: HTMLDivElement | undefined;
  const lines = createMemo(() => (tutor.code()?.text ?? "").replace(/\n$/, "").split("\n"));
  const lang = () => langOf(tutor.pin()?.path ?? "");
  const lit = (n: number) => {
    const r = tutor.pin()?.lines;
    return !!r && n >= r[0] && n <= r[1];
  };
  createEffect(() => {
    lines();
    const start = tutor.pin()?.lines?.[0];
    if (!start || !pane) return;
    requestAnimationFrame(() => pane?.querySelector(`[data-line="${start}"]`)?.scrollIntoView({ block: "center" }));
  });
  return (
    <div class="flex min-h-0 flex-col bg-diff-bg max-[900px]:max-h-[50vh]">
      <div class="flex items-baseline justify-between gap-3 border-b border-rule bg-vellum-raise px-4 py-2 text-[11px]">
        <span class="truncate text-ink-dim">{tutor.pin()?.path}</span>
        <span class="shrink-0 text-ink-faint">
          {tutor.pin()?.lines ? `L${tutor.pin()!.lines![0]}–${tutor.pin()!.lines![1]} · ` : ""}
          {tutor.code()?.ref ?? "…"}
        </span>
      </div>
      <div ref={pane} class="min-h-0 flex-1 overflow-auto py-1.5 text-[11.5px] leading-[1.6]">
        <Show when={!tutor.code()?.err} fallback={<p class="m-0 px-4 text-[12px] text-del">{tutor.code()!.err}</p>}>
          <Index each={tutor.code() ? lines() : []}>
            {(text, i) => (
              <div data-line={i + 1} class="flex" classList={{ "bg-gold-wash": lit(i + 1) }}>
                <span class="w-[48px] shrink-0 select-none pr-3 text-right text-ink-faint">{i + 1}</span>
                <code class="whitespace-pre pr-3" classList={{ "text-ink": lit(i + 1), "text-ink-dim": !lit(i + 1) }} innerHTML={highlight(text(), lang())} />
              </div>
            )}
          </Index>
        </Show>
      </div>
    </div>
  );
}

// ── the concept drawer ────────────────────────────────────────────────────

function Drawer(props: { id: string }) {
  const c = () => tutor.concept(props.id);
  const evidence = createMemo(() => (tutor.learn()?.evidence ?? []).filter((e) => e.concept === props.id).reverse());
  const questions = createMemo(() => (tutor.learn()?.questions ?? []).filter((x) => x.concept === props.id));
  const Links = (p: { label: string; ids: string[] }) => (
    <Show when={p.ids.length}>
      <div class="mb-3">
        <div class={`${LABEL} mb-1.5`}>{p.label}</div>
        <div class="flex flex-wrap gap-1.5">
          <For each={p.ids}>{(id) => <Chip id={id} />}</For>
        </div>
      </div>
    </Show>
  );
  return (
    <aside class="fixed right-0 top-0 z-[15] flex h-screen w-[460px] max-w-full flex-col border-l border-gold-deep bg-vellum-raise shadow-[-12px_0_32px_rgba(0,0,0,0.45)]">
      <Show when={c()} fallback={<p class="m-0 p-6 text-ink-faint">no concept {props.id}</p>}>
        {(cc) => (
          <div class="flex-1 overflow-y-auto px-6 py-5">
            <div class="mb-2 flex items-baseline gap-2">
              <span class={LABEL}>{cc().kind === "convention" ? "convention · told, then tested" : "principle · derivable"}</span>
              <span class="flex-1" />
              <button class="text-[11px] text-ink-faint hover:text-ink" title="close (esc)" onClick={bind("tutor.back")}>
                <Key id="tutor.back" /> ✕
              </button>
            </div>
            <h2 class="m-0 mb-2 font-display text-[22px] font-normal leading-tight text-ink">{cc().name}</h2>
            <Show when={cc().statement_learner}>
              <div class={`${LABEL} mb-0.5`}>in your words{cc().restated ? ` · ${cc().restated}` : ""}</div>
              <p class="m-0 mb-2 font-[Georgia,serif] text-[15px] leading-relaxed text-gold-leaf">“{cc().statement_learner}”</p>
              <div class={`${LABEL} mb-0.5`}>the tutor's version</div>
            </Show>
            <p class="m-0 mb-4 font-[Georgia,serif] text-[14.5px] leading-relaxed text-ink-dim">{cc().statement}</p>

            <div class="mb-4 border border-rule bg-vellum-night p-3">
              <div class="mb-2 flex items-center gap-3">
                <Pips m={cc().mastery} size="md" />
                <span class="text-[12.5px] text-ink">
                  {cc().mastery.held
                    ? `held at ${cc().mastery.held_level}${cc().mastery.depth > (cc().mastery.held ?? 0) ? ` · shown once at ${cc().mastery.level}` : ""}`
                    : cc().mastery.level
                      ? `shown once at ${cc().mastery.level} — a second day makes it held`
                      : "not yet shown unaided"}
                </span>
              </div>
              <div class="grid grid-cols-[72px_1fr] gap-x-2 gap-y-0.5 text-[10.5px] text-ink-faint">
                <For each={LEVELS}>
                  {(l) => (
                    <>
                      <span>{l}</span>
                      <span>{LEVEL_HINT[l]}</span>
                    </>
                  )}
                </For>
              </div>
              <Show when={cc().mastery.due}>
                <div class="mt-2 text-[12px] text-ember">
                  due{cc().mastery.miss_confidence === "high" ? " (a confident miss — re-test first)" : ""}: {cc().mastery.reason}
                </div>
              </Show>
              <Show when={cc().mastery.contrast}>
                <div class="mt-1 text-[12px] text-ink-dim">re-test with the contrast: {cc().mastery.contrast}</div>
              </Show>
            </div>

            <div class="mb-5 flex flex-wrap gap-2">
              <button class="border border-gold-deep bg-gold-wash px-3 py-0.5 font-display text-[14px] text-gold-leaf hover:bg-vellum-edge disabled:opacity-40" disabled={tutor.streaming()} onClick={bind("tutor.retest", cc().id)}>
                re-test me cold <Key id="tutor.retest" />
              </button>
              <button class="border border-rule px-3 py-0.5 font-display text-[14px] text-ink-dim hover:text-ink disabled:opacity-40" disabled={tutor.streaming()} onClick={bind("tutor.teach", cc().id)}>
                teach me this
              </button>
            </div>

            <Links label="needs first — never shown unaided" ids={cc().blocked_by ?? []} />
            <Links label="builds on" ids={cc().builds_on.filter((b) => !(cc().blocked_by ?? []).includes(b))} />
            <Links label="what builds on it" ids={cc().built_on_by} />
            <Links label="same idea elsewhere" ids={cc().analogs} />
            <Show when={cc().topics.length}>
              <div class="mb-4 text-[10.5px] text-ink-faint">in: {cc().topics.map((t) => tutor.learn()?.topics[t]?.title ?? t).join(" · ")}</div>
            </Show>
            <Show when={cc().code.length}>
              <div class="mb-4">
                <div class={`${LABEL} mb-1.5`}>code</div>
                <For each={cc().code}>
                  {(r) => (
                    <button
                      class="block max-w-full truncate text-[11px] text-ink-dim hover:text-gold-leaf disabled:hover:text-ink-dim"
                      disabled={!tutor.active()}
                      title={tutor.active() ? "show in the code pane" : "open a session to see code"}
                      onClick={bind("tutor.pin", undefined, "click", { path: r.path, ref: r.ref, lines: r.lines ? [r.lines[0], r.lines[1] ?? r.lines[0]] : undefined })}
                    >
                      {r.path}
                      {r.lines ? ` L${r.lines[0]}–${r.lines[1] ?? r.lines[0]}` : ""}
                    </button>
                  )}
                </For>
              </div>
            </Show>

            <div class="mb-5">
              <div class={`${LABEL} mb-1.5`}>your questions</div>
              <For each={questions()}>
                {(x) => (
                  <div class="flex items-baseline gap-2 py-1 text-[12.5px]">
                    <span class="flex-1" classList={{ "text-ink": x.status === "open", "text-ink-faint line-through": x.status !== "open" }}>
                      {x.text}
                    </span>
                    <button class={LINK} onClick={bind(x.status === "open" ? "tutor.question.close" : "tutor.question.reopen", x.id)}>
                      {x.status === "open" ? "answered" : "reopen"}
                    </button>
                  </div>
                )}
              </For>
              <form
                class="mt-1.5 flex gap-2"
                onSubmit={(e) => {
                  e.preventDefault();
                  dispatch("tutor.ask", "key", { event: e, target: cc().id });
                }}
              >
                <input
                  class="min-w-0 flex-1 border border-rule bg-vellum-night px-2 py-1 text-[12.5px] text-ink outline-none focus:border-gold-deep"
                  placeholder={tutor.active() ? "ask the tutor about this…" : "ask — starts a session on it"}
                  value={tutor.question()}
                  onInput={(e) => tutor.setQuestion(e.currentTarget.value)}
                />
                <button type="button" class="text-[11px] text-ember hover:text-gold-leaf" onClick={bind("tutor.ask", cc().id)}>
                  ask
                </button>
              </form>
            </div>

            <div>
              <div class={`${LABEL} mb-1`}>evidence · newest first</div>
              <p class="m-0 mb-2 text-[11.5px] text-ink-faint">depth comes only from this — toggle hit/miss, change level or credit, or cut a row</p>
              <Show when={evidence().length} fallback={<p class="m-0 text-[12px] text-ink-faint">none yet</p>}>
                <For each={evidence()}>{(e) => <EvidenceRow e={e} />}</For>
              </Show>
            </div>
          </div>
        )}
      </Show>
    </aside>
  );
}

export default function Tutor() {
  onMount(() => {
    tutor.refresh();
    tutor.reattach();
    // a shared link to a concept: /v2/tutor?concept=<id> opens its drawer
    const want = new URLSearchParams(location.search).get("concept");
    if (want) tutor.setDrawer(want);
  });
  return (
    <Show when={tutor.learn() || tutor.learnErr()} fallback={<p class="px-4 pl-11 text-ink-faint">reading your graph…</p>}>
      <Show
        when={tutor.active()}
        fallback={
          <Show when={!routeArg()} fallback={<p class="px-4 pl-11 text-ink-faint">no such session in this browser</p>}>
            <div data-paint="tutor">
              <Home />
            </div>
          </Show>
        }
      >
        {(s) => <SessionView s={s()} />}
      </Show>
      <Show when={tutor.drawer()}>{(id) => <Drawer id={id()} />}</Show>
    </Show>
  );
}
