// ServerStatus — a quiet bottom-left dot that reports whether the review server is
// reachable. Light poll of /sig (a cheap GET) with a short timeout; calm patina dot
// when healthy, ember "reconnecting…" when the server is down (e.g. the ~2s window
// during a restart). Self-contained (own <style>), mounts with one line.
//
// Polls ONLY while the tab is visible — same discipline as the /events SSE — so a
// backgrounded tab doesn't keep the server alive and defeat its idle-reap.
import { createSignal, onCleanup, Show } from "solid-js";

export function ServerStatus() {
  const [up, setUp] = createSignal(true); // optimistic; flips on the first failed poll
  let timer: ReturnType<typeof setInterval> | null = null;

  const ping = async () => {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 3000);
    try {
      const r = await fetch("/sig", { signal: ctrl.signal, cache: "no-store" });
      setUp(r.ok);
    } catch {
      setUp(false); // network error / abort / connection refused → server unreachable
    } finally {
      clearTimeout(t);
    }
  };

  const start = () => {
    if (timer) return;
    ping();
    timer = setInterval(ping, 4000);
  };
  const stop = () => {
    if (timer) { clearInterval(timer); timer = null; }
  };
  const onVisibility = () => (document.hidden ? stop() : start());

  if (!document.hidden) start();
  document.addEventListener("visibilitychange", onVisibility);
  onCleanup(() => {
    document.removeEventListener("visibilitychange", onVisibility);
    stop();
  });

  return (
    <div class="srvstat" classList={{ down: !up() }} title={up() ? "review server connected" : "review server unreachable — reconnecting"}>
      <style>{CSS}</style>
      <span class="srvstat-dot" />
      <Show when={!up()}>
        <span class="srvstat-label">reconnecting…</span>
      </Show>
    </div>
  );
}

const CSS = `
.srvstat { position: fixed; left: 14px; bottom: 12px; z-index: 70; display: flex;
  align-items: center; gap: 7px; pointer-events: none; }
.srvstat-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--patina);
  box-shadow: 0 0 6px var(--patina); opacity: .5; transition: background .2s, opacity .2s, box-shadow .2s; }
.srvstat.down .srvstat-dot { background: var(--del); box-shadow: 0 0 9px var(--del); opacity: 1;
  animation: srvstat-pulse 1.1s ease-in-out infinite; }
.srvstat-label { font-family: var(--mono); font-size: 11px; color: var(--del); letter-spacing: .02em; }
@keyframes srvstat-pulse { 0%, 100% { opacity: 1; } 50% { opacity: .35; } }
@media (prefers-reduced-motion: reduce) { .srvstat.down .srvstat-dot { animation: none; } }
`;
