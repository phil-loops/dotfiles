import { marked, type Tokens } from "marked";
import hljs from "highlight.js/lib/core";
import typescript from "highlight.js/lib/languages/typescript";
import javascript from "highlight.js/lib/languages/javascript";
import json from "highlight.js/lib/languages/json";
import bash from "highlight.js/lib/languages/bash";
import python from "highlight.js/lib/languages/python";
import sql from "highlight.js/lib/languages/sql";
import css from "highlight.js/lib/languages/css";
import xml from "highlight.js/lib/languages/xml";
import yaml from "highlight.js/lib/languages/yaml";
import diff from "highlight.js/lib/languages/diff";
import markdown from "highlight.js/lib/languages/markdown";
import "highlight.js/styles/github-dark.css";

// Import hljs core + only the languages this repo's chat actually shows — importing the default
// `highlight.js` bundle pulls every language and adds ~1MB to the build. With core, highlightAuto
// only considers these registered languages too.
hljs.registerLanguage("typescript", typescript);
hljs.registerLanguage("javascript", javascript);
hljs.registerLanguage("json", json);
hljs.registerLanguage("bash", bash);
hljs.registerLanguage("python", python);
hljs.registerLanguage("sql", sql);
hljs.registerLanguage("css", css);
hljs.registerLanguage("xml", xml);
hljs.registerLanguage("yaml", yaml);
hljs.registerLanguage("diff", diff);
hljs.registerLanguage("markdown", markdown);
hljs.registerAliases(["ts", "tsx"], { languageName: "typescript" });
hljs.registerAliases(["js", "jsx"], { languageName: "javascript" });
hljs.registerAliases(["sh", "shell", "zsh"], { languageName: "bash" });
hljs.registerAliases("py", { languageName: "python" });
hljs.registerAliases("html", { languageName: "xml" });
hljs.registerAliases("yml", { languageName: "yaml" });
hljs.registerAliases("md", { languageName: "markdown" });

// Render Claude's chat answers (markdown) to HTML, with code fences highlighted via the
// highlight.js already pulled in by diff2html. Used by ChatPanel for assistant turns only —
// user turns stay plain text. Re-runs per streamed token, but the answers are small so a full
// re-parse each frame is cheap. Output is fed to innerHTML: the source is our own local headless
// `claude` reading our own repo, and hljs HTML-escapes code bodies, so this is acceptable for a
// localhost dev tool (no untrusted input crosses this boundary).
marked.use({
  gfm: true,
  breaks: true,
  renderer: {
    code({ text, lang }: Tokens.Code): string {
      const language = lang && hljs.getLanguage(lang) ? lang : "";
      const body = language
        ? hljs.highlight(text, { language }).value
        : hljs.highlightAuto(text).value;
      return `<pre class="cp-pre"><code class="hljs">${body}</code></pre>`;
    },
  },
});

export function renderMarkdown(src: string): string {
  return marked.parse(src) as string;
}
