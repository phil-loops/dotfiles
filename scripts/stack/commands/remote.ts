import { existsSync, readFileSync, writeFileSync } from "fs";
import { join } from "path";
import { getForkRemote, loadConfig } from "../lib.ts";

const LOCAL_CONFIG = join(process.cwd(), ".stackrc");

export function remote(newRemote?: string) {
  if (!newRemote) {
    // Show current remote
    const current = getForkRemote();
    const config = loadConfig();
    const source = config.remote ? (existsSync(LOCAL_CONFIG) ? ".stackrc" : "~/.stackrc") : "auto-detected";
    console.log(`Current remote: ${current} (${source})`);
    return;
  }

  // Set new remote
  let config: Record<string, string> = {};
  if (existsSync(LOCAL_CONFIG)) {
    try {
      config = JSON.parse(readFileSync(LOCAL_CONFIG, "utf-8"));
    } catch {
      // ignore
    }
  }

  config.remote = newRemote;
  writeFileSync(LOCAL_CONFIG, JSON.stringify(config, null, 2) + "\n");
  console.log(`Set remote to: ${newRemote}`);
  console.log(`Saved to: .stackrc`);
}
