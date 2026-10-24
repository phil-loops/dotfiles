// npm run review-walkthrough -- --base http://127.0.0.1:<port> --sandbox <dir> [--out <dir>]
//
// The review page end to end on a `viewer-sandbox <dir> --github` server, keys only, against its
// fake GitHub (<dir>/github.json — never the real one): threads inline, show outdated, types on K,
// a second-reader note and its draft, apply suggestion (a local commit), a reply naming that
// unpushed commit waits, a sandbox push releases it, reply + resolve on a teammate's question, a
// review on a teammate's PR (two pending comments, one a range) that survives a reload and is
// finished as Request changes. Screenshots of each step land in --out. Exits non-zero on a miss.
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync } from "node:fs";
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

// 6. a reply naming the unpushed commit waits for the push
await key("r");
const pre = await p.evaluate(() => document.querySelector(".rv-composer textarea")?.value ?? "");
check(pre.startsWith(`Addressed in ${after.slice(0, 7)}`), `r prefills the reply: "${pre}"`);
await type("placeholders are filtered out.");
await key("Enter", ["Control"]);
check(!!(await until(() => document.querySelector('[data-stop$="PRRT_sb1"] .rv-comment-waiting'), "the waiting reply")), "the reply waits for the push");
check(!gh().log.some((l) => l.op === "reply"), "and GitHub hasn't seen it");
await snap("reply-waits-for-push");

// 7. a push to the sandbox's origin releases it
git("push", "-q", "origin", "demo/model");
const posted = await until(() => !document.querySelector(".rv-comment-waiting") || null, "the release", 10000);
check(!!posted && gh().log.some((l) => l.op === "reply" && l.args.thread === "PRRT_sb1"), "after the push the reply posts");
await key("O");
await goto(`${M}PRRT_sb1`, "N");
await snap("reply-released-after-push");
await key("O");

// 8. reply to the teammate's question, then resolve it
check(await goto(`${M}PRRT_sb3`, "N") || (await goto(`${M}PRRT_sb3`, "n")), "reach the teammate's question");
await key("r");
await type("Yes — switching to the namespace import.");
await key("Enter", ["Control"]);
await until(() => [...document.querySelectorAll('[data-stop$="PRRT_sb3"] .rv-comment')].some((c) => /namespace import/.test(c.textContent) && !c.classList.contains("rv-comment-sending")), "the posted reply");
await key("R");
await until(() => !!document.querySelector('[data-stop$="PRRT_sb3"] .rv-chip-ok'), "resolved");
const log = gh().log;
check(log.some((l) => l.op === "reply" && l.args.thread === "PRRT_sb3") && log.some((l) => l.op === "resolve" && l.args.thread === "PRRT_sb3"), "reply + resolve reached the (fake) GitHub");
await snap("replied-and-resolved");

// 9. a review on a teammate's PR: two pending comments, one on a range
await open("/v2/b/repo/review/pr-77");
await goto("l|src/ui/banner.ts|R:4", "j");
await key("c");
await type("Why three attempts? A constant would say.");
await key("Enter", ["Control"]);
await until(() => document.querySelectorAll(".rv-pending").length === 1, "the first pending comment");
await goto("l|src/ui/banner.ts|R:10", "j");
await key("x");
await key("x");
await key("c");
await type("Log through the logger, not console.");
await key("Enter", ["Control"]);
await until(() => document.querySelectorAll(".rv-pending").length === 2, "the second pending comment");
check(!gh().log.some((l) => l.op === "review"), "pending comments stay local");
await snap("review-two-pending");

// 10. reload: nothing lost
await open("/v2/b/repo/review/pr-77");
check((await until(() => document.querySelectorAll(".rv-pending").length === 2 || null, "pending after reload")) === true, "both pending comments survive a reload");
await snap("pending-after-reload");

// 11. finish as Request changes
await key("S");
await type("Two small things before this lands.");
await key("Digit3", ["Alt"]);
await snap("finish-your-review");
await key("Enter", ["Control"]);
await until(() => document.querySelectorAll(".rv-pending").length === 0 && document.querySelectorAll(".rv-thread").length === 2 || null, "the submitted review's threads");
const rv = gh().log.filter((l) => l.op === "review").pop();
check(rv?.args.event === "REQUEST_CHANGES" && rv.args.threads.length === 2 && rv.args.threads.some((t) => t.startLine === 10 && t.line === 11), "submitted as Request changes with both comments (one on lines 10–11)");
await snap("review-submitted");
await key("Tab");
await snap("conversation");

check(!errors.length, `no page errors${errors.length ? `: ${errors.join(" | ")}` : ""}`);
await b.close();
console.log(`screenshots: ${out}`);
process.exit(failed ? 1 : 0);
