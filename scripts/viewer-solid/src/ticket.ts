// Mirrors srv/review.py ticket_set's shape check ([A-Za-z]+-\d+) so a typo errors inline
// instead of after a round-trip. "" clears the ticket; null = invalid.
export function normalizeTicket(raw: string): string | null {
  const v = raw.trim().toUpperCase();
  if (!v) return "";
  const m = /^([A-Z]+)-?(\d+)$/.exec(v);
  if (m) return `${m[1]}-${m[2]}`;
  if (/^\d+$/.test(v)) return `LOO-${v}`;
  return null;
}
