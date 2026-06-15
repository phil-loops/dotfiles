// ── freshness chip ─────────────────────────────────────
// "is this live / when did it last change" indicator. Rides the shared SSE /events
// stream that detail.js opens (exposed as window.__events) — no independent polling.
// Connection state comes straight from the EventSource (readyState), and an `update`
// event marks a real forest change. Falls back to its own stream if the shared one
// isn't there, so it can't break. Pulses on change.
(function () {
  if (typeof LIVE !== "undefined" && !LIVE) return; // static snapshot → no server
  let lastChange = 0;

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

  // EventSource.readyState: 0 CONNECTING · 1 OPEN · 2 CLOSED
  const es = window.__events || new EventSource("/events");
  function paint() {
    const st = es.readyState;
    chip.classList.toggle("stale", st === 2);
    txt.textContent =
      st === 2
        ? "disconnected"
        : st !== 1
          ? "connecting…"
          : lastChange
            ? "updated " + ago(Date.now() - lastChange)
            : "live";
  }

  es.addEventListener("update", () => {
    lastChange = Date.now();
    chip.classList.add("pulse");
    setTimeout(() => chip.classList.remove("pulse"), 600);
    paint();
  });

  paint();
  setInterval(paint, 1000); // keep the "updated Ns ago" label ticking
})();
