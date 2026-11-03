import { mutationPlugin } from "./mutations.js";
import { build } from "esbuild";
import { convertV4MiniflareOptions, Log, LogLevel, Miniflare, Response as MFResponse, type Request as MFRequest, type WebSocket as MFSocket } from "miniflare";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { hash } from "../src/security.js";

const key = "SYNTHETIC-provider-marker-not-a-credential";
const prompt = "SYNTHETIC-body-marker";
const provisionSecret = "SYNTHETIC-test-provisioning-only-00000000";
const base = {
  RELAY_PROVISION_SECRET: provisionSecret,
  ANTHROPIC_API_KEY: key, ELEVENLABS_API_KEY: key, ASSEMBLYAI_API_KEY: key,
  CLOUD_DEVICE_DAILY_MICROUSD: "10000", CLOUD_GLOBAL_DAILY_MICROUSD: "100000",
  CLOUD_DEVICE_CONCURRENT: "2", CLOUD_GLOBAL_CONCURRENT: "4",
  CLOUD_SPEECH_RESERVATION_MICROUSD: "100", CLOUD_ANTHROPIC_RESERVATION_MICROUSD: "100",
  CLOUD_MAX_BODY_BYTES: "65536", CLOUD_MAX_FRAME_BYTES: "8192", CLOUD_MAX_STREAM_BYTES: "16384",
  CLOUD_MAX_DURATION_MS: "10000", CLOUD_MAX_OUTPUT_TOKENS: "2048",
  CLOUD_ANTHROPIC_MODEL: "synthetic-model", CLOUD_ANTHROPIC_VERSION: "2026-10-21",
};
const query = {
  elevenlabs: "?model_id=scribe_v2_realtime&audio_format=pcm_16000&commit_strategy=manual&keyterms=SYNTHETIC-vocabulary",
  assemblyai: "?speech_model=universal-3-5-pro&sample_rate=16000&encoding=pcm_s16le&include_partial_turns=true&keyterms_prompt=%5B%22SYNTHETIC-vocabulary%22%5D",
};
function canonicalQuery(search: string): string {
  const encode = (value: string) => encodeURIComponent(value).replace(/[!'()~]/g, c => `%${c.charCodeAt(0).toString(16).toUpperCase()}`).replace(/%20/g, "+");
  const pairs = [...new URLSearchParams(search)].map(([name, value]) => `${encode(name)}=${encode(value)}`);
  return pairs.length ? `?${pairs.join("&")}` : "";
}
const payload = () => JSON.stringify({ model: "synthetic-model", max_tokens: 2048, system: prompt,
  messages: [{ role: "user", content: prompt }], tools: [{ name: "select_target", description: "Synthetic", input_schema: { type: "object" } }], tool_choice: { type: "auto" } });
const b64 = (value: ArrayBuffer | Uint8Array) => Buffer.from(value instanceof Uint8Array ? value : new Uint8Array(value)).toString("base64");
interface Device { device_id: string; public_key: string; privateKey: CryptoKey }
async function device(device_id: string): Promise<Device> {
  const keys = await crypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]) as CryptoKeyPair;
  return { device_id, public_key: b64(await crypto.subtle.exportKey("raw", keys.publicKey)), privateKey: keys.privateKey };
}
const sign = async (d: Device, text: string) => b64(await crypto.subtle.sign("Ed25519", d.privateKey, new TextEncoder().encode(text)));
let bundle: string;
const runtimes: Miniflare[] = [];
beforeAll(async () => {
  bundle = (await build({ entryPoints: [new URL("runtime-fixture.ts", import.meta.url).pathname], bundle: true,
    format: "esm", target: "es2022", platform: "browser", external: ["cloudflare:workers"], write: false, plugins: [mutationPlugin()] })).outputFiles[0].text;
});
afterAll(async () => { for (const runtime of runtimes) await runtime.dispose(); });
async function runtime(overrides: Record<string, string | undefined> = {}) {
  const logs: string[] = [], calls: { url: string; headers: Record<string, string>; body: string }[] = [];
  const vendorSockets: MFSocket[] = [];
  let mode: "normal" | "error" | "redirect" | "secret" | "throw" | "slow" | "slow-body" | "long-body" = "normal";
  const mf = new Miniflare(convertV4MiniflareOptions({ name: "cloud-test", modules: true, script: bundle,
    compatibilityDate: "2026-07-01", durableObjects: {
      ROOMS: { className: "Room", useSQLite: true }, ADMISSION: { className: "Admission", useSQLite: true },
      WAKE: { className: "WakeProvider", useSQLite: true }, CLOUD_BUDGET: { className: "CloudBudget", useSQLite: true },
    }, bindings: Object.fromEntries(Object.entries({ ...base, ...overrides }).filter(([, value]) => value !== undefined)), log: new Log(LogLevel.ERROR),
    handleStructuredLogs(log) { logs.push(log.message); },
    async outboundService(request: MFRequest) {
      const text = await request.text(); calls.push({ url: request.url, headers: Object.fromEntries(request.headers), body: text });
      if (mode === "throw") throw new Error(key + prompt);
      if (mode === "error") return new MFResponse(key + prompt, { status: 401, headers: { "x-secret": key } });
      if (mode === "redirect") return new MFResponse(key, { status: 307, headers: { location: "https://disallowed.invalid/steal" } });
      if (mode === "slow") await new Promise(resolve => setTimeout(resolve, 500));
      if (new URL(request.url).hostname === "api.anthropic.com") {
        const data = mode === "secret" ? JSON.stringify({ secret: key }) : '{"role":"assistant","type":"message","content":[],"stop_reason":"end_turn"}';
        return new MFResponse(new ReadableStream({ start(controller) {
          controller.enqueue(new TextEncoder().encode(data.slice(0, 20)));
          if (mode === "slow-body" || mode === "long-body") setTimeout(() => { try { controller.enqueue(new TextEncoder().encode(data.slice(20))); controller.close(); } catch { /* cancelled by proxy */ } }, mode === "long-body" ? 2300 : 500);
          else { controller.enqueue(new TextEncoder().encode(data.slice(20))); controller.close(); }
        } }), { headers: { "x-secret": key, "set-cookie": "synthetic=ignored" } });
      }
      // Fake upgrade implemented by Miniflare's host-side WebSocketPair.
      const { WebSocketPair } = await import("miniflare");
      const pair = new WebSocketPair(), server = pair[1]; server.accept(); vendorSockets.push(server);
      server.addEventListener("message", event => { if (server.readyState === 1) server.send(event.data); });
      return new MFResponse(null, { status: 101, webSocket: pair[0], headers: { "x-secret": key } });
    },
  }));
  runtimes.push(mf); await mf.ready;
  return { mf, logs, calls, vendorSockets, mode(value: typeof mode) { mode = value; } };
}
type Runtime = Awaited<ReturnType<typeof runtime>>;
class Client {
  readonly account = crypto.randomUUID(); readonly room = Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString("hex");
  constructor(readonly r: Runtime) {}
  path(operation: string) { return `https://relay.test/v1/accounts/${this.account}/rooms/${this.room}/${operation}`; }
  post(operation: string, raw: string, headers: Record<string, string> = {}) {
    return this.r.mf.dispatchFetch(this.path(operation), { method: "POST", body: raw,
      headers: { "content-type": "application/json", "anthropic-version": base.CLOUD_ANTHROPIC_VERSION, ...headers } });
  }
  async create(d: Device) {
    const raw = JSON.stringify({ device_id: d.device_id, public_key: d.public_key });
    expect((await this.post("create", raw, { authorization: `Bearer ${provisionSecret}`, "x-relay-signature": await sign(d,
      JSON.stringify(["voiceremote-relay-create-v1", this.account, this.room, await hash(raw)])) })).status).toBe(201);
  }
  async challenge(d: Device, operation: string, raw = "") {
    if (["proxy/elevenlabs", "proxy/assemblyai"].includes(operation)) raw = canonicalQuery(raw);
    const text = JSON.stringify({ device_id: d.device_id, operation, body_sha256: await hash(raw) });
    return this.post("challenge", text, { "x-relay-signature": await sign(d,
      JSON.stringify(["voiceremote-relay-challenge-v1", this.account, this.room, await hash(text)])) });
  }
  async proof(d: Device, operation: string, raw = "") {
    const response = await this.challenge(d, operation, raw); expect(response.status).toBe(200);
    const challenge = await response.json() as { challenge: string; message: string };
    return { "x-relay-challenge": challenge.challenge, "x-relay-signature": await sign(d, challenge.message) };
  }
  async auth(d: Device, operation: string, raw = payload()) { return this.post(operation, raw, await this.proof(d, operation, raw)); }
  async join(admin: Device, phone: Device) {
    const token = b64(crypto.getRandomValues(new Uint8Array(32))), expires = Date.now() + 120_000;
    expect((await this.auth(admin, "invite", JSON.stringify({ token_sha256: await hash(token), expires_at: expires }))).status).toBe(201);
    const signature = await sign(phone, JSON.stringify(["voiceremote-relay-join-v1", this.account, this.room, phone.device_id, phone.public_key, token, expires]));
    expect((await this.post("join", JSON.stringify({ device_id: phone.device_id, public_key: phone.public_key, one_use_token: token, expires_at: expires, signature }))).status).toBe(201);
  }
  async open(d: Device, provider: keyof typeof query) {
    return this.r.mf.dispatchFetch(this.path(`proxy/${provider}`) + query[provider], {
      headers: { upgrade: "websocket", ...await this.proof(d, `proxy/${provider}`, query[provider]) },
    });
  }
  async inspect() {
    const ns = await this.r.mf.getDurableObjectNamespace("ROOMS");
    return (await ns.get(ns.idFromName(JSON.stringify([this.account, this.room]))).fetch("https://test/__test")).json();
  }
}
async function setup(overrides: Record<string, string | undefined> = {}) {
  const r = await runtime(overrides), c = new Client(r), admin = await device("desktop"), phone = await device("phone");
  await c.create(admin); await c.join(admin, phone); return { r, c, admin, phone };
}
async function until(check: () => boolean) {
  const end = Date.now() + 3000;
  while (!check()) { if (Date.now() > end) throw new Error("Synthetic socket timeout"); await new Promise(resolve => setTimeout(resolve, 10)); }
}
async function ledger(r: Runtime, operation?: string) {
  const ns = await r.mf.getDurableObjectNamespace("CLOUD_BUDGET");
  return ns.get(ns.idFromName("global")).fetch("https://test/__test", operation ? { method: "POST", body: operation } : {});
}
function socket(ws: MFSocket) {
  const received: (string | ArrayBuffer)[] = []; let closed = false, reason: string | undefined;
  ws.addEventListener("message", e => received.push(e.data instanceof Uint8Array ? e.data.slice().buffer : e.data)); ws.addEventListener("close", e => { closed = true; reason = e.reason; }); ws.accept();
  return { ws, received, get closed() { return closed; }, get reason() { return reason; } };
}

