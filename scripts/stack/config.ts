import { existsSync, readFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import { git } from "./git.ts";

const LOCAL_CONFIG_FILE = join(process.cwd(), ".stackrc");
const GLOBAL_CONFIG_FILE = join(homedir(), ".stackrc");

export type Config = {
  remote?: string; // e.g. "phil-loops" or "origin"
  repo?: string; // e.g. "phil-loops/loops" for gh commands
  reviewEditor?: "nvim" | "terminal"; // default editor for stack review
};

/**
 * Load config from .stackrc (local takes precedence over global)
 * Format: JSON { "remote": "phil-loops", "repo": "phil-loops/loops" }
 */
export function loadConfig(): Config {
  let config: Config = {};

  // Load global first
  if (existsSync(GLOBAL_CONFIG_FILE)) {
    try {
      config = { ...config, ...JSON.parse(readFileSync(GLOBAL_CONFIG_FILE, "utf-8")) };
    } catch {
      // ignore invalid config
    }
  }

  // Local overrides global
  if (existsSync(LOCAL_CONFIG_FILE)) {
    try {
      config = { ...config, ...JSON.parse(readFileSync(LOCAL_CONFIG_FILE, "utf-8")) };
    } catch {
      // ignore invalid config
    }
  }

  return config;
}

export function getForkRemote(): string {
  const config = loadConfig();

  // Config takes precedence
  if (config.remote) return config.remote;

  // Fallback to auto-detection
  try {
    const remotes = git("remote").split("\n");
    if (remotes.includes("phil-loops")) return "phil-loops";
    return "origin";
  } catch {
    return "origin";
  }
}

export function getGitHubRepo(): string | null {
  const config = loadConfig();

  // Config takes precedence
  if (config.repo) return config.repo;

  // Fallback to auto-detection from remote URL
  try {
    const remote = getForkRemote();
    const url = git(`remote get-url ${remote}`);
    const match = url.match(/github\.com[:/]([^/]+\/[^/.]+)/);
    return match ? match[1].replace(/\.git$/, "") : null;
  } catch {
    return null;
  }
}
