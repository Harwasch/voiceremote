import { requireThat } from "./security.js";

// Control requests are flat objects with strings, booleans and safe integers.
// Reject duplicate decoded keys and non-JSON whitespace before JSON.parse.
// Relay payloads continue to use the generated codec unchanged.
export function parseControl(raw: string): unknown {
  const token = /"(?:[^"\\\u0000-\u001f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"|true|false|-?(?:0|[1-9][0-9]*)|[{}:,]|[ \t\r\n]+/y;
  let offset = 0;
  const tokens: string[] = [];
  while (offset < raw.length) {
    token.lastIndex = offset;
    const match = token.exec(raw);
    requireThat(match);
    offset = token.lastIndex;
    if (!/^[ \t\r\n]+$/.test(match[0])) tokens.push(match[0]);
  }
  let i = 0;
  requireThat(tokens[i++] === "{");
  const keys = new Set<string>();
  const result: Record<string, unknown> = Object.create(null);
  function string(value: string | undefined): string {
    requireThat(typeof value === "string" && value.startsWith('"'));
    const decoded = JSON.parse(value) as string;
    for (const scalar of decoded) {
      const n = scalar.codePointAt(0)!;
      requireThat(n < 0xd800 || n > 0xdfff);
    }
    return decoded;
  }
  if (tokens[i] !== "}") while (true) {
    const key = string(tokens[i++]);
    requireThat(!keys.has(key)); keys.add(key);
    requireThat(tokens[i++] === ":");
    const value = tokens[i++];
    requireThat(value !== undefined);
    if (/^-?\d+$/.test(value)) { requireThat(Number.isSafeInteger(Number(value))); result[key] = Number(value); }
    else result[key] = value === "true" ? true : value === "false" ? false : string(value);
    if (tokens[i] !== ",") break;
    i++;
    requireThat(tokens[i] !== "}");
  }
  requireThat(tokens[i++] === "}" && i === tokens.length);
  return result;
}
