// npm run review-walkthrough -- --base http://127.0.0.1:<port> --sandbox <dir> [--out <dir>]
//
// The review page end to end on a `viewer-sandbox <dir> --github` server, keys only, against its
// fake GitHub (<dir>/github.json — never the real one): threads inline, show outdated, types on K,
// a second-reader note and its draft, apply suggestion (a local commit), a reply naming that
// unpushed commit stays a draft until a sandbox push, then joins Phil's pending review; a reply to a
// teammate's question joins the same pending review and R only opens GitHub; on a teammate's PR a
// draft and a range comment survive a reload, P sends the draft, S opens GitHub, and "submitted" is
// learned only once (the fake) GitHub says so. Every mutation is one of the three pending-review
// ones, none with an event. Screenshots of each step land in --out. Exits non-zero on a miss.
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";

const arg = (k, d) => {
  const i = process.argv.indexOf(k);
  return i > 0 ? process.argv[i + 1] : d;
};
const base = arg("--base");
const sandbox = arg("--sandbox");
const out = arg("--out", "/tmp/review-walkthrough");
if (!base || !sandbox) {
  console.error("usage: review-walkthrough --base <url> --sandbox <dir> [--out <dir>]");
  process.exit(2);
}
mkdirSync(out, { recursive: true });
const repo = join(sandbox, "repo");
const gh = () => JSON.parse(readFileSync(join(sandbox, "github.json"), "utf8"));
const git = (...a) => execFileSync("git", ["-C", repo, ...a], { encoding: "utf8" }).trim();

let failed = false;
const check = (ok, what) => {
  console.log(`${ok ? "✓" : "✕"} ${what}`);
  if (!ok) failed = true;
};

const require = createRequire(import.meta.url);
const puppeteer = require("puppeteer-core");
const b = await puppeteer.launch({
  executablePath:
    process.env.CHROME ||
    `${process.env.HOME}/.cache/puppeteer/chrome-headless-shell/mac_arm-150.0.7871.24/chrome-headless-shell-mac-arm64/chrome-headless-shell`,
  headless: true,
});
const p = await b.newPage();
await p.evaluateOnNewDocument(() => {
  window.__opened = [];
  window.open = (u) => (window.__opened.push(String(u)), null);
});
await p.setExtraHTTPHeaders({ "X-Stack-Actor": "headless" });
await p.setViewport({ width: 1400, height: 940 });
const errors = [];
p.on("pageerror", (e) => errors.push(String(e)));

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let shot = 0;
const snap = async (name) => {
  await sleep(250);
  const path = join(out, `${String(++shot).padStart(2, "0")}-${name}.png`);
  await p.screenshot({ path });
  return path;
};
const key = async (k, mods = []) => {
  for (const m of mods) await p.keyboard.down(m);
  await p.keyboard.press(k);
  for (const m of mods.reverse()) await p.keyboard.up(m);
  await sleep(90);
};
const type = async (text) => p.keyboard.type(text, { delay: 2 });
const until = async (fn, what, ms = 8000) => {
  const t0 = Date.now();
  for (;;) {
    const v = await p.evaluate(fn).catch(() => null);
    if (v) return v;
    if (Date.now() - t0 > ms) {
      check(false, `timed out waiting for ${what}`);
      return null;
    }
    await sleep(100);
  }
};
const here = () => p.evaluate(() => document.querySelector(".rv-on")?.getAttribute("data-stop") ?? "");
/** Walk the cursor (n / N / j) until it sits on this stop. */
const goto = async (stop, keyName = "n", max = 60) => {
  for (let i = 0; i < max && (await here()) !== stop; i++) await key(keyName);
  return (await here()) === stop;
};
const open = async (path) => {
  await p.goto(`${base}${path}`);
  await p.waitForSelector('[data-paint="review"]', { timeout: 10000 });
  await sleep(150);
};

const M = "t|repo:demo/model#";

// 1. threads inline — open ones unfolded, resolved folded, outdated hidden
await open("/v2/b/repo/demo/model");
const shown = await p.evaluate(() => [...document.querySelectorAll(".rv-thread")].map((e) => e.getAttribute("data-stop")));
check(shown.includes(`${M}PRRT_sb1`) && shown.includes(`${M}PRRT_sb3`) && shown.includes(`${M}PRRT_sb4`), "threads render inline at their lines");
check(!shown.includes(`${M}PRRT_sb5`), "the outdated thread is hidden by default");
check(await p.evaluate(() => !!document.querySelector('[data-stop$="PRRT_sb4"] .rv-chip-ok') && !document.querySelector('[data-stop$="PRRT_sb4"] .rv-comment')), "a resolved thread is folded");
await snap("threads-inline");

