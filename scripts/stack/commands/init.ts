import type { Command } from "../types.ts";
import { currentBranch, getBranchesByPrefix, gitTry, loadConvention, saveConvention } from "../lib.ts";

export const command: Command = {
  name: "init",
  help: "Setup convention mode (e.g., stack init goals-)",
  args: "[prefix]",
  run(args) {
    const prefix = args[0];
    const convention = loadConvention();

    if (!prefix) {
      // Show current convention or try to detect from current branch
      if (convention) {
        const branches = getBranchesByPrefix(convention.prefix);
        console.log(`Convention mode: ${convention.prefix}* (root: ${convention.root})`);
        console.log(`Matching branches: ${branches.length}`);
        return;
      }

      // Try to detect prefix from current branch
      const branch = currentBranch();
      const match = branch.match(/^(.+-)(\d+(?:\.\d+)?)$/);
      if (match) {
        console.log(`Detected prefix: ${match[1]}`);
        console.log(`Run: stack init ${match[1]}`);
      } else {
        console.log("Usage: stack init <prefix>");
        console.log("Example: stack init goals-");
      }
      return;
    }

    // Ensure prefix ends with a separator
    const normalizedPrefix = prefix.endsWith("-") ? prefix : prefix + "-";

    // Check for existing branches
    const branches = getBranchesByPrefix(normalizedPrefix);

    // Detect root (default to main)
    let root = "main";
    if (!gitTry("rev-parse --verify main")) {
      if (gitTry("rev-parse --verify master")) {
        root = "master";
      }
    }

    saveConvention({ prefix: normalizedPrefix, root });

    console.log(`Initialized convention stack:`);
    console.log(`  Prefix: ${normalizedPrefix}`);
    console.log(`  Root: ${root}`);
    if (branches.length > 0) {
      console.log(`  Found ${branches.length} matching branches: ${branches.join(", ")}`);
    } else {
      console.log(`  No matching branches yet. Create one with: git checkout -b ${normalizedPrefix}1`);
    }
  },
};
