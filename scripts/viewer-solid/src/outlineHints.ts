// The outline's voice rules, as live hints — never a block. The opening commit carries
// `type(scope):` with the forest's ticket as the lowercase scope; follow-ups read bare, the way
// they'd be typed at `git commit -m`; subjects stay short; a body is one non-obvious why, and
// the forest plan belongs in the PR body, not baked into a commit.

export const SUBJECT_LIMIT = 50;
const LONG_BODY = 240;
const TYPES = ["feat", "fix", "chore", "refactor", "docs", "test", "perf", "style", "ci", "build", "revert"];
const PREFIX = new RegExp(`^(${TYPES.join("|")})(\\(([^)]*)\\))?(!)?:\\s*`, "i");
const WIP = /^(wip\b|fixup!|squash!|amend!)/i;

export type Words = { subject: string; body: string };
export type Hint = {
  id: string;
  tone: "error" | "warn" | "note";
  text: string;
  fix?: { label: string; apply: (w: Words) => Words };
};

/** `{type, scope, bang, rest}` when the subject opens with a conventional prefix. */
export function prefixOf(subject: string): { type: string; scope?: string; bang: string; rest: string } | undefined {
  const m = PREFIX.exec(subject);
  if (!m) return undefined;
  return { type: m[1].toLowerCase(), scope: m[3], bang: m[4] ?? "", rest: subject.slice(m[0].length) };
}

/** The subject with its conventional prefix removed — how a follow-up reads. */
export function bare(subject: string): string {
  const p = prefixOf(subject);
  return p ? p.rest : subject;
}

/** The opening subject with the ticket as its scope; a prefix-less one gains `feat(<ticket>):`. */
export function withScope(subject: string, ticket: string): string {
  const p = prefixOf(subject);
  return p ? `${p.type}(${ticket})${p.bang}: ${p.rest}` : `feat(${ticket}): ${subject}`;
}

/** True when a body still carries the generated "Part of a stack" block or the old fence. */
export function hasPlan(body: string): boolean {
  return /^Part of /m.test(body) || /^-- forest --$/m.test(body);
}

/** The body without its generated forest block: the "Part of …" line and the step lines under
 *  it, plus the retired `-- forest --` fence. Prose before or after the block stays. */
export function stripPlan(body: string): string {
  const lines = body.split("\n");
  const out: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].trim() === "-- forest --") continue;
    if (lines[i].startsWith("Part of ")) {
      // the block runs to the first blank line that isn't followed by more steps: a squash message
      // wraps long steps onto unindented lines, so every non-blank line until then is the block's
      const step = (l: string) => /^\s+\S|^\s*(\d+\.\s|[-*•]\s|\[)/.test(l);
      while (i + 1 < lines.length) {
        if (lines[i + 1].trim() !== "") {
          i++;
          continue;
        }
        let j = i + 1;
        while (j < lines.length && lines[j].trim() === "") j++;
        if (j < lines.length && step(lines[j])) i = j;
        else break;
      }
      continue;
    }
    out.push(lines[i]);
  }
  return out.join("\n").replace(/\n{3,}/g, "\n\n").trim();
}

/** Every hint for one outline row. `opening` = the branch's first own commit (or the PR title,
 *  which follows the same rule); `ticket` = the forest's ticket, lowercase, if it has one. */
export function hintsFor(w: Words, ctx: { opening: boolean; ticket?: string; kind?: "commit" | "title" }): Hint[] {
  const hints: Hint[] = [];
  const subject = w.subject.trim();
  if (!subject) return [{ id: "empty", tone: "error", text: "a subject is required" }];
  if (WIP.test(subject)) {
    hints.push({ id: "wip", tone: "error", text: "a placeholder subject — saving refuses it" });
  }
  if (subject.length > SUBJECT_LIMIT) {
    hints.push({ id: "long", tone: "warn", text: `${subject.length} chars — terse reads better (≤ ${SUBJECT_LIMIT})` });
  }
  const p = prefixOf(subject);
  if (ctx.opening && ctx.ticket) {
    const ticket = ctx.ticket.toLowerCase();
    if (!p) {
      hints.push({
        id: "scope",
        tone: "warn",
        text: `the opening line wants \`type(${ticket}):\``,
        fix: { label: `＋ feat(${ticket}):`, apply: (x) => ({ ...x, subject: withScope(x.subject.trim(), ticket) }) },
      });
    } else if (p.scope !== ticket) {
      hints.push({
        id: "scope",
        tone: "warn",
        text: p.scope ? `scope \`${p.scope}\` — the forest's ticket is \`${ticket}\`` : `no scope — the forest's ticket is \`${ticket}\``,
        fix: { label: "fix scope", apply: (x) => ({ ...x, subject: withScope(x.subject.trim(), ticket) }) },
      });
    }
  } else if (ctx.opening && !p) {
    hints.push({ id: "type", tone: "note", text: "the opening line usually carries a `type:` prefix" });
  }
  if (!ctx.opening && p) {
    hints.push({
      id: "bare",
      tone: "warn",
      text: "follow-ups read bare — no type, no scope",
      fix: { label: "make bare", apply: (x) => ({ ...x, subject: bare(x.subject.trim()) }) },
    });
  }
  if (ctx.kind !== "title" && hasPlan(w.body)) {
    hints.push({
      id: "plan",
      tone: "warn",
      text: "a baked forest block — the PR body carries the stack now",
      fix: { label: "strip it", apply: (x) => ({ ...x, body: stripPlan(x.body) }) },
    });
  } else if (ctx.kind !== "title" && w.body.trim().length > LONG_BODY) {
    hints.push({ id: "prose", tone: "note", text: `${w.body.trim().length}-char body — one line of why is plenty` });
  }
  return hints;
}
