// A branch's unified diff (the /node payload's per-file patches) as rows the page renders and the
// cursor walks: one row per line in unified view, one per old/new pair in split view. Pure.

export type Kind = "ctx" | "add" | "del";
export interface Line {
  kind: Kind;
  old: number | null;
  new: number | null;
  text: string;
}
export interface Hunk {
  header: string;
  lines: Line[];
}
export interface FileDiff {
  path: string;
  oldPath: string | null;
  status: "added" | "deleted" | "renamed" | "modified" | "binary";
  add: number;
  del: number;
  hunks: Hunk[];
}

const HUNK = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$/;

export function parsePatch(path: string, patch: string): FileDiff {
  const out: FileDiff = { path, oldPath: null, status: "modified", add: 0, del: 0, hunks: [] };
  let h: Hunk | null = null;
  let o = 0;
  let n = 0;
  for (const raw of patch.replace(/\n$/, "").split("\n")) {
    const m = HUNK.exec(raw);
    if (m) {
      o = +m[1];
      n = +m[3];
      h = { header: raw, lines: [] };
      out.hunks.push(h);
      continue;
    }
    if (!h) {
      if (raw.startsWith("new file")) out.status = "added";
      else if (raw.startsWith("deleted file")) out.status = "deleted";
      else if (raw.startsWith("rename from ")) {
        out.status = "renamed";
        out.oldPath = raw.slice(12);
      } else if (raw.startsWith("Binary files")) out.status = "binary";
      continue;
    }
    if (raw.startsWith("\\")) continue; // "\ No newline at end of file"
    const c = raw[0];
    const text = raw.slice(1);
    if (c === "+") {
      h.lines.push({ kind: "add", old: null, new: n++, text });
      out.add++;
    } else if (c === "-") {
      h.lines.push({ kind: "del", old: o++, new: null, text });
      out.del++;
    } else if (c === " ") {
      h.lines.push({ kind: "ctx", old: o++, new: n++, text });
    }
  }
  return out;
}

/** A display row: unified rows carry one line; split rows pair an old line with a new one. */
export interface Row {
  key: string;
  hunk: number;
  left: Line | null;
  right: Line | null;
}

/** "R:<new>" for a line with a new side, else "L:<old>" — the anchor a thread or comment sits at. */
export const anchorOf = (l: Line): string => (l.new != null ? `R:${l.new}` : `L:${l.old}`);
/** Every anchor a line answers to: a kept line sits on both sides. */
export const anchorsOf = (l: Line): string[] =>
  l.kind === "ctx" ? [`R:${l.new}`, `L:${l.old}`] : [anchorOf(l)];

export function unifiedRows(f: FileDiff): Row[] {
  const rows: Row[] = [];
  f.hunks.forEach((h, i) => {
    for (const l of h.lines) rows.push({ key: anchorOf(l), hunk: i, left: l.kind === "add" ? null : l, right: l.kind === "del" ? null : l });
  });
  return rows;
}

/** Split view: kept lines on both halves; a run of removals beside the additions that replace it. */
export function splitRows(f: FileDiff): Row[] {
  const rows: Row[] = [];
  f.hunks.forEach((h, i) => {
    let dels: Line[] = [];
    let adds: Line[] = [];
    const flush = () => {
      for (let k = 0; k < Math.max(dels.length, adds.length); k++) {
        const left = dels[k] ?? null;
        const right = adds[k] ?? null;
        rows.push({ key: right ? anchorOf(right) : anchorOf(left!), hunk: i, left, right });
      }
      dels = [];
      adds = [];
    };
    for (const l of h.lines) {
      if (l.kind === "del") {
        if (adds.length) flush();
        dels.push(l);
      } else if (l.kind === "add") adds.push(l);
      else {
        flush();
        rows.push({ key: anchorOf(l), hunk: i, left: l, right: l });
      }
    }
    flush();
  });
  return rows;
}

/** The anchors a row answers to (a thread at any of them renders under it). */
export function rowAnchors(r: Row): string[] {
  const out = new Set<string>();
  if (r.right) out.add(`R:${r.right.new}`);
  if (r.left) out.add(`L:${r.left.old}`);
  return [...out];
}

// ── context: the unchanged lines a diff leaves out, revealed on request ──

/** A run of unchanged lines the diff hides: before hunk `at`, or after the last (`at` = hunks.length). */
export interface Gap {
  at: number;
  /** new-side line numbers of what's still hidden, first..last; `last` null = to the end of a file not read yet */
  first: number;
  last: number | null;
  /** the hunk header's own context (the enclosing function, say), for the gap row */
  label: string;
}

const span = (h: Hunk) => {
  const m = HUNK.exec(h.header);
  if (!m) return null;
  const [os, ol, ns, nl] = [+m[1], m[2] == null ? 1 : +m[2], +m[3], m[4] == null ? 1 : +m[4]];
  // a side with no lines (`+12,0`) sits AFTER its start line
  const first = nl ? ns : ns + 1;
  const oldFirst = ol ? os : os + 1;
  return { first, last: first + nl - 1, offset: oldFirst - first, after: oldFirst + ol - 1 - (first + nl - 1), label: m[5].trim() };
};

/**
 * The file with `reveal[at]` more unchanged lines shown at each gap — taken from `lines` (the new
 * file, 1-based by index + 1) and added to the neighbouring hunk as ordinary context lines, so rows,
 * anchors and threads treat them like any other — plus the gaps still hidden. A gap before a hunk
 * reveals upward from it (the lines nearest the change first), the gap after the last downward.
 * Without `lines` nothing is revealed, and the trailing gap's end is unknown.
 */
export function expand(f: FileDiff, lines: string[] | undefined, reveal: ReadonlyMap<number, number>): { file: FileDiff; gaps: Gap[] } {
  if (f.status === "added" || f.status === "deleted" || f.status === "binary" || !f.hunks.length) return { file: f, gaps: [] };
  const spans = f.hunks.map(span);
  if (spans.some((s) => !s)) return { file: f, gaps: [] };
  const eof = lines ? (lines.length && lines[lines.length - 1] === "" ? lines.length - 1 : lines.length) : null;
  const hunks = f.hunks.map((h) => ({ header: h.header, lines: [...h.lines] }));
  const gaps: Gap[] = [];
  const ctx = (n: number, offset: number): Line => ({ kind: "ctx", old: n + offset, new: n, text: lines![n - 1] ?? "" });
  let prevEnd = 0;
  spans.forEach((s, i) => {
    const want = reveal.get(i) ?? 0;
    let hiddenLast = s!.first - 1;
    if (lines && want > 0) {
      const from = Math.max(prevEnd + 1, s!.first - want);
      const add: Line[] = [];
      for (let n = from; n < s!.first; n++) add.push(ctx(n, s!.offset));
      hunks[i].lines.unshift(...add);
      hiddenLast = from - 1;
    }
    if (hiddenLast >= prevEnd + 1) gaps.push({ at: i, first: prevEnd + 1, last: hiddenLast, label: s!.label });
    prevEnd = s!.last;
  });
  const last = spans[spans.length - 1]!;
  const want = reveal.get(spans.length) ?? 0;
  let hiddenFirst = last.last + 1;
  if (lines && want > 0) {
    const to = Math.min(eof!, last.last + want);
    for (let n = last.last + 1; n <= to; n++) hunks[hunks.length - 1].lines.push(ctx(n, last.after));
    hiddenFirst = to + 1;
  }
  if (eof == null || hiddenFirst <= eof) gaps.push({ at: spans.length, first: hiddenFirst, last: eof, label: "" });
  return { file: { ...f, hunks }, gaps };
}
