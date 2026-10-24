// A small one-line highlighter for diff lines: comments, strings, numbers, keywords and types in
// TS/JS-shaped code (Python and shell get their comments). Output is escaped HTML whose text is
// exactly the line, so a caret offset in it is a column in the file. Pure.

const KW = new Set(
  ("abstract as async await break case catch class const continue debugger declare default delete do else enum export extends " +
    "false finally for from function get if implements import in instanceof interface is keyof let new null of private " +
    "protected public readonly return satisfies set static super switch this throw true try type typeof undefined var void while with yield " +
    "def elif lambda pass None True False not and or self").split(" "),
);

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const span = (cls: string, s: string) => `<span class="${cls}">${esc(s)}</span>`;

const TOKEN = /(\/\/.*$|\/\*.*?(?:\*\/|$)|^\s*\*.*$|#(?![{[]).*$)|("(?:[^"\\]|\\.)*"?|'(?:[^'\\]|\\.)*'?|`(?:[^`\\]|\\.)*`?)|(\b\d[\d_]*(?:\.\d+)?\b)|([A-Za-z_$][\w$]*)/g;

export function highlight(text: string, lang: string): string {
  if (lang === "plain") return esc(text);
  const hashComments = lang === "py" || lang === "sh";
  let out = "";
  let last = 0;
  TOKEN.lastIndex = 0;
  for (let m = TOKEN.exec(text); m; m = TOKEN.exec(text)) {
    out += esc(text.slice(last, m.index));
    const [tok, comment, str, num, word] = m;
    if (comment !== undefined) {
      const isHash = comment.trimStart().startsWith("#");
      out += isHash && !hashComments ? esc(comment) : span("hl-c", comment);
    } else if (str !== undefined) out += span("hl-s", str);
    else if (num !== undefined) out += span("hl-n", num);
    else if (word !== undefined) out += KW.has(word) ? span("hl-k", word) : /^[A-Z]/.test(word) ? span("hl-t", word) : esc(word);
    last = m.index + tok.length;
  }
  return out + esc(text.slice(last));
}

export function langOf(path: string): string {
  const ext = path.slice(path.lastIndexOf(".") + 1).toLowerCase();
  if (["ts", "tsx", "js", "jsx", "mjs", "cjs", "mts", "json", "css", "go", "rs", "java", "c", "h", "swift", "kt", "prisma", "sql"].includes(ext)) return "ts";
  if (ext === "py") return "py";
  if (["sh", "zsh", "bash", "toml", "yml", "yaml"].includes(ext) || !path.includes(".")) return "sh";
  return "plain";
}
