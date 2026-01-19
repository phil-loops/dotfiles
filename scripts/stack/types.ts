export const CATEGORIES = {
  nav: "Navigation",
  stack: "Stack Operations",
  git: "Git/GitHub",
  util: "Utilities",
} as const;

export type Category = keyof typeof CATEGORIES;

export interface Command {
  name: string;
  category: Category;
  help: string;
  args?: string;
  run(args: string[]): void;
}
