import { createEffect, createMemo, For, Show, type JSX } from "solid-js";
import hljs from "highlight.js/lib/core";
import "./markdown"; // registers the hljs languages on the shared core

const LANG_BY_EXT: Record<string, string> = {
  ts: "typescript", tsx: "typescript", mts: "typescript", cts: "typescript",
  js: "javascript", jsx: "javascript", mjs: "javascript", cjs: "javascript",
  py: "python", json: "json", sh: "bash", zsh: "bash", bash: "bash", sql: "sql", css: "css",
  html: "xml", xml: "xml", svg: "xml", yml: "yaml", yaml: "yaml", md: "markdown", diff: "diff", patch: "diff",
};
const HIGHLIGHT_MAX = 300_000;

const escapeHtml = (t: string) => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

// Highlight the WHOLE file (so a multi-line comment or string colors correctly), then cut the HTML
// into lines, closing the spans still open at each newline and reopening them on the next line.
export function highlightLines(text: string, path: string): string[] {
  const lang = LANG_BY_EXT[path.split(".").pop()?.toLowerCase() ?? ""];
  let html: string;
  if (text.length > HIGHLIGHT_MAX) {
    html = escapeHtml(text);
  } else if (lang && hljs.getLanguage(lang)) {
    html = hljs.highlight(text, { language: lang, ignoreIllegals: true }).value;
  } else {
    html = hljs.highlightAuto(text).value;
  }
  const out: string[] = [];
  const open: string[] = [];
  let cur = "";
  for (const m of html.matchAll(/<span[^>]*>|<\/span>|\n|[^<\n]+/g)) {
    const t = m[0];
    if (t === "\n") {
      out.push(cur + "</span>".repeat(open.length));
      cur = open.join("");
    } else if (t.startsWith("<span")) {
      open.push(t);
      cur += t;
    } else if (t === "</span>") {
      open.pop();
      cur += t;
    } else {
      cur += t;
    }
  }
  out.push(cur + "</span>".repeat(open.length));
  return out;
}

/** A read-only, line-numbered, syntax-colored file in its own scroller, scrolled to and lighting `lit`. */
export function CodeLines(props: { text?: string; path: string; lit?: [number, number]; children?: JSX.Element }) {
  let pane: HTMLDivElement | undefined;
  const lines = createMemo(() => highlightLines((props.text ?? "").replace(/\n$/, ""), props.path));
  const focused = () => !!props.lit;
  const lit = (n: number) => {
    const r = props.lit;
    return !!r && n >= r[0] && n <= r[1];
  };
  createEffect(() => {
    lines();
    const start = props.lit?.[0];
    if (!start) return;
    queueMicrotask(() => {
      const el = pane?.querySelector(`[data-ln="${start}"]`) as HTMLElement | null;
      if (el && pane) pane.scrollTo({ top: Math.max(0, el.offsetTop - 80), behavior: "smooth" });
    });
  });
  return (
    <div ref={pane} class="relative flex-1 min-h-0 overflow-auto py-2">
      {props.children}
      <Show when={props.text !== undefined}>
        <pre class="m-0 font-mono text-[12.5px] leading-[1.55]">
          <For each={lines()}>
            {(ln, i) => (
              <div
                data-ln={i() + 1}
                class="flex"
                classList={{ "bg-gold-wash": lit(i() + 1) }}
              >
                <span
                  class="w-[52px] shrink-0 select-none pr-3 text-right"
                  classList={{ "text-gold-leaf": lit(i() + 1), "text-ink-faint": !lit(i() + 1) }}
                >{i() + 1}</span>
                {/* innerHTML: hljs output — it escapes the file's text, and the file is local code */}
                <span
                  class="whitespace-pre pr-4 text-ink"
                  classList={{ "opacity-55": focused() && !lit(i() + 1) }}
                  innerHTML={ln || " "}
                />
              </div>
            )}
          </For>
        </pre>
      </Show>
    </div>
  );
}
