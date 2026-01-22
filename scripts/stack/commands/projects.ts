import type { Command } from "../types.ts";
import {
  currentBranch,
  getChildren,
  getDescendants,
  git,
  loadStack,
} from "../lib.ts";

export const command: Command = {
  category: "nav",
  name: "projects",
  help: "Show top-level projects (direct children of main)",
  args: "[number|name] [subcommand]",
  run(args: string[]) {
    const stack = loadStack();
    const branch = currentBranch();

    // Get direct children of main (the "projects")
    const projects = getChildren(stack, "main");

    if (projects.length === 0) {
      console.log("No projects tracked off main.");
      console.log("Use: stack add main");
      return;
    }

    // Figure out which project we're currently in (if any)
    let currentProject: string | null = null;
    if (projects.includes(branch)) {
      // We're directly on a project branch
      currentProject = branch;
    } else if (stack[branch]) {
      // We're in a tracked branch - walk up to find which project
      let walk = branch;
      while (stack[walk] && stack[walk] !== "main") {
        walk = stack[walk];
      }
      if (stack[walk] === "main") {
        currentProject = walk;
      }
    }

    // If given an argument, switch to that project or run a subcommand
    if (args.length > 0) {
      const arg = args[0];
      let target: string | null = null;

      // Try as number first
      const num = parseInt(arg, 10);
      if (!isNaN(num) && num >= 1 && num <= projects.length) {
        target = projects[num - 1];
      } else {
        // Try as name (exact or partial match)
        target = projects.find((p) => p === arg) || projects.find((p) => p.includes(arg)) || null;
      }

      if (!target) {
        console.log(`Project not found: ${arg}`);
        console.log(`Available: ${projects.join(", ")}`);
        return;
      }

      // Check for subcommand
      const subcommand = args[1];
      if (subcommand === "review") {
        // Run review with --nvim --all on the target project
        import("./review.ts").then((mod) => {
          mod.command.run(["--nvim", "--all", "--from", target]);
        });
        return;
      }

      // No subcommand - just switch to the project
      git(`checkout ${target}`);
      console.log(`Switched to ${target}`);
      return;
    }

    // Show the project list
    console.log("Projects:");
    projects.forEach((project, i) => {
      const num = `${i + 1}.`.padEnd(3);
      const marker = project === currentProject ? " <-- you" : "";
      const depth = getDescendants(stack, project).length;
      const depthStr = depth > 0 ? ` (${depth} branches)` : "";
      console.log(`  ${num} ${project}${depthStr}${marker}`);
    });

    console.log("");
    console.log("Use: stack projects <number|name>");
  },
};
