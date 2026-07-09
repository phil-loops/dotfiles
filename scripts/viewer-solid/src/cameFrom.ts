import { createSignal } from "solid-js";

// the node you last left via "back to the forest map", so the overview can emphasize where you
// were. Module-scope so it survives the route change from a node to its forest overview.
export const [cameFrom, setCameFrom] = createSignal("");