// 2. show outdated
await key("O");
check(await until(() => !!document.querySelector('[data-stop$="PRRT_sb5"]'), "the outdated thread"), "O shows the outdated thread");
await snap("show-outdated");
await key("O");

// 3. types on K, under the pointer
const at = await p.evaluate(() => {
  const el = document.querySelector('[data-code][data-path="src/models/widget-rules.ts"][data-line="6"]');
  if (!el) return null;
  el.scrollIntoView({ block: "center" });
  const walk = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
  for (let n = walk.nextNode(); n; n = walk.nextNode()) {
    const i = n.textContent.indexOf("listWidgets");
    if (i >= 0) {
      const r = document.createRange();
      r.setStart(n, i + 2);
      r.setEnd(n, i + 3);
      const b = r.getBoundingClientRect();
      return { x: b.left + 1, y: b.top + b.height / 2 };
    }
  }
  return null;
});
if (at) {
  await p.mouse.move(at.x, at.y);
  await key("K");
  const typed = await until(() => {
    const t = document.querySelector(".rv-pop")?.textContent ?? "";
    return /loading|asking/.test(t) ? null : t || null;
  }, "a type", 120000);
  if (/memory is tight/.test(String(typed))) console.log(`– K reached the type service, which declined: ${typed} (the machine's memory floor, not the page)`);
  else check(!!typed && /listWidgets|Widget\[\]/.test(typed), `K shows the type: ${String(typed).slice(0, 80)}`);
  await snap("types-on-K");
  await key("Escape");
} else check(false, "found listWidgets on line 6");

// 4. the second reader's note, and its draft reply inserted with one key
check(await goto(`${M}PRRT_sb1`), "n reaches the bot's finding");
check(await p.evaluate(() => /same issue in 2 places/.test(document.querySelector('[data-stop$="PRRT_sb1"] .rv-note')?.textContent ?? "")), "the note folds to one line: verdict + same issue in 2 places");
await key("z");
await snap("second-reader-note");
await key("i");
const draft = gh().prs["43"] && JSON.parse(readFileSync(join(repo, ".git/stack-review-notes/43/PRRT_sb1.json"), "utf8")).draftReply;
check((await p.evaluate(() => document.querySelector(".rv-composer textarea")?.value)) === draft, "i puts the draft reply in the reply box");
await snap("draft-inserted");
await key("Escape");

// 5. apply suggestion — a local commit, never a push
const before = git("rev-parse", "demo/model");
await key("a");
const by = await until(() => document.querySelector('[data-stop$="PRRT_sb1"] .rv-chip-gold')?.textContent?.match(/addressed by (\w+)/)?.[1], "addressed by", 8000);
const after = git("rev-parse", "demo/model");
check(after !== before && git("log", "-1", "--format=%s", "demo/model").startsWith("fix(loo-9999): apply john-hankles's suggestion"), `a applies the suggestion as a local commit (${after.slice(0, 7)})`);
check(git("rev-parse", "refs/remotes/origin/demo/model") === before, "nothing was pushed");
check(by && after.startsWith(by), "the thread says it's addressed by that commit");
await snap("suggestion-applied");

// 6. a reply naming the unpushed commit stays a draft until it's on origin
const ops = () => gh().log.map((l) => l.op);
await key("r");
const pre = await p.evaluate(() => document.querySelector(".rv-composer textarea")?.value ?? "");
check(pre.startsWith(`Addressed in ${after.slice(0, 7)}`), `r prefills the reply: "${pre}"`);
await type("placeholders are filtered out.");
await key("Enter", ["Control"]);
check(!!(await until(() => /waits for/.test(document.querySelector('[data-stop$="PRRT_sb1"] .rv-reply-draft')?.textContent ?? "") || null, "the waiting draft")), "the reply stays a draft, waiting for the push");
check(!ops().length, "and GitHub hasn't seen anything");
await snap("reply-waits-for-push");

// 7. a push to the sandbox's origin sends it into Phil's pending review
git("push", "-q", "origin", "demo/model");
await until(() => !document.querySelector(".rv-reply-draft") || null, "the release", 10000);
const rel = gh().log;
check(rel[0]?.op === "addPullRequestReview" && !("event" in rel[0].input), "after the push: a pending review is created, with no event");
const joined = rel.find((l) => l.op === "addPullRequestReviewThreadReply");
check(joined?.input.pullRequestReviewThreadId === "PRRT_sb1" && joined.input.pullRequestReviewId === gh().prs["43"].pending?.id, "and the reply joins that pending review");
await key("O");
await goto(`${M}PRRT_sb1`, "N");
check(await p.evaluate(() => [...document.querySelectorAll('[data-stop$="PRRT_sb1"] .rv-comment')].some((c) => /placeholders are filtered/.test(c.textContent) && /pending/.test(c.textContent))), "the thread shows it as pending");
await snap("reply-pending-after-push");
await key("O");

