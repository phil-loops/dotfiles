export async function fetchJSON<T = unknown>(path: string): Promise<T> {
  const r = await fetch(path);
  if (!r.ok) throw new Error(`${path} → ${r.status}`);
  return (await r.json()) as T;
}

// ?branch=<project>#node=<branch> — the same URL scheme the vanilla viewer uses, so
// existing links (and the homepage's hop-to-node) work unchanged.
export function nodeFromUrl(): string {
  const hash = new URLSearchParams(location.hash.replace(/^#/, ""));
  return (
    hash.get("node") ||
    new URLSearchParams(location.search).get("branch") ||
    ""
  );
}
