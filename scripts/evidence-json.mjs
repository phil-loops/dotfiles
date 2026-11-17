// evidence-json.mjs — how an endpoint capture becomes a comparable artifact: masks, then canonical JSON.
//
// A mask is "$..key" (drop that key at any depth) or "$.a.b[0].c" (drop one exact path). Nothing is
// masked by default: what varies between two attempts shows up as "not repeatable" and gets masked by name.

function dropExact(node, segs) {
  if (node === null || typeof node !== "object" || !segs.length) return;
  const [head, ...rest] = segs;
  if (!rest.length) {
    if (Array.isArray(node) && typeof head === "number") node.splice(head, 1);
    else delete node[head];
    return;
  }
  dropExact(node[head], rest);
}

function dropEverywhere(node, key) {
  if (node === null || typeof node !== "object") return;
  if (!Array.isArray(node)) delete node[key];
  for (const v of Object.values(node)) dropEverywhere(v, key);
}

function segments(p) {
  return [...p.slice(1).matchAll(/\.([^.[\]]+)|\[(\d+)\]/g)].map((m) => (m[2] !== undefined ? Number(m[2]) : m[1]));
}

export function mask(body, masks = []) {
  const out = structuredClone(body);
  for (const m of masks) {
    if (m.startsWith("$..")) dropEverywhere(out, m.slice(3));
    else if (m.startsWith("$.")) dropExact(out, segments(m));
    else throw new Error(`mask ${m} must start with $. or $..`);
  }
  return out;
}

export function canon(v) {
  if (v === null || typeof v !== "object") return JSON.stringify(v);
  if (Array.isArray(v)) return `[${v.map(canon).join(",")}]`;
  return `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canon(v[k])}`).join(",")}}`;
}
