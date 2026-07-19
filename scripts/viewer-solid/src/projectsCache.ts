import type { Project } from "./types";

// opportunistic load: the forests fan-out is cheap warm (~110ms) but a reaped server pays a cold
// python boot + git fan-out, and pages would render EMPTY until it lands. Paint the last-known
// forests from localStorage instantly, then revalidate — never blank on a cold open.
const PROJECTS_CACHE = "viewerProjectsCache";

export const cachedProjects = (): Project[] | undefined => {
  try {
    const s = localStorage.getItem(PROJECTS_CACHE);
    return s ? (JSON.parse(s) as Project[]) : undefined;
  } catch {
    return undefined;
  }
};

export const rememberProjects = (d: Project[] | undefined): void => {
  if (d && d.length) {
    try { localStorage.setItem(PROJECTS_CACHE, JSON.stringify(d)); } catch { /* quota/private mode — skip */ }
  }
};
