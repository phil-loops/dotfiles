import { execSync } from "child_process";
import { writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { getStackBranchesForWebview, getBranchData, detectChurn } from "./data.ts";
import { generateHtml } from "./html.ts";

export function webview(args: string[]) {
  const prefix = args[0];

  console.log("Gathering branch data (ignoring whitespace)...");
  if (prefix) console.log(`Filtering branches with prefix: ${prefix}`);

  const branches = getStackBranchesForWebview(prefix);
  if (branches.length === 0) {
    console.error("No branches found with stack parent config.");
    if (prefix) {
      console.error(`No branches found matching prefix: ${prefix}`);
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
