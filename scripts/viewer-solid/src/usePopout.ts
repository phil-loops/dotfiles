import { createSignal } from "solid-js";
import { createStore } from "solid-js/store";

// Pop a chat out into a tmux window (fresh, or split an existing pane). Lists live tmux targets
// on open, then hands the session + branch to /chat-popout.
export function usePopout(deps: { session: () => string | undefined; branch: () => string }) {
  const [popoutOpen, setPopoutOpen] = createSignal(false);
  const [targets, setTargets] = createStore<{ target: string; name: string; panes: number }[]>([]);
  const [popoutMsg, setPopoutMsg] = createSignal<string | null>(null);
  const togglePopout = async () => {
    if (popoutOpen()) {
      setPopoutOpen(false);
      return;
    }
    setPopoutMsg(null);
    setPopoutOpen(true);
    try {
      const r = await fetch("/tmux-targets").then((res) => res.json());
      setTargets(Array.isArray(r) ? r : []);
    } catch {
      setTargets([]);
    }
  };
  const popOut = async (target: string) => {
    setPopoutOpen(false);
    setPopoutMsg("opening…");
    try {
      const r = await fetch("/chat-popout", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ session: deps.session(), branch: deps.branch(), target }),
      }).then((res) => res.json());
      setPopoutMsg(r.ok ? "✦ opened in tmux" : r.err || "couldn’t open");
    } catch {
      setPopoutMsg("couldn’t reach the server");
    }
    setTimeout(() => setPopoutMsg(null), 4000);
  };
  return { popoutOpen, setPopoutOpen, targets, popoutMsg, togglePopout, popOut };
}
