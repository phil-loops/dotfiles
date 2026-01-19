export interface Command {
  name: string;
  help: string;
  args?: string;
  run(args: string[]): void;
}
