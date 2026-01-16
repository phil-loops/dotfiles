import { currentBranch, listBackups } from "../lib.ts";

export function backupRestore() {
  const branch = currentBranch();
  const backups = listBackups(branch);

  if (backups.length === 0) {
    console.log(`No backups found for ${branch}`);
    return;
  }

  console.log(`Backups for ${branch}:\n`);
  backups.forEach((b, i) => {
    console.log(`  ${i + 1}. ${b}`);
  });

  console.log(`\nTo restore, run:`);
  console.log(`  git reset --hard <backup-name>`);
  console.log(`\nExample (restore latest):`);
  console.log(`  git reset --hard ${backups[backups.length - 1]}`);
}
