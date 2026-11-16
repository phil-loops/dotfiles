// evidence-measure.mjs — how much two captures differ: changed pixels, the largest channel delta, the
// box that holds every change. A diagnostic beside the evidence, never evidence itself.
//   node evidence-measure.mjs <before.png> <after.png>     (NODE_PATH = node_modules with sharp)
import { createRequire } from "node:module";
import path from "node:path";
const sharp = createRequire(path.join(process.env.NODE_PATH || "", "noop.js"))("sharp");
const [a, b] = await Promise.all(process.argv.slice(2).map((p) => sharp(p).ensureAlpha().raw().toBuffer({ resolveWithObject: true })));
const out = { changedPixels: 0, maxDelta: 0, box: null, size: [a.info.width, a.info.height] };
if (a.info.width !== b.info.width || a.info.height !== b.info.height) {
  out.sizeChanged = [b.info.width, b.info.height];
} else {
  const W = a.info.width;
  let x0 = Infinity, y0 = Infinity, x1 = -1, y1 = -1;
  for (let i = 0, p = 0; i < a.data.length; i += 4, p++) {
    let d = 0;
    for (let c = 0; c < 4; c++) d = Math.max(d, Math.abs(a.data[i + c] - b.data[i + c]));
    if (!d) continue;
    out.changedPixels++;
    out.maxDelta = Math.max(out.maxDelta, d);
    const x = p % W, y = (p / W) | 0;
    x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x); y1 = Math.max(y1, y);
  }
  if (out.changedPixels) out.box = [x0, y0, x1 - x0 + 1, y1 - y0 + 1];
}
console.log(JSON.stringify(out));
