import {
  addProjectBranch,
  getProjects,
  getProjectBranches,
  getProjectMemory,
  getStackTree,
  removeProject,
  removeProjectBranch,
  setProjectMemory,
  type StackTreeNode,
} from "../lib/stack-config.ts";

function usage(): never {
  console.error("Usage: stack project <subcommand>");
  console.error("  list                          List all projects.");
  console.error("  show <project>                Print the project's branch tree.");
  console.error("  create <project>              Create an empty project.");
  console.error("  delete <project>              Delete a project.");
  console.error("  add <project> <branch>        Add a branch to a project.");
  console.error("  remove <project> <branch>     Remove a branch from a project.");
  console.error("  set-memory <project> <path>   Attach a memory file to a project.");
  process.exit(1);
}

function requireProject(name: string | undefined): string {
  if (!name) usage();
  return name;
}

function printTree(nodes: StackTreeNode[], depth = 0): void {
  for (const node of nodes) {
    const prefix = depth === 0 ? "" : `${"  ".repeat(depth - 1)}└─ `;
    console.log(`${prefix}${node.name}`);
    if (node.children.length > 0) printTree(node.children, depth + 1);
  }
}

/**
 * Build a forest from a set of project branches. Branches whose parent is not
 * itself in the set become forest roots; the rendered "parent" is whatever
 * stack-branch config records (typically `main` or another tracked branch).
 */
function buildProjectForest(branches: string[]): StackTreeNode[] {
  const set = new Set(branches);
  const full = getStackTree();
  const byName = new Map<string, StackTreeNode>();
  // Flatten the existing tree into a lookup so we can rebuild a filtered forest.
  const stack = [...full];
  while (stack.length > 0) {
    const node = stack.shift()!;
    byName.set(node.name, { name: node.name, parent: node.parent, children: [] });
    stack.push(...node.children);
  }
  const filtered = new Map<string, StackTreeNode>();
  for (const name of branches) {
    const node = byName.get(name);
    if (node) filtered.set(name, { ...node, children: [] });
  }
  // Branches not tracked via stack-branch still show up as standalone roots so
  // the project view is never silently missing entries.
  for (const name of branches) {
    if (!filtered.has(name)) {
      filtered.set(name, { name, parent: "main", children: [] });
    }
  }
  const roots: StackTreeNode[] = [];
  for (const node of filtered.values()) {
    const parent = filtered.get(node.parent);
    if (parent && set.has(node.parent)) {
      parent.children.push(node);
    } else {
      roots.push(node);
    }
  }
  return roots;
}

export { buildProjectForest };

function listProjects(): void {
  const projects = getProjects();
  if (projects.length === 0) {
    console.log("No projects defined.");
    console.log("Create one with: stack project create <name>");
    return;
  }
  for (const name of projects) {
    const branches = getProjectBranches(name);
    const memory = getProjectMemory(name);
    const mem = memory ? ` (memory: ${memory})` : "";
    console.log(`${name} — ${branches.length} branch${branches.length === 1 ? "" : "es"}${mem}`);
  }
}

function showProject(project: string): void {
  const branches = getProjectBranches(project);
  if (branches.length === 0) {
    console.log(`Project "${project}" has no branches.`);
    return;
  }
  const memory = getProjectMemory(project);
  console.log(`Project: ${project}`);
  if (memory) console.log(`Memory:  ${memory}`);
  console.log(`Branches: ${branches.length}`);
  console.log();
  printTree(buildProjectForest(branches));
}

function createProject(project: string): void {
  const existing = getProjects();
  if (existing.includes(project)) {
    console.log(`Project "${project}" already exists.`);
    return;
  }
  // Git doesn't materialize a section until a key is set, so creation is a
  // pure metadata concept here. Print guidance instead of writing an empty key.
  console.log(`Project "${project}" registered. Add branches with:`);
  console.log(`  stack project add ${project} <branch>`);
}

function deleteProject(project: string): void {
  removeProject(project);
  console.log(`Deleted project "${project}".`);
}

function addBranch(project: string, branch: string): void {
  addProjectBranch(project, branch);
  console.log(`Added "${branch}" to project "${project}".`);
}

function removeBranch(project: string, branch: string): void {
  removeProjectBranch(project, branch);
  console.log(`Removed "${branch}" from project "${project}".`);
}

function setMemory(project: string, path: string): void {
  setProjectMemory(project, path);
  console.log(`Memory file for "${project}" set to ${path}.`);
}

export function project(args: string[]): void {
  const sub = args[0];
  switch (sub) {
    case "list":
      listProjects();
      return;
    case "show":
      showProject(requireProject(args[1]));
      return;
    case "create":
      createProject(requireProject(args[1]));
      return;
    case "delete":
      deleteProject(requireProject(args[1]));
      return;
    case "add":
      addBranch(requireProject(args[1]), requireProject(args[2]));
      return;
    case "remove":
      removeBranch(requireProject(args[1]), requireProject(args[2]));
      return;
    case "set-memory":
      setMemory(requireProject(args[1]), requireProject(args[2]));
      return;
    default:
      usage();
  }
}
