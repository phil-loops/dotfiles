// ServerStatus — a quiet bottom-left dot that reports whether the review server is
// reachable. Light poll of /sig (a cheap GET) with a short timeout; calm patina dot
// when healthy, ember "reconnecting…" when the server is down (e.g. the ~2s window
// during a restart). Mounts with one line.
//
// Polls ONLY while the tab is visible — same discipline as the /events SSE — so a
// backgrounded tab doesn't keep the server alive and defeat its idle-reap.
import { createSignal, onCleanup, Show } from "solid-js";
import { canMutate } from "./provider";

export function ServerStatus() {
  if (!canMutate) return null; // static snapshot: no live server to monitor
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
    <div
      class="srvstat group pointer-events-none fixed bottom-3 left-[14px] z-[70] flex cursor-pointer items-center gap-[7px]"
      classList={{ down: !up() }}
      title={up() ? "review server connected — click to re-check" : "review server unreachable — click to reconnect now"}
      onClick={ping}
    >
      <span
        class="srvstat-dot pointer-events-auto h-2 w-2 rounded-full transition-[background,opacity,box-shadow] duration-200 group-hover:opacity-100"
        classList={{
          "bg-patina opacity-50 shadow-[0_0_6px_var(--color-patina)]": up(),
          "animate-srvstat-pulse bg-del opacity-100 shadow-[0_0_9px_var(--color-del)] motion-reduce:animate-none": !up(),
        }}
      />
      <Show when={!up()}>
        <span class="srvstat-label pointer-events-auto font-mono text-[11px] tracking-[0.02em] text-del">reconnecting…</span>
      </Show>
    </div>
  );
}
