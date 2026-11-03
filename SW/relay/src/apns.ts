import { base64, hash, metric, unbase64, utf8 } from "./security.js";

export interface WakeSecrets {
  APNS_TEAM_ID?: string;
  APNS_KEY_ID?: string;
  APNS_PRIVATE_KEY?: string;
  APNS_TOPIC?: string;
}
export interface WakeRegistration { token: string; environment: "sandbox" | "production" }
function url64(bytes: Uint8Array): string { return base64(bytes).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, ""); }
export interface CachedToken { credentialHash: string; issued: number; token: string }
interface TokenStore { get(): Promise<CachedToken | undefined>; put(value: CachedToken): Promise<void> }
let cached: CachedToken | undefined;
let pending: Promise<CachedToken> | undefined;
let pendingHash: string | undefined;

async function providerToken(team: string, kid: string, pem: string, store?: TokenStore): Promise<string> {
  const credentialHash = await hash(JSON.stringify([team, kid, pem]));
  const now = Date.now();
  const existing = store ? await store.get() : cached;
  if (existing?.credentialHash === credentialHash && now >= existing.issued && now - existing.issued < 50 * 60_000) return existing.token;
  if (pending && pendingHash === credentialHash) return (await pending).token;
  pendingHash = credentialHash;
  const mint = (async (): Promise<CachedToken> => {
    const der = unbase64(pem.replace(/-----[^-]+-----/g, "").replace(/\s/g, ""));
    const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
    const header = url64(utf8.encode(JSON.stringify({ alg: "ES256", kid })));
    const claims = url64(utf8.encode(JSON.stringify({ iss: team, iat: Math.floor(now / 1000) })));
    const unsigned = `${header}.${claims}`;
    const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, utf8.encode(unsigned)));
    const result = { credentialHash, issued: now, token: `${unsigned}.${url64(sig)}` };
    if (store) await store.put(result); else cached = result;
    return result;
  })();
  pending = mint;
  try { return (await mint).token; } finally { if (pending === mint) { pending = undefined; pendingHash = undefined; } }
}

// No frame, room ID, transcript or task content is accepted by this module.
export async function wake(env: WakeSecrets, registration: WakeRegistration, store?: TokenStore): Promise<void> {
  const { APNS_TEAM_ID: team, APNS_KEY_ID: kid, APNS_PRIVATE_KEY: pem, APNS_TOPIC: topic } = env;
  if (!team || !kid || !pem || !topic) { metric("wake_disabled"); return; }
  try {
    const jwt = await providerToken(team, kid, pem, store);
    const token = Array.from(unbase64(registration.token), b => b.toString(16).padStart(2, "0")).join("");
    const host = registration.environment === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
    const response = await fetch(`https://${host}/3/device/${token}`, {
      method: "POST", redirect: "manual", signal: AbortSignal.timeout(5000),
      headers: { authorization: `bearer ${jwt}`, "apns-topic": topic,
        "apns-push-type": "background", "apns-priority": "5", "apns-expiration": "0", "apns-collapse-id": "relay-wake" },
      body: '{"aps":{"content-available":1}}',
    });
    await response.body?.cancel();
    metric(response.ok ? "wake_sent" : "wake_failed");
  } catch { metric("wake_failed"); }
}
