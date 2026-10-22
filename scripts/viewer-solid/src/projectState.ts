// focus · workbench · archive — where a project lives (POST /project-state; srv/review.py).
export type ProjectState = "focus" | "workbench" | "archive";

export const setProjectState = (repo: string, project: string, state: ProjectState) =>
  fetch("/project-state", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ repo: repo || "loops", project, state }),
  }).then((r) => r.json() as Promise<{ ok: boolean; error?: string }>);
