import { spawnSync } from "child_process";
import { readFileSync, writeFileSync } from "fs";

export interface ConflictContext {
  branch: string;
  onto: string;
  files: string[];
  repoRoot: string;
}

export type ResolveResult =
  | { kind: "resolved"; files: string[] }
  | { kind: "unresolvable"; reason: string }
  | { kind: "error"; reason: string };

/**
 * Hand a rebase conflict to Claude. Reads each conflicted file's on-disk
 * contents (which still contain <<<<<<< markers), asks Claude to emit the
 * resolved contents, then writes the resolutions back to disk.
 *
 * Caller is responsible for `git add` + `git rebase --continue` after this
 * returns `resolved`.
 */
export function resolveWithClaude(ctx: ConflictContext): ResolveResult {
  const fileBlocks = ctx.files
    .map((f) => {
      const content = safeRead(`${ctx.repoRoot}/${f}`);
      return `<file path="${f}">\n${content}\n</file>`;
    })
    .join("\n\n");

  const prompt = `You are resolving a git rebase conflict.

We are rebasing branch \`${ctx.branch}\` onto \`${ctx.onto}\`.

For each file below, output the fully resolved content wrapped in:
<resolved path="path/to/file">
...full resolved file contents, no conflict markers...
</resolved>

Do not include anything outside <resolved> blocks except, optionally, a leading "UNRESOLVABLE: <reason>" line.

If any file cannot be safely resolved (truly ambiguous intent, both changes can't coexist, etc.), output instead ONLY:
UNRESOLVABLE: <short reason>

Prefer taking the intent of both sides where they don't conflict semantically. When in doubt, prefer the incoming change from \`${ctx.onto}\` (the rebase target) unless it's clearly a regression.

Files with conflicts:

${fileBlocks}`;

  const result = spawnSync(
    "claude",
    ["-p", prompt, "--output-format", "text", "--dangerously-skip-permissions"],
    {
      encoding: "utf-8",
      timeout: 5 * 60 * 1000,
      maxBuffer: 100 * 1024 * 1024,
    },
  );

  if (result.error) {
    return { kind: "error", reason: result.error.message };
  }
  if (result.status !== 0) {
    return { kind: "error", reason: result.stderr || `exit ${result.status}` };
  }

  const output = (result.stdout || "").trim();

  const unresolvable = output.match(/^UNRESOLVABLE:\s*(.+)$/m);
  if (unresolvable) {
    return { kind: "unresolvable", reason: unresolvable[1].trim() };
  }

  const resolutions = parseResolutions(output);
  if (resolutions.size === 0) {
    return { kind: "error", reason: "no <resolved> blocks in output" };
  }

  const missing = ctx.files.filter((f) => !resolutions.has(f));
  if (missing.length > 0) {
    return { kind: "error", reason: `missing resolutions for: ${missing.join(", ")}` };
  }

  for (const [path, content] of resolutions) {
    writeFileSync(`${ctx.repoRoot}/${path}`, content);
  }

  return { kind: "resolved", files: [...resolutions.keys()] };
}

function parseResolutions(output: string): Map<string, string> {
  const out = new Map<string, string>();
  const re = /<resolved\s+path="([^"]+)"\s*>\n?([\s\S]*?)\n?<\/resolved>/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(output)) !== null) {
    out.set(m[1], m[2]);
  }
  return out;
}

function safeRead(path: string): string {
  try {
    return readFileSync(path, "utf-8");
  } catch {
    return "";
  }
}
