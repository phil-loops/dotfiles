// ── freshness chip ─────────────────────────────────────
// "is this live / when did it last change" indicator. Self-contained: polls the
// cheap /sig hash on its own cadence (no coupling to the model poll in detail.js),
// tracks the last change + last successful contact, and renders a ticking chip in
// the brand. Pulses on a real change so you can see it update while watching.
(function () {
  if (typeof LIVE !== "undefined" && !LIVE) return; // static snapshot → no server
  const POLL_MS = 2000,
    STALE_MS = 8000;
  let lastSig = null,
    lastChange = 0,
    lastOk = 0;

  const chip = el("div", "freshness");
  chip.id = "freshness";
  const dot = el("span", "fdot"),
    txt = el("span", "ftxt");
  chip.append(dot, txt);
  ($(".brand") || document.body).appendChild(chip);

  const ago = (ms) => {
    const s = Math.round(ms / 1000);
    if (s < 5) return "just now";
    if (s < 60) return s + "s ago";
    const m = Math.round(s / 60);
    return m < 60 ? m + "m ago" : Math.round(m / 60) + "h ago";
  };

  async function poll() {
    try {
      const { sig } = await (await fetch("/sig")).json();
      lastOk = Date.now();
      if (lastSig === null) {
        lastSig = sig;
        lastChange = Date.now();
      } else if (sig !== lastSig) {
        lastSig = sig;
        lastChange = Date.now();
        chip.classList.add("pulse");
        setTimeout(() => chip.classList.remove("pulse"), 600);
      }
    } catch (e) {
      /* network blip — paint() reflects it as disconnected */
    }
  }

  function paint() {
    const now = Date.now();
    const live = now - lastOk < STALE_MS;
    chip.classList.toggle("stale", !live);
    txt.textContent = !lastOk
      ? "connecting…"
      : !live
        ? "disconnected"
        : lastChange
          ? "updated " + ago(now - lastChange)
          : "live";
  }

  poll();
  paint();
  setInterval(poll, POLL_MS);
  setInterval(paint, 1000);
})();
