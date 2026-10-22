// The key dispatcher: one keydown listener turns keys into registered commands, run by the runner.
import { createKeymap, keyName } from "./keys";
import { liveScopes } from "./model";
import { commands } from "./registry";
import { dispatch } from "./runner";
import { menuOpen, setPendingKeys } from "./ui";

export function installKeys(): void {
  const keymap = createKeymap(commands().filter((c) => c.keys?.length).map((c) => ({ id: c.id, keys: c.keys!, scope: c.scope })));
  let pendingTimer: number | undefined;
  document.addEventListener("keydown", (e) => {
    if (menuOpen()) return; // the menu owns the keyboard while it's open
    const t = e.target as HTMLElement | null;
    if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return;
    const key = keyName(e);
    if (!key) return;
    const fed = keymap.feed(key, liveScopes());
    clearTimeout(pendingTimer);
    if (fed.kind === "pending") {
      setPendingKeys(fed.prefix);
      pendingTimer = window.setTimeout(() => {
        keymap.reset();
        setPendingKeys("");
      }, 1200);
      e.preventDefault();
      return;
    }
    setPendingKeys("");
    if (fed.kind === "run") {
      e.preventDefault();
      dispatch(fed.id, "key", { event: e });
    }
  });
}
