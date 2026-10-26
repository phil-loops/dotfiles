// The key dispatcher: one keydown listener turns keys into registered commands, run by the runner.
import { createKeymap, keyName } from "./keys";
import { liveScopes } from "./model";
import { commands } from "./registry";
import { dispatch } from "./runner";
import { menuOpen, pendingKeys, setPendingKeys } from "./ui";

export function installKeys(): void {
  const keymap = createKeymap(commands().filter((c) => c.keys?.length).map((c) => ({ id: c.id, keys: c.keys!, scope: c.scope })));
  document.addEventListener("mousedown", () => {
    keymap.reset();
    setPendingKeys("");
  });
  document.addEventListener("keydown", (e) => {
    if (menuOpen()) return; // the menu owns the keyboard while it's open
    const t = e.target as HTMLElement | null;
    if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) {
      // esc leaves a field, so the page's keys work again without reaching for the mouse
      if (e.key === "Escape" && !e.defaultPrevented) t.blur();
      return;
    }
    const key = keyName(e);
    if (!key) return;
    const fed = keymap.feed(key, liveScopes());
    // a prefix (space, g) waits for its next key as long as it takes, like Helix; the popup shows what can follow
    if (fed.kind === "pending") {
      setPendingKeys(fed.prefix);
      e.preventDefault();
      return;
    }
    const wasPending = !!pendingKeys();
    setPendingKeys("");
    if (wasPending && fed.kind === "none") e.preventDefault();
    if (fed.kind === "run") {
      e.preventDefault();
      dispatch(fed.id, "key", { event: e });
    }
  });
}
