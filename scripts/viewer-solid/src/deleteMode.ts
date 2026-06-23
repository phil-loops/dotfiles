import { createSignal } from "solid-js";

// Shared toggle for the home-screen "drop old forests" mode. Flipped from the command
// palette (Cmd-K), consumed by Home to swap each forest row's trailing control for a
// drop button. Module-level so the palette and Home share one source of truth; Home
// resets it on unmount so navigating away always leaves delete mode.
export const [deleteMode, setDeleteMode] = createSignal(false);
