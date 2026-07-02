import registry from "./chat-actions.json";
import "./chatActions.css";

// The frontend half of the ONE action registry (chat-actions.json — srv/prompts.py reads the same
// file to teach Claude the menu). The read-only chat can't touch the tree; instead it emits a
// ```loops-action fenced JSON block, we render it as a button here, and a click POSTs to an endpoint
// that already exists. The registry is the single source of truth for what an action IS — this file
// only parses the block and dispatches it, so the taught vocabulary and the wired call never drift.

export interface ActionDef {
  id: string;
  endpoint: string;
  scope: "file" | "branch";
  confirm: boolean;
  label: string;
  describe: string;
  params: { name: string; desc: string }[];
  body: unknown;
}

export interface ActionSpec {
  action: string;
  label?: string;
  params?: Record<string, unknown>;
}

export type Segment =
  | { kind: "md"; text: string }
  | { kind: "action"; spec: ActionSpec }
  | { kind: "pending" }; // an action block still streaming (fence not closed yet)

const ACTIONS: ActionDef[] = (registry as { actions: ActionDef[] }).actions;

export function actionById(id: string): ActionDef | undefined {
  return ACTIONS.find((a) => a.id === id);
}

function parseSpec(json: string): ActionSpec | null {
  try {
    const o = JSON.parse(json);
    if (o && typeof o.action === "string" && actionById(o.action)) {
      return { action: o.action, label: o.label, params: o.params || {} };
    }
  } catch {
    // partial/invalid JSON — treat as not-an-action so it renders as prose
  }
  return null;
}

const FENCE = /```loops-action[ \t]*\r?\n([\s\S]*?)```/g;
const OPEN = "```loops-action";

// Split an assistant turn into markdown prose and action segments. A closed loops-action fence that
// parses becomes an action; one that doesn't parse falls back to raw markdown (so nothing vanishes).
// A trailing UNCLOSED fence (mid-stream) becomes a single "pending" segment so we never flash raw
// JSON at the reader before the button is ready.
export function parseSegments(text: string): Segment[] {
  const segs: Segment[] = [];
  let last = 0;
  let m: RegExpExecArray | null;
  FENCE.lastIndex = 0;
  while ((m = FENCE.exec(text)) !== null) {
    if (m.index > last) {
      segs.push({ kind: "md", text: text.slice(last, m.index) });
    }
    const spec = parseSpec(m[1]);
    segs.push(spec ? { kind: "action", spec } : { kind: "md", text: m[0] });
    last = FENCE.lastIndex;
  }
  const rest = text.slice(last);
  const open = rest.indexOf(OPEN);
  if (open >= 0) {
    if (open > 0) {
      segs.push({ kind: "md", text: rest.slice(0, open) });
    }
    segs.push({ kind: "pending" });
  } else if (rest) {
    segs.push({ kind: "md", text: rest });
  }
  return segs;
}

// Resolve the registry's body template against the click context: "$branch"/"$path" come from the
// chat's scope, "$<param>" from what Claude put in the block. Empty results are dropped so an absent
// optional/context value just omits its key rather than sending an empty string.
function resolve(tpl: unknown, spec: ActionSpec, ctx: { branch: string; path: string }): unknown {
  if (typeof tpl === "string") {
    if (!tpl.startsWith("$")) {
      return tpl;
    }
    const key = tpl.slice(1);
    if (key === "branch") {
      return ctx.branch;
    }
    if (key === "path") {
      return ctx.path;
    }
    return spec.params?.[key];
  }
  if (Array.isArray(tpl)) {
    return tpl.map((v) => resolve(v, spec, ctx));
  }
  if (tpl && typeof tpl === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(tpl)) {
      const rv = resolve(v, spec, ctx);
      if (rv !== undefined && rv !== "") {
        out[k] = rv;
      }
    }
    return out;
  }
  return tpl;
}

// POST the resolved body to the action's endpoint. Endpoints answer {ok, err?} (and often out) —
// normalize to a single {ok, msg} the button can show inline.
export async function runAction(
  spec: ActionSpec,
  ctx: { branch: string; path: string },
): Promise<{ ok: boolean; msg: string }> {
  const def = actionById(spec.action);
  if (!def) {
    return { ok: false, msg: `unknown action “${spec.action}”` };
  }
  if (def.scope === "file" && !ctx.path) {
    return { ok: false, msg: "this action needs a file — open a file-scoped chat" };
  }
  try {
    const res = await fetch(def.endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(resolve(def.body, spec, ctx)),
    });
    let data: { ok?: boolean; err?: string } = {};
    try {
      data = await res.json();
    } catch {
      // some endpoints answer empty on success — a 2xx with no body is still a win
    }
    const ok = res.ok && data.ok !== false;
    return { ok, msg: ok ? "done" : data.err || `failed (${res.status})` };
  } catch (e) {
    return { ok: false, msg: e instanceof Error ? e.message : "couldn’t reach the server" };
  }
}
