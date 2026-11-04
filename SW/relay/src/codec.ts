import type { RelayFrame } from "./protocol/generated.js";
import { parseControl } from "./control.js";
import { record, requireThat } from "./security.js";

// The generated Ajv codec compiles validators dynamically; Workers forbids eval.
// This flat transport adapter uses generated types, closes every variant, and
// is checked against the generated codec/shared vectors in codec.test.ts.
export function decodeFrame(raw: string): RelayFrame {
  const frame = parseControl(raw) as Record<string, unknown>;
  const common = ["kind", "account_id", "room_id", "sender_device_id"];
  for (const name of common.slice(1)) {
    const value = frame[name];
    requireThat(typeof value === "string" && [...value].length >= 1 && [...value].length <= 128);
  }
  function bytes(value: unknown): void {
    requireThat(typeof value === "string" && value.length >= 4 && value.length <= 1_048_576
      && /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)
      && !/[^A-Za-z0-9+/=]/.test(value));
  }
  switch (frame.kind) {
    case "ciphertext": record(frame, [...common, "ciphertext"]); bytes(frame.ciphertext); break;
    case "presence": record(frame, [...common, "state"]); requireThat(frame.state === "online" || frame.state === "offline"); break;
    case "wake_registration":
      record(frame, [...common, "apns_wake_token", "environment"]); bytes(frame.apns_wake_token);
      requireThat(frame.environment === "sandbox" || frame.environment === "production"); break;
    default: requireThat(false);
  }
  return frame as unknown as RelayFrame;
}
export function encodeFrame(frame: RelayFrame): string { return JSON.stringify(frame); }