// 8. reply to the teammate's question — same pending review; R only opens GitHub
check(await goto(`${M}PRRT_sb3`, "N") || (await goto(`${M}PRRT_sb3`, "n")), "reach the teammate's question");
await key("r");
await type("Yes — switching to the namespace import.");
await key("Enter", ["Control"]);
await until(() => [...document.querySelectorAll('[data-stop$="PRRT_sb3"] .rv-comment')].some((c) => /namespace import/.test(c.textContent) && /pending/.test(c.textContent)) || null, "the pending reply");
const r2 = gh().log.filter((l) => l.op === "addPullRequestReviewThreadReply").pop();
check(r2?.input.pullRequestReviewThreadId === "PRRT_sb3" && r2.input.pullRequestReviewId === joined?.input.pullRequestReviewId, "the second reply joins the same pending review");
await key("R");
const opened1 = await p.evaluate(() => window.__opened.slice(-1)[0]);
check(/discussion_r/.test(opened1 ?? "") && !ops().some((o) => /resolve/i.test(o)), `R opens the conversation on GitHub (${opened1}) and resolves nothing`);
await snap("replies-in-pending-review");

// 9. a teammate's PR: one draft kept here, one range comment into the pending review
await open("/v2/b/repo/review/pr-77");
await goto("l|src/ui/banner.ts|R:4", "j");
await key("c");
await type("Why three attempts? A constant would say.");
await key("Enter", ["Control", "Shift"]);
await until(() => /draft/.test(document.querySelector(".rv-pending")?.textContent ?? "") || null, "the draft");
await goto("l|src/ui/banner.ts|R:10", "j");
await key("x");
await key("x");
await key("c");
await type("Log through the logger, not console.");
await key("Enter", ["Control"]);
await until(() => [...document.querySelectorAll(".rv-comment")].some((c) => /logger/.test(c.textContent) && /pending/.test(c.textContent)) || null, "the pending range comment");
const th = gh().log.filter((l) => l.op === "addPullRequestReviewThread").pop();
check(th?.input.startLine === 10 && th.input.line === 11 && th.input.subjectType === "LINE", "the range comment is a new thread on lines 10–11 of the pending review");
await snap("draft-and-pending");

// 10. reload: nothing lost
await open("/v2/b/repo/review/pr-77");
check(!!(await until(() => (/draft/.test(document.querySelector(".rv-pending")?.textContent ?? "") && [...document.querySelectorAll(".rv-comment")].some((c) => /logger/.test(c.textContent))) || null, "after reload")), "the draft and the pending comment survive a reload");
await snap("after-reload");

// 11. P sends the draft; S opens GitHub; "submitted" only once GitHub says so
await key("P");
await until(() => !document.querySelector(".rv-pending") || null, "the draft sent");
check(gh().prs["77"].pending?.count === 2, "both comments sit in the pending review");
await key("S");
const opened2 = await p.evaluate(() => window.__opened.slice(-1)[0]);
check(opened2 === "https://github.com/sandbox/repo/pull/77/files", `S opens GitHub's files view to submit (${opened2})`);
await snap("open-on-github-to-submit");
const g = gh();
for (const t of g.prs["77"].threads) for (const c of t.comments) c.state = "SUBMITTED";
g.prs["77"].reviews.push({ id: "PRR_phil", author: g.viewer, state: "CHANGES_REQUESTED", body: "Two small things.", at: new Date().toISOString(), url: "" });
g.prs["77"].pending = null;
writeFileSync(join(sandbox, "github.json"), JSON.stringify(g, null, 1));
await until(() => !/pending/.test([...document.querySelectorAll(".rv-comment .rv-chip")].map((c) => c.textContent).join(" ")) && /requested changes/.test(document.querySelector(".rv-sub")?.textContent ?? "") || null, "the submitted review", 10000);
const ledger = JSON.parse(readFileSync(join(repo, ".git/stack-review-ledger.json"), "utf8")).items;
check(ledger.length >= 4 && ledger.every((i) => i.key && i.state === "sent"), "every ledger item carries a key and was sent");
await snap("submitted-on-github");
await key("Tab");
await snap("conversation");

// 12. the only GitHub writes were the three pending-review mutations, never with an event
const all = gh().log;
check(all.every((l) => ["addPullRequestReview", "addPullRequestReviewThread", "addPullRequestReviewThreadReply"].includes(l.op)) && !all.some((l) => "event" in l.input), `GitHub saw only pending-review writes: ${[...new Set(all.map((l) => l.op))].join(", ")}`);

check(!errors.length, `no page errors${errors.length ? `: ${errors.join(" | ")}` : ""}`);
await b.close();
console.log(`screenshots: ${out}`);
process.exit(failed ? 1 : 0);
