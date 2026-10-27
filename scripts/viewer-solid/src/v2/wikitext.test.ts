import { test } from "node:test";
import assert from "node:assert/strict";
import { sectionsOf, wikiHtml, type WikiPage } from "./wikitext.ts";

const page = (slug: string, section: string): WikiPage => ({ slug, title: slug, section, order: 0, lede: "", project: "", kind: "map", body: "", words: 0 });

test("sections keep the server's page order and their own first appearance", () => {
  const s = sectionsOf([page("a", "Mail"), page("b", "Canopy"), page("c", "Mail")]);
  assert.deepEqual(
    s.map((x) => [x.name, x.pages.map((p) => p.slug)]),
    [
      ["Mail", ["a", "c"]],
      ["Canopy", ["b"]],
    ],
  );
});

test("a citation is a button carrying its anchor, its label still markdown", () => {
  const html = wikiHtml("Every route returns a [`nextPage` URL](src:lib/rest-api/pagination.ts#buildPaginationMeta).");
  assert.match(html, /<button class="wk-cite" data-anchor="lib\/rest-api\/pagination.ts#buildPaginationMeta"[^>]*><code class="md-code">nextPage<\/code> URL<\/button>/);
  assert.doesNotMatch(html, /src:/);
});

test("a wikilink names the page by its title when it's known", () => {
  assert.match(wikiHtml("see [[canopy-v2-keys]]", (s) => (s === "canopy-v2-keys" ? "Keys like Helix" : undefined)), /data-slug="canopy-v2-keys">Keys like Helix<\/a>/);
  assert.match(wikiHtml("see [[no-such]]"), />no such<\/a>/);
});

test("an anchor can't break out of its attribute, and prose around it is still escaped", () => {
  const html = wikiHtml('<b>x</b> [y](src:a"onclick="z)');
  assert.match(html, /&lt;b&gt;x&lt;\/b&gt;/);
  assert.match(html, /data-anchor="a&quot;onclick=&quot;z"/);
});

test("tables render, a pipe inside code staying in its cell", () => {
  const html = wikiHtml("| key | was |\n|---|---|\n| `a | b` | `space` |\n| x | y |");
  assert.match(html, /<table class="md-table"><thead><tr><th>key<\/th><th>was<\/th><\/tr><\/thead>/);
  assert.match(html, /<td><code class="md-code">a \| b<\/code><\/td><td><code class="md-code">space<\/code><\/td>/);
  assert.match(html, /<td>x<\/td><td>y<\/td><\/tr><\/tbody><\/table>/);
});

test("an indented list nests under its item", () => {
  const html = wikiHtml("1. **Motion.** first\n2. **Actions** each:\n   - thread header\n   - pending draft\n\n   Other keys.\n3. Third");
  assert.equal(
    html,
    "<ol><li><strong>Motion.</strong> first</li><li><strong>Actions</strong> each:<ul><li>thread header</li><li>pending draft</li></ul><p>Other keys.</p></li><li>Third</li></ol>",
  );
  assert.match(wikiHtml("4. four\n5. five"), /^<ol start="4">/);
});
