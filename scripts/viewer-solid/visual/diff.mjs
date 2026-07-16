// diff — pixel-compare two shot directories; write diff PNGs for failures.
//   node diff.mjs --a ./baseline --b ./current [--threshold 0.001] [--out ./diffs] [--only name1,name2]
// threshold is the FRACTION of pixels allowed to differ per surface (default 0.1%).
import { PNG } from "pngjs";
import pixelmatch from "pixelmatch";
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const arg = (name, dflt) => {
  const i = process.argv.indexOf("--" + name);
  return i === -1 ? dflt : process.argv[i + 1];
};
const A = arg("a", "./baseline");
const B = arg("b", "./current");
const OUT = arg("out", "./diffs");
const THRESHOLD = parseFloat(arg("threshold", "0.001"));

mkdirSync(OUT, { recursive: true });
const only = (arg("only", "") || "").split(",").filter(Boolean);
let bad = 0;
const files = readdirSync(A)
  .filter((f) => f.endsWith(".png"))
  .filter((f) => only.length === 0 || only.includes(f.replace(/\.png$/, "")))
  .sort();
for (const f of files) {
  if (!existsSync(join(B, f))) {
    console.error(`✗ ${f}: missing in ${B}`);
    bad++;
    continue;
  }
  const a = PNG.sync.read(readFileSync(join(A, f)));
  const b = PNG.sync.read(readFileSync(join(B, f)));
  if (a.width !== b.width || a.height !== b.height) {
    console.error(`✗ ${f}: size ${a.width}x${a.height} → ${b.width}x${b.height}`);
    bad++;
    continue;
  }
  const d = new PNG({ width: a.width, height: a.height });
  const n = pixelmatch(a.data, b.data, d.data, a.width, a.height, { threshold: 0.1 });
  const frac = n / (a.width * a.height);
  if (frac > THRESHOLD) {
    writeFileSync(join(OUT, f), PNG.sync.write(d));
    console.error(`✗ ${f}: ${(frac * 100).toFixed(3)}% pixels differ (${n}) → ${join(OUT, f)}`);
    bad++;
  } else {
    console.log(`✓ ${f}${n ? ` (${n}px)` : ""}`);
  }
}
process.exit(bad ? 1 : 0);