describe("cloud proxies with synthetic upstreams", () => {
  it("disables cloud without provisioning even for a paired member", async () => {
    const { r, c, phone } = await setup({ RELAY_PROVISION_SECRET: undefined });
    const headers = await c.proof(phone, "proxy/anthropic", payload());
    expect((await c.post("proxy/anthropic", payload(), headers)).status).toBe(503);
    for (const provider of ["elevenlabs", "assemblyai"] as const) {
      expect((await r.mf.dispatchFetch(c.path(`proxy/${provider}`) + query[provider], { headers: { upgrade: "websocket", ...headers } })).status).toBe(503);
    }
    expect(r.calls).toHaveLength(0);
  });

  it("refuses spend by an unpaired creator before budget reservation", async () => {
    const r = await runtime(), c = new Client(r), creator = await device("creator"); await c.create(creator);
    expect((await c.auth(creator, "proxy/anthropic")).status).toBe(403);
    expect((await c.open(creator, "elevenlabs")).status).toBe(403);
    expect((await c.open(creator, "assemblyai")).status).toBe(403); expect(r.calls).toHaveLength(0);
    expect(await (await ledger(r)).json()).toEqual({});
  });

  it("refuses historically open rooms when provisioning is later enabled", async () => {
    const { r, c, phone } = await setup();
    const ns = await r.mf.getDurableObjectNamespace("ROOMS");
    await ns.get(ns.idFromName(JSON.stringify([c.account, c.room]))).fetch("https://test/__test", { method: "POST", body: "unprovision" });
    expect((await c.auth(phone, "proxy/anthropic")).status).toBe(403); expect(r.calls).toHaveLength(0);
  });

  it("refuses cloud after a paired room falls below two current members", async () => {
    const { r, c, admin, phone } = await setup();
    const live = socket((await c.open(phone, "assemblyai")).webSocket!);
    expect((await c.auth(admin, "revoke", JSON.stringify({ device_id: admin.device_id }))).status).toBe(200);
    await until(() => live.closed);
    expect((await c.auth(phone, "proxy/anthropic")).status).toBe(403); expect(r.calls).toHaveLength(1);
  });

  it.each(["O'Brien", "O%27Brien", "O%27Brien%20%2B%20%C3%A9", "O%27Brien+%2b+%c3%a9"])("signs the normalized speech query for %s", async term => {
    const { r, c, phone } = await setup();
    const search = query.elevenlabs.replace("SYNTHETIC-vocabulary", term);
    const canonical = canonicalQuery(search), headers = await c.proof(phone, "proxy/elevenlabs", canonical);
    const response = await r.mf.dispatchFetch(c.path("proxy/elevenlabs") + search, { headers: { upgrade: "websocket", ...headers } });
    expect(response.status).toBe(101); socket(response.webSocket!).ws.close(1000);
    expect(new URL(r.calls[0].url).search).toBe(canonical);
  });

  it("matches the shared normalized-query digest vector", async () => {
    const search = query.elevenlabs.replace("SYNTHETIC-vocabulary", "O'Brien");
    expect(await hash(canonicalQuery(search))).toBe("Pf3oZrkv9GShKRbUCijPMlzWfZn9dv4xDIoM51ydJvc=");
  });

  it("cancels a stalled Messages body at the total duration limit", async () => {
    const { r, c, phone } = await setup({ CLOUD_MAX_DURATION_MS: "300" });
    const probeURL = "https://relay.test/__cloud_probe";
    await r.mf.dispatchFetch(probeURL, { method: "POST" });
    try {
      const result = await Promise.race([c.auth(phone, "proxy/anthropic"),
        new Promise<never>((_, reject) => { const timer = setTimeout(() => reject(new Error("Duration limit not enforced")), 1200); timer.unref(); })]);
      expect(result.status).toBe(503);
      const probe = await (await r.mf.dispatchFetch(probeURL)).json() as any;
      expect(probe.aborted).toBe(1); expect(probe.cancelled).toBe(1);
    } finally { await r.mf.dispatchFetch(probeURL, { method: "DELETE" }); }
  });

  it("allows a Messages response body slower than two seconds within its duration budget", async () => {
    const { r, c, phone } = await setup(); r.mode("long-body");
    expect((await c.auth(phone, "proxy/anthropic")).status).toBe(200);
  });

  it("rejects Anthropic configuration with fewer than 2048 output tokens", async () => {
    const { r, c, phone } = await setup({ CLOUD_MAX_OUTPUT_TOKENS: "1024" });
    expect((await c.auth(phone, "proxy/anthropic")).status).toBe(503); expect(r.calls).toHaveLength(0);
  });

  it("revoke cancels the upstream response body immediately", async () => {
    const { r, c, admin, phone } = await setup();
    await c.join(admin, await device("remaining-peer"));
    const probeURL = "https://relay.test/__cloud_probe";
    await r.mf.dispatchFetch(probeURL, { method: "POST" });
    const pending = c.auth(phone, "proxy/anthropic");
    try {
      await new Promise(resolve => setTimeout(resolve, 100));
      expect((await (await r.mf.dispatchFetch(probeURL)).json() as any).started).toBe(1);
      expect((await c.auth(admin, "revoke", JSON.stringify({ device_id: phone.device_id }))).status).toBe(200);
      // Remaining two members keep cloud eligibility: this specifically requires
      // aborting the revoked device, before any deadline or final-response check.
      await new Promise(resolve => setTimeout(resolve, 100));
      const probe = await (await r.mf.dispatchFetch(probeURL)).json() as any;
      expect(probe.aborted).toBe(1); expect(probe.cancelled).toBe(1);
    } finally { await r.mf.dispatchFetch(probeURL, { method: "DELETE" }); }
    expect([403, 503]).toContain((await pending).status);
  });

  it("refuses non-members, missing proof, replay, query tampering and cross-provider proof", async () => {
    const { r, c, phone } = await setup(), outsider = await device("outsider");
    expect((await c.challenge(outsider, "proxy/anthropic", payload())).status).toBe(403);
    expect((await c.post("proxy/anthropic", payload())).status).toBe(403);
    const proof = await c.proof(phone, "proxy/anthropic", payload());
    expect((await c.post("proxy/anthropic", payload(), proof)).status).toBe(200);
    expect((await c.post("proxy/anthropic", payload(), proof)).status).toBe(403);
    const wsProof = await c.proof(phone, "proxy/elevenlabs", query.elevenlabs);
    expect((await r.mf.dispatchFetch(c.path("proxy/elevenlabs") + query.elevenlabs + "&keyterms=changed", { headers: { upgrade: "websocket", ...wsProof } })).status).toBe(403);
    const other = await c.proof(phone, "proxy/elevenlabs", query.assemblyai);
    expect((await r.mf.dispatchFetch(c.path("proxy/assemblyai") + query.assemblyai, { headers: { upgrade: "websocket", ...other } })).status).toBe(403);
    expect(r.calls).toHaveLength(1);
  });

  it.each(["elevenlabs", "assemblyai"] as const)("passes %s text/binary frames both ways and closes on revoke", async provider => {
    const { r, c, admin, phone } = await setup();
    const response = await c.open(phone, provider); expect(response.status).toBe(101);
    expect(response.headers.get("x-secret")).toBeNull();
    const client = socket(response.webSocket!);
    const input = provider === "elevenlabs" ? JSON.stringify({ message_type: "input_audio_chunk", audio_base_64: "AAAA", sample_rate: 16000, commit: false }) : Buffer.from([0, 0, 1, 0]);
    client.ws.send(input); await until(() => client.received.length === 1 || client.closed);
    expect(client.reason).toBeUndefined();
    if (typeof input === "string") expect(client.received[0]).toBe(input);
    else expect(new Uint8Array(client.received[0] as ArrayBuffer)).toEqual(new Uint8Array(input));
    const output = provider === "elevenlabs" ? '{"message_type":"partial_transcript","text":"SYNTHETIC"}' : '{"type":"Turn","transcript":"SYNTHETIC","end_of_turn":false,"turn_order":0}';
    r.vendorSockets[0].send(output); await until(() => client.received.length === 2); expect(client.received[1]).toBe(output);
    const stale = await c.proof(phone, "proxy/anthropic", payload());
    expect((await c.auth(admin, "revoke", JSON.stringify({ device_id: phone.device_id }))).status).toBe(200);
    await until(() => client.closed && r.vendorSockets[0].readyState !== 1);
    expect((await c.post("proxy/anthropic", payload(), stale)).status).toBe(403);
    expect((await c.challenge(phone, `proxy/${provider}`, query[provider])).status).toBe(403);
    expect(r.calls[0].url).toContain(provider === "elevenlabs" ? "api.elevenlabs.io/v1/speech-to-text/realtime" : "streaming.assemblyai.com/v3/ws");
    expect(r.calls[0].headers[provider === "elevenlabs" ? "xi-api-key" : "authorization"]).toBe(key);
    expect(r.calls[0].headers["x-relay-signature"]).toBeUndefined();
    const persisted = JSON.stringify(await c.inspect()) + await (await ledger(r)).text();
    for (const marker of [key, "SYNTHETIC-vocabulary", output, typeof input === "string" ? input : "SYNTHETIC-no-content"]) {
      expect(persisted).not.toContain(marker); expect(r.logs.join("\n")).not.toContain(marker);
    }
  });

  it("keeps Messages wire data, strips headers, and persists/logs no body or key", async () => {
    const { r, c, phone } = await setup();
    const response = await c.auth(phone, "proxy/anthropic"); expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ role: "assistant", type: "message", content: [], stop_reason: "end_turn" });
    expect(response.headers.get("x-secret")).toBeNull(); expect(response.headers.get("set-cookie")).toBeNull();
    expect(r.calls[0].url).toBe("https://api.anthropic.com/v1/messages"); expect(r.calls[0].body).toBe(payload());
    expect(r.calls[0].headers["x-api-key"]).toBe(key);
    const state = JSON.stringify(await c.inspect()) + await (await ledger(r)).text(), logs = r.logs.join("\n");
    for (const marker of [key, prompt, "SYNTHETIC-vocabulary"]) { expect(state).not.toContain(marker); expect(logs).not.toContain(marker); }
  });

  it("binds exact Messages bytes and forwards only validated JSON after duplicate keys", async () => {
    const { r, c, phone } = await setup();
    const proof = await c.proof(phone, "proxy/anthropic", payload());
    expect((await c.post("proxy/anthropic", payload() + " ", proof)).status).toBe(403);
    const duplicate = '{"model":"unapproved",' + payload().slice(1);
    expect((await c.auth(phone, "proxy/anthropic", duplicate)).status).toBe(200);
    expect(r.calls[0].body).toBe(payload()); expect(r.calls[0].body).not.toContain("unapproved");
  });

  it("refuses disallowed routes, URL injection, paid models and server tools without upstream calls", async () => {
    const { r, c, phone } = await setup();
    for (const path of ["proxy/anthropic/v1/messages", "proxy/https://evil.invalid", "proxy/unknown"]) expect((await c.post(path, payload())).status).toBe(404);
    const q = query.elevenlabs + "&url=https://evil.invalid";
    expect((await r.mf.dispatchFetch(c.path("proxy/elevenlabs") + q, { headers: { upgrade: "websocket", ...await c.proof(phone, "proxy/elevenlabs", q) } })).status).toBe(400);
    for (const extra of [{ model: "unapproved" }, { max_tokens: 999999 }, { stream: true }, { tools: [{ type: "web_search", name: "web_search" }] }, { messages: [{ role: "user", content: [{ type: "image", source: { url: "https://evil.invalid" } }] }] }]) {
      expect((await c.auth(phone, "proxy/anthropic", JSON.stringify({ ...JSON.parse(payload()), ...extra }))).status).toBe(400);
    }
    expect(r.calls).toHaveLength(0);
  });

  it("reserves device spend across rooms and persists reservations across eviction", async () => {
    const { r, c, phone } = await setup({ CLOUD_DEVICE_DAILY_MICROUSD: "100" });
    expect((await c.auth(phone, "proxy/anthropic")).status).toBe(200);
    const ns = await r.mf.getDurableObjectNamespace("CLOUD_BUDGET");
    await r.mf.unsafeEvictDurableObject("cloud-test", "CloudBudget", { id: ns.idFromName("global").toString() });
    const second = new Client(r); await second.create(phone); await second.join(phone, await device("second-peer"));
    const denied = await second.auth(phone, "proxy/anthropic"); expect(denied.status).toBe(429);
    expect(await denied.json()).toEqual({ error: "budget_exceeded" }); expect(r.calls).toHaveLength(1);
  });

  it("enforces one global daily budget across devices and rooms, even after upstream failures", async () => {
    const { r, c, phone } = await setup({ CLOUD_GLOBAL_DAILY_MICROUSD: "100" });
    r.mode("error"); expect((await c.auth(phone, "proxy/anthropic")).status).toBe(502);
    r.mode("normal"); const second = new Client(r), other = await device("other"); await second.create(other); await second.join(other, await device("second-peer"));
    expect((await second.auth(other, "proxy/anthropic")).status).toBe(429); expect(r.calls).toHaveLength(1);
  });

  it("serializes simultaneous reservations across rooms", async () => {
    const { r, c, phone } = await setup({ CLOUD_GLOBAL_DAILY_MICROUSD: "100" });
    const otherRoom = new Client(r), other = await device("other"); await otherRoom.create(other); await otherRoom.join(other, await device("other-peer"));
    const responses = await Promise.all([c.auth(phone, "proxy/anthropic"), otherRoom.auth(other, "proxy/anthropic")]);
    expect(responses.map(response => response.status).sort()).toEqual([200, 429]); expect(r.calls).toHaveLength(1);
  });

  it("resets UTC spend without dropping active leases and rejects observed clock rollback", async () => {
    const { r, c, phone } = await setup({ CLOUD_DEVICE_DAILY_MICROUSD: "100", CLOUD_DEVICE_CONCURRENT: "1" });
    const live = socket((await c.open(phone, "assemblyai")).webSocket!);
    await ledger(r, "yesterday");
    const denied = await c.auth(phone, "proxy/anthropic"); expect(denied.status).toBe(429);
    expect(await denied.json()).toEqual({ error: "concurrency_exceeded" });
    live.ws.close(1000); await until(() => live.closed); await new Promise(resolve => setTimeout(resolve, 50));
    expect((await c.auth(phone, "proxy/anthropic")).status).toBe(200);
    await ledger(r, "rollback");
    const rollback = await c.auth(phone, "proxy/anthropic"); expect(rollback.status).toBe(503);
    expect(await rollback.json()).toEqual({ error: "clock_unavailable" });
  });

  it.each(["ANTHROPIC_API_KEY", "ELEVENLABS_API_KEY", "ASSEMBLYAI_API_KEY"])("missing %s disables that provider cleanly", async secret => {
    const { r, c, phone } = await setup({ [secret]: "" });
    const response = secret === "ANTHROPIC_API_KEY" ? await c.auth(phone, "proxy/anthropic") : await c.open(phone, secret === "ELEVENLABS_API_KEY" ? "elevenlabs" : "assemblyai");
    expect(response.status).toBe(503); expect(await response.json()).toEqual({ error: "provider_not_configured" }); expect(r.calls).toHaveLength(0);
  });

  it("fails closed on unset/zero policy and excessive body size", async () => {
    const { r, c, phone } = await setup({ CLOUD_GLOBAL_DAILY_MICROUSD: "0" });
    const disabled = await c.auth(phone, "proxy/anthropic"); expect(disabled.status).toBe(503);
    expect(await disabled.json()).toEqual({ error: "cloud_not_configured" });
    const raw = "x".repeat(65537); expect((await c.auth(phone, "proxy/anthropic", raw)).status).toBe(413); expect(r.calls).toHaveLength(0);
  });

  it.each(["error", "redirect", "secret"] as const)("contains %s responses without exposing keys, content or headers", async mode => {
    const { r, c, phone } = await setup(); r.mode(mode);
    const response = await c.auth(phone, "proxy/anthropic"); expect(response.status).toBe(502);
    const output = await response.text(); expect(output).toBe('{"error":"upstream_failed"}');
    expect(output + r.logs.join("\n") + JSON.stringify([...response.headers])).not.toContain(key);
    expect(r.logs.join("\n")).not.toContain(prompt); expect(r.calls).toHaveLength(1);
  });

  it("closes a vendor stream containing a key or a paid client control without forwarding either", async () => {
    const { r, c, phone } = await setup();
    const response = await c.open(phone, "assemblyai"), client = socket(response.webSocket!);
    r.vendorSockets[0].send(JSON.stringify({ error: key })); await until(() => client.closed); expect(client.received).toHaveLength(0);
    const next = await c.open(phone, "assemblyai"), other = socket(next.webSocket!);
    other.ws.send('{"type":"LLMGatewayRequest","prompt":"SYNTHETIC"}'); await until(() => other.closed); expect(other.received).toHaveLength(0);
    expect(r.logs.join("\n")).not.toContain(key);
  });

  it("rejects duplicate speech control fields before forwarding", async () => {
    const { r, c, phone } = await setup();
    const client = socket((await c.open(phone, "elevenlabs")).webSocket!);
    client.ws.send('{"message_type":"unapproved","message_type":"input_audio_chunk","audio_base_64":"AAAA","sample_rate":16000,"commit":false}');
    await until(() => client.closed); expect(client.reason).toBe("invalid_request"); expect(client.received).toHaveLength(0);
  });

  it("forwards the client Terminate control and contains vendor close reasons", async () => {
    const { r, c, phone } = await setup();
    const client = socket((await c.open(phone, "assemblyai")).webSocket!);
    client.ws.send('{"type":"Terminate"}'); await until(() => client.received.length > 0);
    expect(client.received[0]).toBe('{"type":"Terminate"}');
    r.vendorSockets[0].close(1008, key); await until(() => client.closed);
    expect(client.reason).toBe("closed"); expect(r.logs.join("\n")).not.toContain(key);
  });

  it("enforces device and global concurrent stream limits and frees closed leases", async () => {
    const { r, c, phone } = await setup({ CLOUD_DEVICE_CONCURRENT: "1", CLOUD_GLOBAL_CONCURRENT: "1" });
    const one = socket((await c.open(phone, "assemblyai")).webSocket!);
    const deviceLimit = await c.open(phone, "elevenlabs"); expect(deviceLimit.status).toBe(429);
    expect(await deviceLimit.json()).toEqual({ error: "concurrency_exceeded" });
    const second = new Client(r), other = await device("other"); await second.create(other); await second.join(other, await device("second-peer"));
    expect((await second.open(other, "assemblyai")).status).toBe(429);
    one.ws.close(1000); await until(() => one.closed);
    // Release is an asynchronous internal request; allow it to reach the singleton.
    await new Promise(resolve => setTimeout(resolve, 50));
    const accepted = await second.open(other, "assemblyai"); expect(accepted.status).toBe(101); socket(accepted.webSocket!).ws.close(1000);
  });

  it("enforces stream duration, frame cap and aggregate bytes", async () => {
    const { r, c, phone } = await setup({ CLOUD_MAX_DURATION_MS: "300", CLOUD_MAX_FRAME_BYTES: "8", CLOUD_MAX_STREAM_BYTES: "10" });
    const timed = socket((await c.open(phone, "assemblyai")).webSocket!); await until(() => timed.closed);
    const oversized = socket((await c.open(phone, "assemblyai")).webSocket!); oversized.ws.send(Buffer.alloc(10)); await until(() => oversized.closed); expect(oversized.reason).toBe("too_large");
    const aggregate = socket((await c.open(phone, "assemblyai")).webSocket!); aggregate.ws.send(Buffer.alloc(6)); await until(() => aggregate.closed); expect(aggregate.reason).toBe("too_large");
    expect(aggregate.received).toHaveLength(0); // 6 inbound + 6 echoed outbound exceeds 10.
    expect(r.logs.join("\n")).not.toContain(key);
  });

  it.each(["slow", "slow-body"] as const)("revoke interrupts an in-flight HTTP request (%s) before returning provider content", async mode => {
    const { r, c, admin, phone } = await setup(); r.mode(mode);
    const pending = c.auth(phone, "proxy/anthropic"); await until(() => r.calls.length > 0);
    if (mode === "slow-body") await new Promise(resolve => setTimeout(resolve, 50));
    expect((await c.auth(admin, "revoke", JSON.stringify({ device_id: phone.device_id }))).status).toBe(200);
    const result = await pending; expect([403, 503]).toContain(result.status);
    expect(await result.text()).not.toContain("assistant");
  });
});
