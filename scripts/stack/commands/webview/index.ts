import { execSync } from "child_process";
import { writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { getProjectBranches } from "../../lib/stack-config.ts";
import { getStackBranchesForWebview, getBranchData, detectChurn } from "./data.ts";
import { generateHtml } from "./html.ts";

export function webview(args: string[]) {
  let prefix: string | undefined;
  let project: string | undefined;
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--project") {
      project = args[++i];
    } else if (arg.startsWith("--project=")) {
      project = arg.slice("--project=".length);
    } else if (!arg.startsWith("-")) {
      prefix = arg;
    }
  }

  if (project && prefix) {
    console.error("--project and prefix are mutually exclusive");
    process.exit(1);
  }

  console.log("Gathering branch data (ignoring whitespace)...");
  if (prefix) console.log(`Filtering branches with prefix: ${prefix}`);
  if (project) console.log(`Filtering branches in project: ${project}`);

  let branches: ReturnType<typeof getStackBranchesForWebview>;
  if (project) {
    const names = getProjectBranches(project);
    if (names.length === 0) {
      console.error(`Project "${project}" has no branches.`);
      console.error(`Add branches with: loops stack project add ${project} <branch>`);
      process.exit(1);
    }
    branches = getStackBranchesForWebview({ names });
  } else {
    branches = getStackBranchesForWebview({ prefix });
  }

  if (branches.length === 0) {
    console.error("No branches found with stack parent config.");
    if (prefix) {
      console.error(`No branches found matching prefix: ${prefix}`);
    }
    if (project) {
      console.error(`No project "${project}" branches have stack parent config set.`);
    }
    console.error("Make sure branches have parents set via: git config stack-branch.<branch>.parent <parent>");
    process.exit(1);
  }

  console.log(`Found ${branches.length} branches in stack`);

  const branchData = branches.map((b) => {
    process.stdout.write(`  ${b.name}...`);
    const data = getBranchData(b.name, b.parent);
    console.log(` ${data.filesChanged} files, +${data.insertions}/-${data.deletions}`);
    return data;
  });

  console.log("Detecting churn...");
  const churnData = detectChurn(branchData);
  if (churnData.length > 0) {
    console.log(`  Found ${churnData.length} churn hunks`);
  } else {
    console.log("  No churn detected");
  }

  const html = generateHtml(branchData, churnData);
  const outPath = join(tmpdir(), "stack-view.html");
  writeFileSync(outPath, html);

  console.log(`\nOpening ${outPath}`);
  execSync(`open "${outPath}"`);
}
