import { readFileSync } from "node:fs";
import { Ajv2020 } from "ajv/dist/2020.js";
import { describe, it, expect } from "vitest";
import { decode, encode, validate, type Records, type ToolCall, type InnerMessage } from "../src/protocol/generated.js";

interface Vector { name: string; schema: keyof Records; value: unknown; json?: string }
interface RawVector { name: string; schema: keyof Records; json: string }
const root = new URL("../../../", import.meta.url);
const vectors: { valid: Vector[]; invalid: Vector[]; raw_invalid: RawVector[] } = JSON.parse(
  readFileSync(new URL("SYS/protocol/vectors/golden.json", root), "utf8"),
);
const tools = JSON.parse(readFileSync(new URL("SYS/tools/tool-call.schema.json", root), "utf8"));
const protocol = JSON.parse(readFileSync(new URL("SYS/protocol/protocol.schema.json", root), "utf8"));
// Independent oracle: compile the ORIGINAL schemas, including cross-document refs.
const oracle = new Ajv2020({ strict: true, strictRequired: false });
oracle.addSchema(tools).addSchema(protocol);
function original(name: keyof Records) {
  const document = protocol.$defs[name] ? protocol : tools;
  const validator = oracle.getSchema(`${document.$id}#/$defs/${name}`);
  if (!validator) throw new Error(`Missing source definition ${name}`);
  return validator;
}

describe("shared protocol vectors", () => {
  for (const v of vectors.valid) {
    it(`round trips ${v.name}`, () => {
      expect(original(v.schema)(v.value)).toBe(true);
      const value = decode(v.schema, v.json ?? JSON.stringify(v.value));
      const output = encode(v.schema, value);
      expect(JSON.parse(output)).toEqual(v.value);
      expect(decode(v.schema, output)).toEqual(v.value);
    });
  }
  for (const v of vectors.invalid) {
    it(`rejects ${v.name}`, () => {
      expect(original(v.schema)(v.value)).toBe(false);
      expect(() => decode(v.schema, JSON.stringify(v.value))).toThrow();
    });
  }
  for (const v of vectors.raw_invalid) {
    it(`rejects raw ${v.name}`, () => {
      expect(() => decode(v.schema, v.json)).toThrow();
    });
  }
  it("validates constructed values on encode", () => {
    const v = vectors.valid.find(v => v.schema === "DictationText")!;
    const value = decode("DictationText", JSON.stringify(v.value));
    expect(() => encode("DictationText", { ...value, text: "SYNTHETIC\n" })).toThrow();
    expect(() => decode("InnerMessage", '{"kind":"unknown"}')).toThrow();
    expect(() => decode("RelayFrame", "not JSON")).toThrow();
    expect(() => encode("DictationText", { ...value, text: "SYNTHETIC\ud800" })).toThrow();
  });
  it("rejects non-UTF-8 source strings before decoding escapes", () => {
    const v = vectors.valid.find(v => v.schema === "DictationText")!;
    const raw = JSON.stringify({ ...(v.value as object), text: "MARKER" });
    for (const malformed of ["\ud800", "\udc00", "\\ud800" + "\udc00", "\ud800" + "\\udc00"]) {
      expect(() => decode("DictationText", raw.replace("MARKER", malformed))).toThrow();
    }
  });
});

// Compiled with tsc: the public types preserve discriminators and deny authority.
function typeChecks(tool: ToolCall, message: InnerMessage) {
  // @ts-expect-error The model cannot supply authority through a tool call.
  tool.authenticated_actor = "forbidden";
  if (message.kind === "dictation_text") {
    const text: string = message.text;
    // @ts-expect-error No Send flag exists on dictation.
    message.send = true;
    return text;
  }
}
void typeChecks;
void validate;
