import { createSignal } from "solid-js";

// Which face the forest overview shows — the spatial map or the merge-story. Module scope so any
// entry point (the ⌘K palette's "merge story" command, the in-page toggle) can flip it, and so it
// stays a sticky preference as you move between forests.
export type OverviewView = "map" | "story";

export const [overviewView, setOverviewView] = createSignal<OverviewView>("map");
