// GitHub-flavoured markdown for review comments and PR bodies, rendered SAFELY: everything is
// HTML-escaped first and only the constructs below become markup — comments are written by other
// people and a bot, and this page holds keys that write to git. Pure.
//
// Blocks: fenced code (```suggestion renders as a suggested change), headings, quotes, lists (task
// boxes too), rules, paragraphs with GitHub's hard line breaks. Inline: code, bold, italic,
// strikethrough, http(s) links and bare URLs, @mentions. HTML comments (PR templates) are dropped.

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

export interface MdOpts {
  /** the lines a ```suggestion replaces, shown above it as removals */
  replaces?: string[];
}

export function inline(src: string): string {
  const codes: string[] = [];
  let s = src.replace(/(`+)([^`]|[^`][\s\S]*?[^`])\1(?!`)/g, (_m, _t, body: string) => {
    codes.push(`<code class="md-code">${esc(body.trim() === "" ? body : body.replace(/^ (.*) $/, "$1"))}</code>`);
    return `\u0000${codes.length - 1}\u0000`;
  });
  s = esc(s);
  s = s.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, (_m, text: string, url: string) => `<a href="${url}" target="_blank" rel="noopener noreferrer">${text}</a>`);
  s = s.replace(/(^|[\s(])(https?:\/\/[^\s<)]+[^\s<).,;:!?'"])/g, (_m, pre: string, url: string) => `${pre}<a href="${url}" target="_blank" rel="noopener noreferrer">${url}</a>`);
  s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>").replace(/__([^_]+)__/g, "<strong>$1</strong>");
  s = s.replace(/(^|[^*\w])\*([^*\s][^*]*?)\*(?!\w)/g, "$1<em>$2</em>").replace(/(^|[^_\w])_([^_\s][^_]*?)_(?!\w)/g, "$1<em>$2</em>");
  s = s.replace(/~~([^~]+)~~/g, "<del>$1</del>");
  s = s.replace(/(^|[\s(])@([A-Za-z0-9][\w-]*)/g, '$1<span class="md-at">@$2</span>');
  return s.replace(/\u0000(\d+)\u0000/g, (_m, i: string) => codes[+i]);
}

function fence(lang: string, body: string[], opts: MdOpts): string {
  if (lang === "suggestion") {
    const old = (opts.replaces ?? []).map((l) => `<div class="md-sg-del"><span>-</span>${esc(l) || " "}</div>`).join("");
    const neu = body.map((l) => `<div class="md-sg-add"><span>+</span>${esc(l) || " "}</div>`).join("");
    return `<div class="md-suggestion"><div class="md-sg-head">Suggested change</div><pre>${old}${neu || '<div class="md-sg-empty">(removes the lines)</div>'}</pre></div>`;
  }
  return `<pre class="md-pre"><code>${esc(body.join("\n"))}</code></pre>`;
}

/** Bots (linear-code) post HTML: their links and paragraphs become markdown, and the rest is escaped as usual. */
function fromHtml(s: string): string {
  if (!/^\s*<p>/i.test(s)) return s;
  return s
    .replace(/<a\s+href="(https?:\/\/[^"]+)"[^>]*>([^<]*)<\/a>/gi, "[$2]($1)")
    .replace(/<\/p>\s*<p>/gi, "\n\n")
    .replace(/<\/?p>|<br\s*\/?>/gi, "\n");
}

const LIST_ITEM = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/;
const TABLE_RULE = /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$/;
/** A table row's cells: split on pipes that aren't escaped or inside backticks. */
function cells(row: string): string[] {
  const out: string[] = [];
  let cur = "";
  let tick = false;
  const s = row.trim().replace(/^\|/, "").replace(/\|$/, "");
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (ch === "\\" && s[i + 1] === "|") {
      cur += "|";
      i++;
    } else if (ch === "`") {
      tick = !tick;
      cur += ch;
    } else if (ch === "|" && !tick) {
      out.push(cur.trim());
      cur = "";
    } else cur += ch;
  }
  out.push(cur.trim());
  return out;
}

