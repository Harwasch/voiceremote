// Relay transport credentials are separate from endpoint-held Noise keys.
export const utf8 = new TextEncoder();
export const LIMITS = {
  frameBytes: 1_052_672, controlBytes: 4096, devices: 8, invites: 8,
  challenges: 16, queueCount: 32, queueBytes: 2_105_344,
  queueTtlMs: 300_000, tokenTtlMs: 120_000, challengeTtlMs: 60_000,
  attemptsPerMinute: 60, wakeCooldownMs: 60_000,
} as const;

export class Refusal extends Error {
  constructor(readonly status: number, readonly code: string) { super(code); }
}
export function requireThat(value: unknown, status = 400, code = "invalid_request"): asserts value {
  if (!value) throw new Refusal(status, code);
}
export function json(value: unknown, status = 200): Response {
  return Response.json(value, { status, headers: { "cache-control": "no-store" } });
}
export function failure(error: unknown): Response {
  // Never reflect exception messages, validation errors or request bytes.
  return error instanceof Refusal ? json({ error: error.code }, error.status) : json({ error: "unavailable" }, 503);
}
export function id(value: unknown): asserts value is string {
  requireThat(typeof value === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(value));
}
export function sourceBucket(address: string): string {
  if (address === "local") return address;
  if (!address.includes(":")) {
    const parts = address.split(".");
    requireThat(parts.length === 4 && parts.every(p => /^\d{1,3}$/.test(p) && Number(p) <= 255));
    return parts.map(Number).join(".");
  }
  let normalized: string;
  try { normalized = new URL(`http://[${address}]/`).hostname.slice(1, -1); }
  catch { throw new Refusal(400, "invalid_source"); }
  const [left, right] = normalized.split("::");
  const a = left ? left.split(":") : [], b = right ? right.split(":") : [];
  const parts = right === undefined ? a : [...a, ...Array(8 - a.length - b.length).fill("0"), ...b];
  requireThat(parts.length === 8);
  return `${parts.slice(0, 4).map(p => p.padStart(4, "0")).join(":")}::/64`;
}
export function record(value: unknown, keys: string[]): asserts value is Record<string, unknown> {
  requireThat(value && typeof value === "object" && !Array.isArray(value));
  requireThat(Object.keys(value).length === keys.length && keys.every(k => Object.hasOwn(value, k)));
}
export function base64(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes));
}
export function unbase64(value: unknown, length?: number): Uint8Array<ArrayBuffer> {
  requireThat(typeof value === "string" && value.length <= 1024);
  let bytes: Uint8Array<ArrayBuffer>;
  try { bytes = Uint8Array.from(atob(value), c => c.charCodeAt(0)); }
  catch { throw new Refusal(400, "invalid_request"); }
  requireThat(base64(bytes) === value && (length === undefined || bytes.length === length));
  return bytes;
}
export function randomToken(): string { return base64(crypto.getRandomValues(new Uint8Array(32))); }
export async function hash(value: string): Promise<string> {
  return base64(new Uint8Array(await crypto.subtle.digest("SHA-256", utf8.encode(value))));
}
export async function publicKey(value: unknown): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", unbase64(value, 32), "Ed25519", false, ["verify"]);
}
export async function verify(key: string, signature: unknown, message: string): Promise<boolean> {
  try { return await crypto.subtle.verify("Ed25519", await publicKey(key), unbase64(signature, 64), utf8.encode(message)); }
  catch { return false; }
}
export async function secretMatches(header: string | null, secret?: string): Promise<boolean> {
  if (!secret || secret.length < 32 || !header || header.length > 512) return false;
  const a = utf8.encode(await hash(header));
  const b = utf8.encode(await hash(`Bearer ${secret}`));
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}
export async function body(request: Request): Promise<string> {
  requireThat(!request.headers.has("content-encoding"));
  const reader = request.body?.getReader();
  if (!reader) return "";
  let timer: ReturnType<typeof setTimeout>;
  const timeout = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => {
      reject(new Refusal(408, "body_timeout"));
      void reader.cancel().catch(() => {});
    }, 2000);
  });
  try { return await Promise.race([readBody(reader), timeout]); }
  finally { clearTimeout(timer!); }
}
async function readBody(reader: ReadableStreamDefaultReader<Uint8Array>): Promise<string> {
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > LIMITS.controlBytes) { await reader.cancel(); throw new Refusal(413, "too_large"); }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  try { return new TextDecoder("utf-8", { fatal: true }).decode(bytes); }
  catch { throw new Refusal(400, "invalid_request"); }
}
export type Metric = "accepted" | "rejected" | "joined" | "revoked" | "dropped" | "wake_disabled" | "wake_sent" | "wake_failed";
export function metric(event: Metric, count = 1, bytes = 0): void {
  console.log(JSON.stringify({ event, count, bytes }));
}
