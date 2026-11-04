import { afterEach, describe, expect, it, vi } from "vitest";
import { wake, type WakeSecrets } from "../src/apns.js";

afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks(); });
describe("APNs optional secrets", () => {
  it("reuses a provider JWT across concurrent wakes and refreshes after 50 minutes", async () => {
    vi.spyOn(console, "log").mockImplementation(() => {});
    const key = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
    const env = { APNS_TEAM_ID: "SYNTHETIC-cache", APNS_KEY_ID: "SYNTHETIC-cache", APNS_TOPIC: "invalid.app",
      APNS_PRIVATE_KEY: `-----BEGIN PRIVATE KEY-----\n${Buffer.from(await crypto.subtle.exportKey("pkcs8", key.privateKey)).toString("base64")}\n-----END PRIVATE KEY-----` };
    const fetch = vi.fn().mockResolvedValue({ ok: true }); vi.stubGlobal("fetch", fetch);
    const clock = vi.spyOn(Date, "now").mockReturnValue(1_800_000_000_000);
    const registration = { token: "AQID", environment: "sandbox" as const };
    await Promise.all([wake(env, registration), wake(env, registration)]);
    const first = fetch.mock.calls[0][1].headers.authorization;
    expect(fetch.mock.calls[1][1].headers.authorization).toBe(first);
    clock.mockReturnValue(1_800_000_000_000 + 49 * 60_000); await wake(env, registration);
    expect(fetch.mock.calls[2][1].headers.authorization).toBe(first);
    clock.mockReturnValue(1_800_000_000_000 + 50 * 60_000); await wake(env, registration);
    expect(fetch.mock.calls[3][1].headers.authorization).not.toBe(first);
  });
  it.each([{}, { APNS_TEAM_ID: "SYNTHETIC" }, { APNS_TEAM_ID: "SYNTHETIC", APNS_KEY_ID: "SYNTHETIC", APNS_TOPIC: "invalid.app" }])(
    "disables wake cleanly without a complete secret set: %j", async (env: WakeSecrets) => {
      const fetch = vi.fn(); vi.stubGlobal("fetch", fetch);
      const log = vi.spyOn(console, "log").mockImplementation(() => {});
      await expect(wake(env, { token: "AQID", environment: "production" })).resolves.toBeUndefined();
      expect(fetch).not.toHaveBeenCalled();
      expect(log).toHaveBeenCalledExactlyOnceWith('{"event":"wake_disabled","count":1,"bytes":0}');
    },
  );
  it("contains key import failures without logging credentials or exception bytes", async () => {
    const fetch = vi.fn(); vi.stubGlobal("fetch", fetch);
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    await wake({ APNS_TEAM_ID: "SYNTHETIC", APNS_KEY_ID: "SYNTHETIC", APNS_TOPIC: "invalid.app",
      APNS_PRIVATE_KEY: "SYNTHETIC-INVALID-KEY-MARKER" }, { token: "AQID", environment: "production" });
    expect(fetch).not.toHaveBeenCalled();
    expect(log).toHaveBeenCalledExactlyOnceWith('{"event":"wake_failed","count":1,"bytes":0}');
  });
});
