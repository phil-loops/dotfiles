export async function fetchJSON(path) {
  const r = await fetch(path);
  if (!r.ok) throw new Error(`${path} → ${r.status}`);
  return r.json();
}

// ?branch=<project>#node=<branch> — the same URL scheme the vanilla viewer uses, so
// existing links (and the homepage's hop-to-node) work unchanged.
export function nodeFromUrl() {
  const hash = new URLSearchParams(location.hash.replace(/^#/, ""));
  return (
    hash.get("node") ||
    new URLSearchParams(location.search).get("branch") ||
    ""
  );
}
