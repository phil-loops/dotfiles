// Your keys from ~/.dotfiles/canopy/keys.toml, injected into the page by the server and laid over
// the registry's defaults before the keyboard is installed.
import { applyKeys, clashes } from "./bindings";
import { commands } from "./registry";

export const customized = new Set<string>();
export let keyProblems: string[] = [];

export function applyUserKeys(): void {
  const given = (window as unknown as { __CANOPY_KEYS__?: { keys: Record<string, string[]>; errors: string[] } }).__CANOPY_KEYS__;
  const keys = given?.keys ?? {};
  for (const id of Object.keys(keys)) customized.add(id);
  keyProblems = [...(given?.errors ?? []), ...applyKeys(commands(), keys), ...clashes(commands())];
}
