/**
 * Extract key changes (functions, classes, etc.) from a git diff
 */
export function extractKeyChanges(diff: string): string[] {
  const changes: string[] = [];
  const seen = new Set<string>();

  const patterns = [
    // TypeScript/JavaScript
    /^\+\s*(export\s+)?(async\s+)?function\s+(\w+)/,
    /^\+\s*(export\s+)?(const|let|var)\s+(\w+)\s*=\s*(async\s+)?\(/,
    /^\+\s*(export\s+)?class\s+(\w+)/,
    /^\+\s*(export\s+)?(const|let|var)\s+(\w+)\s*=\s*\{/,
    // SQL
    /^\+\s*CREATE\s+(TABLE|INDEX|UNIQUE INDEX)\s+(?:IF NOT EXISTS\s+)?"?(\w+)"?/i,
    /^\+\s*ALTER\s+TABLE\s+"?(\w+)"?/i,
    // Python
    /^\+\s*def\s+(\w+)/,
    /^\+\s*class\s+(\w+)/,
    // Go
    /^\+\s*func\s+(\w+|\(\w+\s+\*?\w+\)\s+\w+)/,
    // Rust
    /^\+\s*(pub\s+)?fn\s+(\w+)/,
    /^\+\s*(pub\s+)?struct\s+(\w+)/,
  ];

  for (const line of diff.split("\n")) {
    for (const pattern of patterns) {
      const match = line.match(pattern);
      if (match) {
        // Get the most meaningful capture group
        const name = match[match.length - 1] || match[match.length - 2];
        if (name && !seen.has(name)) {
          seen.add(name);
          // Clean up the line for display
          const cleaned = line.slice(1).trim().slice(0, 60);
          changes.push(cleaned + (line.length > 61 ? "..." : ""));
        }
        break;
      }
    }
  }

  return changes;
}

/**
 * Extract just the names of key changes (for compact display)
 */
export function extractKeyChangeNames(diff: string): string[] {
  const names: string[] = [];
  const seen = new Set<string>();

  const patterns: [RegExp, number][] = [
    // TypeScript/JavaScript function declarations
    [/^\+\s*(export\s+)?(async\s+)?function\s+(\w+)/, 3],
    // Arrow functions assigned to variables
    [/^\+\s*(export\s+)?(const|let|var)\s+(\w+)\s*=\s*(async\s+)?\(/, 3],
    // Classes
    [/^\+\s*(export\s+)?class\s+(\w+)/, 2],
    // Object literals (schemas, configs)
    [/^\+\s*(export\s+)?(const|let|var)\s+(\w+)\s*=\s*\{/, 3],
    // SQL
    [/^\+\s*CREATE\s+(TABLE|INDEX|UNIQUE INDEX)\s+(?:IF NOT EXISTS\s+)?"?(\w+)"?/i, 2],
    [/^\+\s*ALTER\s+TABLE\s+"?(\w+)"?/i, 1],
    // Python
    [/^\+\s*def\s+(\w+)/, 1],
    [/^\+\s*class\s+(\w+)/, 1],
    // Go
    [/^\+\s*func\s+(\w+)/, 1],
    // Rust
    [/^\+\s*(pub\s+)?fn\s+(\w+)/, 2],
    [/^\+\s*(pub\s+)?struct\s+(\w+)/, 2],
  ];

  for (const line of diff.split("\n")) {
    for (const [pattern, groupIndex] of patterns) {
      const match = line.match(pattern);
      if (match && match[groupIndex]) {
        const name = match[groupIndex];
        if (!seen.has(name)) {
          seen.add(name);
          // Format with () for functions, nothing for others
          const isFunction = /function|async|def|func|fn/.test(line) ||
                            /=\s*(async\s+)?\(/.test(line);
          names.push(isFunction ? `${name}()` : name);
        }
        break;
      }
    }
  }

  return names;
}
