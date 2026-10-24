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
