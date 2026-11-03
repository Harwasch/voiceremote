import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { decodeFrame } from "../src/codec.js";
import { parseControl } from "../src/control.js";
import { decode, schemaDocument } from "../src/protocol/generated.js";
import { LIMITS, sourceBucket } from "../src/security.js";

describe("Worker transport adapter agrees with generated contract", () => {
  it("the frame cap covers the schema's largest ciphertext and maximally escaped IDs", () => {
    const id = "\u0000".repeat(128);
    const frame = { kind: "ciphertext", account_id: id, room_id: id, sender_device_id: id, ciphertext: "A".repeat(1_048_576) };
    const raw = JSON.stringify(frame);
    expect(frame.ciphertext.length).toBe(schemaDocument.$defs.Base64.maxLength);
    expect([...id].length).toBe(schemaDocument.$defs.Identifier.maxLength);
    expect(new TextEncoder().encode(raw).length).toBeLessThanOrEqual(LIMITS.frameBytes);
    expect(decodeFrame(raw)).toEqual(frame);
  });
  it("normalizes IPv6 spelling and groups exactly the first 64 bits", () => {
    expect(sourceBucket("2001:db8:1:2::1")).toBe(sourceBucket("2001:0db8:0001:0002:abcd:ffff:0000:9999"));
    expect(sourceBucket("2001:db8:1:3::1")).not.toBe(sourceBucket("2001:db8:1:2::1"));
    expect(sourceBucket("192.0.2.1")).not.toBe(sourceBucket("192.0.2.2"));
  });
  const vectors = JSON.parse(readFileSync(new URL("../../../SYS/protocol/vectors/golden.json", import.meta.url), "utf8"));
  for (const group of ["valid", "invalid", "raw_invalid"]) for (const v of vectors[group]) {
    if (!["RelayFrame", "RelayCiphertext", "RelayPresence", "RelayWakeRegistration"].includes(v.schema)) continue;
    it(`${group}: ${v.name}`, () => {
      const raw = v.json ?? JSON.stringify(v.value);
      if (group === "valid") expect(decodeFrame(raw)).toEqual(decode("RelayFrame", raw));
      else expect(() => decodeFrame(raw)).toThrow();
    });
  }
  it("rejects duplicate escaped keys, nested data, bad scalars and unknown fields", () => {
    for (const raw of ['{"a":true,"\\u0061":false}', '{"a":{"b":true}}', '{"a":"\\ud800"}',
      '{"a":1.0}', '{"a":1e0}', '{"a":9007199254740992}', '{"a":null}', '{"a":true,}', '\uFEFF{}', '{}\u00a0', '{}{}']) {
      expect(() => parseControl(raw)).toThrow();
    }
    expect(parseControl('{"a":"\\ud83d\\ude80","b":false}')).toEqual({ a: "🚀", b: false });
  });
  it("checks every variant and field against the generated validator", () => {
    const samples = [
      { kind: "ciphertext", ciphertext: "AQID" },
      { kind: "presence", state: "online" },
      { kind: "wake_registration", apns_wake_token: "AQID", environment: "sandbox" },
    ].map(f => ({ account_id: "a", room_id: "r", sender_device_id: "d", ...f }));
    for (const sample of samples) {
      const mutations: unknown[] = [sample, { ...sample, unexpected: true }];
      for (const key of Object.keys(sample)) {
        const missing = { ...sample } as Record<string, unknown>; delete missing[key]; mutations.push(missing);
        for (const value of [null, false, 0, [], {}, "", "unknown", "a\n", "😀".repeat(129)]) mutations.push({ ...sample, [key]: value });
      }
      for (const value of mutations) {
        const raw = JSON.stringify(value);
        let accepted = true;
        try { decode("RelayFrame", raw); } catch { accepted = false; }
        if (accepted) expect(decodeFrame(raw)).toEqual(value);
        else expect(() => decodeFrame(raw)).toThrow();
      }
    }
  });
});
