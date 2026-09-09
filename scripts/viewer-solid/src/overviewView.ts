import { createSignal } from "solid-js";

// Which face the forest overview shows — the spatial map, the merge-story, or the stories
// editor (one plain-English line per branch, edited in place). Module scope so any
// entry point (the ⌘K palette's "merge story" command, the in-page toggle) can flip it, and so it
// stays a sticky preference as you move between forests.
export type OverviewView = "map" | "story" | "stories";

export const [overviewView, setOverviewView] = createSignal<OverviewView>("map");
