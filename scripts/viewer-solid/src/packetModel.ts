// The review packet's data and its pure rules — what the server sends (srv/packet.py), the hand
// parts the words column edits, and the one live hint (a claim nobody could check). Rendering
// stays on the server (review_packet.py), so the preview is the exact body that will publish.

export type Hand = { lead: string; intent: string[] | null; not: string[]; read: string[] | null };

export type Sections = {
  lead: string;
  intent: string[];
  intentSource: "hand" | "seeded";
  intentSeed: string[];
  notDerived: string[];
  notHand: string[];
  read: string[];
  readSource: "hand" | "model" | "layers";
  readGenerated: string[];
  where: string[];
  verified: string[];
};

export type Finding = { path: string; line: number | null; url: string; body: string; claim: number | null; outdated: boolean };

export type Review = {
  stale: boolean;
  mergedSince: number[];
  openedSince: number[];
  updatedBody: string;
  url: string;
  number: number;
  claims: string[];
  findings: Finding[];
  botRan: boolean;
  packet: boolean;
};

export type Packet = {
  ok: boolean;
  err?: string;
  branch: string;
  tree: string;
  title: string;
  label: boolean;
  labelName: string;
  sections: Sections;
  hand: Hand;
  body: string;
  packetBody: string;
  legacyBody: boolean;
  guide: { state: "none" | "running" | "done" | "failed" | "empty"; err?: string; tree?: string };
  review: Review | null;
};

export const MAX_CLAIMS = 5;
export const EMPTY_HAND: Hand = { lead: "", intent: null, not: [], read: null };

/** A hand value with blank lines dropped — what save sends and dirty-checks compare. */
export function normalizeHand(h: Hand): Hand {
  const clean = (xs: string[]) => xs.map((x) => x.replace(/\s+/g, " ").trim()).filter(Boolean);
  return {
    lead: h.lead.trim(),
    intent: h.intent === null ? null : clean(h.intent),
    not: clean(h.not),
    read: h.read === null ? null : clean(h.read),
  };
}

export const sameHand = (a: Hand, b: Hand): boolean => JSON.stringify(normalizeHand(a)) === JSON.stringify(normalizeHand(b));

/** The JSON stored in branch.<b>.stack-packet: only what was written by hand; "" clears it. */
export function handJson(h: Hand): string {
  const n = normalizeHand(h);
  const keep: Record<string, unknown> = {};
  if (n.lead) keep.lead = n.lead;
  if (n.intent !== null) keep.intent = n.intent;
  if (n.not.length) keep.not = n.not;
  if (n.read !== null) keep.read = n.read;
  return Object.keys(keep).length ? JSON.stringify(keep) : "";
}

// verbs that name an activity instead of an outcome — a reviewer can't confirm "improves X"
const VAGUE = /\b(improv(e|es|ed|ing)|clean(s|ed|ing)? ?up|cleanup|refactor(s|ed|ing)?( things| stuff| code)?|tid(y|ies|ied)|tweak(s|ed)?|polish(es|ed)?|rework(s|ed)?|adjust(s|ed)?|various|misc(ellaneous)?|stuff|things|better|nicer|handles?( things| stuff)?|updates?( things| stuff| code)?|fix(es)? (things|stuff|issues|bugs))\b/i;

/** A non-blocking note when a claim couldn't be confirmed or contradicted by reading the diff. */
export function claimHint(claim: string): string | null {
  const c = claim.trim();
  if (!c) return null;
  if (c.split(/\s+/).length < 3) return "too short to check — say what the diff does to what";
  const m = VAGUE.exec(c);
  if (m) return `“${m[0]}” isn't checkable — name the behavior a reviewer can confirm in the diff`;
  return null;
}

/** "#43 merged since" / "#43, #44 merged since · #45 opened" — what moved since publishing. */
export function staleLabel(r: Pick<Review, "mergedSince" | "openedSince">): string {
  const refs = (ns: number[]) => ns.map((n) => `#${n}`).join(", ");
  return [
    r.mergedSince.length ? `${refs(r.mergedSince)} merged since` : "",
    r.openedSince.length ? `${refs(r.openedSince)} opened since` : "",
  ].filter(Boolean).join(" · ");
}

/** Unresolved bot findings grouped under the claim each disputes; null holds the unplaced. */
export function findingsByClaim(r: Pick<Review, "findings" | "claims">): { claim: number | null; text: string; findings: Finding[] }[] {
  const out: { claim: number | null; text: string; findings: Finding[] }[] = [];
  r.claims.forEach((c, i) => {
    const fs = r.findings.filter((f) => f.claim === i);
    if (fs.length) out.push({ claim: i, text: c, findings: fs });
  });
  const loose = r.findings.filter((f) => f.claim === null || f.claim >= r.claims.length);
  if (loose.length) out.push({ claim: null, text: "", findings: loose });
  return out;
}

/** The bot's verdict in two words, for a row: "claims held" | "2 findings" | "" (not reviewed). */
export function verdictLabel(r: Pick<Review, "findings" | "botRan" | "packet"> | null | undefined): string {
  if (!r) return "";
  if (r.findings.length) return `${r.findings.length} finding${r.findings.length === 1 ? "" : "s"}`;
  return r.botRan && r.packet ? "claims held" : "";
}
