import { parseArgs as nodeParseArgs } from "node:util";

type ArgType = "string" | "boolean";

type OptionConfig = {
  type: ArgType;
  short?: string;
  default?: string | boolean;
};

type Options = Record<string, OptionConfig>;

type ParsedArgs<T extends Options> = {
  values: {
    [K in keyof T]: T[K]["type"] extends "boolean" ? boolean : string | undefined;
  };
  positionals: string[];
};

/**
 * Parse command line arguments using node:util parseArgs
 *
 * @example
 * const { values, positionals } = parseArgs(args, {
 *   all: { type: "boolean", short: "a" },
 *   base: { type: "string", short: "b" },
 * });
 * // stack update --all -> values.all = true
 * // stack peel foo --base main -> positionals = ["foo"], values.base = "main"
 */
export function parseArgs<T extends Options>(
  args: string[],
  options: T
): ParsedArgs<T> {
  const config: {
    args: string[];
    options: Record<string, { type: ArgType; short?: string; default?: string | boolean }>;
    allowPositionals: boolean;
    strict: boolean;
  } = {
    args,
    options: {},
    allowPositionals: true,
    strict: false,
  };

  for (const [name, opt] of Object.entries(options)) {
    config.options[name] = {
      type: opt.type,
      short: opt.short,
      default: opt.default,
    };
  }

  const result = nodeParseArgs(config);

  const values: Record<string, string | boolean | undefined> = { ...result.values };
  for (const [name, opt] of Object.entries(options)) {
    if (values[name] === undefined && opt.default !== undefined) {
      values[name] = opt.default;
    }
  }

  return {
    values: values as ParsedArgs<T>["values"],
    positionals: result.positionals,
  };
}