export function renderMarkdown(src: string, opts: MdOpts = {}): string {
  const lines = fromHtml(src.replace(/\r\n?/g, "\n").replace(/<!--[\s\S]*?-->/g, "")).split("\n");
  const out: string[] = [];
  let para: string[] = [];
  const flush = () => {
    if (para.length) out.push(`<p>${para.map(inline).join("<br>")}</p>`);
    para = [];
  };
  for (let i = 0; i < lines.length; i++) {
    const ln = lines[i];
    const f = /^\s*(```|~~~)\s*([\w-]*)/.exec(ln);
    if (f) {
      flush();
      const body: string[] = [];
      for (i++; i < lines.length && !lines[i].trimStart().startsWith(f[1]); i++) body.push(lines[i]);
      out.push(fence(f[2], body, opts));
      continue;
    }
    const h = /^(#{1,6})\s+(.*)$/.exec(ln);
    if (h) {
      flush();
      out.push(`<h${h[1].length} class="md-h">${inline(h[2])}</h${h[1].length}>`);
      continue;
    }
    if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(ln)) {
      flush();
      out.push("<hr>");
      continue;
    }
    if (/^\s*>/.test(ln)) {
      flush();
      const quote: string[] = [];
      for (; i < lines.length && /^\s*>/.test(lines[i]); i++) quote.push(lines[i].replace(/^\s*> ?/, ""));
      i--;
      out.push(`<blockquote>${renderMarkdown(quote.join("\n"), opts)}</blockquote>`);
      continue;
    }
    if (/^\s*\|.*\|\s*$/.test(ln) && TABLE_RULE.test(lines[i + 1] ?? "")) {
      flush();
      const rows: string[][] = [cells(ln)];
      for (i += 2; i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i]); i++) rows.push(cells(lines[i]));
      i--;
      const row = (r: string[], tag: string) => `<tr>${r.map((c) => `<${tag}>${inline(c)}</${tag}>`).join("")}</tr>`;
      out.push(`<table class="md-table"><thead>${row(rows[0], "th")}</thead><tbody>${rows.slice(1).map((r) => row(r, "td")).join("")}</tbody></table>`);
      continue;
    }
    const li = LIST_ITEM.exec(ln);
    if (li) {
      flush();
      const base = li[1].length;
      const ordered = /\d/.test(li[2]);
      const items: { text: string; sub: string[] }[] = [];
      for (; i < lines.length; i++) {
        const m = LIST_ITEM.exec(lines[i]);
        if (m && m[1].length === base) items.push({ text: m[3], sub: [] });
        else if (m && m[1].length > base && items.length) items[items.length - 1].sub.push(lines[i]);
        else if (!m && lines[i].trim() && /^\s{2,}/.test(lines[i]) && items.length) {
          const last = items[items.length - 1];
          if (last.sub.length) last.sub.push(lines[i]);
          else last.text += " " + lines[i].trim();
        } else if (!lines[i].trim() && items.length) {
          // a blank line inside a loose list: it goes on if what follows is its next item or indented under it
          let j = i + 1;
          while (j < lines.length && !lines[j].trim()) j++;
          const next = lines[j] ?? "";
          const m2 = LIST_ITEM.exec(next);
          const indent = /^\s*/.exec(next)![0].length;
          if (m2 && m2[1].length === base) continue;
          if (indent > base && indent >= 2) items[items.length - 1].sub.push("");
          else break;
        } else break;
      }
      i--;
      const first = parseInt(li[2], 10);
      const body = items
        .map(({ text, sub }) => {
          const task = /^\[([ xX])\]\s+(.*)$/.exec(text);
          const head = task ? `${task[1] === " " ? "☐" : "☑"} ${inline(task[2])}` : inline(text);
          const indent = Math.min(...sub.filter((s) => s.trim()).map((s) => /^\s*/.exec(s)![0].length));
          const nested = sub.length ? renderMarkdown(sub.map((s) => s.slice(indent)).join("\n"), opts) : "";
          return `<li${task ? ' class="md-task"' : ""}>${head}${nested}</li>`;
        })
        .join("");
      out.push(ordered ? `<ol${first > 1 ? ` start="${first}"` : ""}>${body}</ol>` : `<ul>${body}</ul>`);
      continue;
    }
    if (!ln.trim()) {
      flush();
      continue;
    }
    para.push(ln);
  }
  flush();
  return out.join("");
}

/** The first ```suggestion block's lines, or null (mirrors srv/reviewdesk.suggestion_of). */
export function suggestionOf(body: string): string[] | null {
  const m = /^```suggestion[^\n]*\n([\s\S]*?)^```/m.exec(body.replace(/\r\n/g, "\n"));
  if (!m) return null;
  const inner = m[1].replace(/\n$/, "");
  return m[1] === "" ? [] : inner.split("\n");
}

/** One line of plain text from markdown, for a folded summary. */
export function plain(src: string, max = 140): string {
  const s = src
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/```[\s\S]*?```/g, " ")
    .replace(/[`*_>#~]/g, "")
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    .replace(/\s+/g, " ")
    .trim();
  return s.length > max ? s.slice(0, max - 1) + "…" : s;
}
