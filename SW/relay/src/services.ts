import { DurableObject } from "cloudflare:workers";
import { parseControl } from "./control.js";
import type { Env } from "./worker.js";
import { body, failure, hash, json, Refusal, requireThat, utf8 } from "./security.js";

// Fixed destinations only. Neither request headers nor JSON can select an origin.
const upstreams = {
  elevenlabs: "https://api.elevenlabs.io/v1/speech-to-text/realtime",
  assemblyai: "https://streaming.assemblyai.com/v3/ws",
  anthropic: "https://api.anthropic.com/v1/messages",
} as const;
export type Provider = keyof typeof upstreams;
export interface CloudEnv {
  CLOUD_BUDGET?: DurableObjectNamespace;
  ANTHROPIC_API_KEY?: string; ELEVENLABS_API_KEY?: string; ASSEMBLYAI_API_KEY?: string;
  CLOUD_DEVICE_DAILY_MICROUSD?: string; CLOUD_GLOBAL_DAILY_MICROUSD?: string;
  CLOUD_DEVICE_CONCURRENT?: string; CLOUD_GLOBAL_CONCURRENT?: string;
  CLOUD_SPEECH_RESERVATION_MICROUSD?: string; CLOUD_ANTHROPIC_RESERVATION_MICROUSD?: string;
  CLOUD_MAX_BODY_BYTES?: string; CLOUD_MAX_FRAME_BYTES?: string; CLOUD_MAX_STREAM_BYTES?: string;
  CLOUD_MAX_DURATION_MS?: string; CLOUD_ANTHROPIC_MODEL?: string; CLOUD_ANTHROPIC_VERSION?: string;
  CLOUD_MAX_OUTPUT_TOKENS?: string;
}
export function cloudProvisioned(env: { RELAY_PROVISION_SECRET?: string }): boolean {
  return (env.RELAY_PROVISION_SECRET?.length ?? 0) >= 32;
}
// Ordered application/x-www-form-urlencoded pairs, including leading '?'.
// Normalizes URL-parser escaping (notably apostrophes) before signing/hashing.
export function cloudSigningQuery(url: URL): string {
  const query = url.searchParams.toString(); return query ? `?${query}` : "";
}
function number(value: string | undefined, ceiling = Number.MAX_SAFE_INTEGER): number {
  requireThat(value && /^[1-9][0-9]*$/.test(value), 503, "cloud_not_configured");
  const n = Number(value); requireThat(Number.isSafeInteger(n) && n <= ceiling, 503, "cloud_not_configured"); return n;
}
export function cloudBodyLimit(env: CloudEnv, provider?: Provider): number {
  if (provider) providerKey(env, provider);
  return number(env.CLOUD_MAX_BODY_BYTES, 1_048_576);
}
function providerKey(env: CloudEnv, provider: Provider): string {
  const key = provider === "anthropic" ? env.ANTHROPIC_API_KEY
    : provider === "elevenlabs" ? env.ELEVENLABS_API_KEY : env.ASSEMBLYAI_API_KEY;
  requireThat(key && key.trim() && !/[\r\n]/.test(key), 503, "provider_not_configured");
  return key;
}
function settings(env: CloudEnv, provider: Provider) {
  const key = providerKey(env, provider);
  requireThat(env.CLOUD_BUDGET, 503, "cloud_not_configured");
  const config = {
    key, bodyBytes: cloudBodyLimit(env), frameBytes: number(env.CLOUD_MAX_FRAME_BYTES, 1_048_576),
    streamBytes: number(env.CLOUD_MAX_STREAM_BYTES, 16_777_216), duration: number(env.CLOUD_MAX_DURATION_MS, 300_000),
    cost: number(provider === "anthropic" ? env.CLOUD_ANTHROPIC_RESERVATION_MICROUSD : env.CLOUD_SPEECH_RESERVATION_MICROUSD),
  };
  if (provider === "anthropic") requireThat(env.CLOUD_ANTHROPIC_MODEL && env.CLOUD_ANTHROPIC_VERSION
    && number(env.CLOUD_MAX_OUTPUT_TOKENS, 8192) >= 2048, 503, "cloud_not_configured");
  return config;
}
function speechQuery(provider: Provider, query: URLSearchParams): string {
  const fixed = provider === "elevenlabs"
    ? { model_id: "scribe_v2_realtime", audio_format: "pcm_16000", commit_strategy: "manual" }
    : { speech_model: "universal-3-5-pro", sample_rate: "16000", encoding: "pcm_s16le", include_partial_turns: "true" };
  const vocabulary = provider === "elevenlabs" ? "keyterms" : "keyterms_prompt";
  for (const name of query.keys()) requireThat(Object.hasOwn(fixed, name) || name === vocabulary);
  for (const [name, value] of Object.entries(fixed)) requireThat(query.getAll(name).length === 1 && query.get(name) === value);
  const terms = query.getAll(vocabulary);
  if (provider === "elevenlabs") requireThat(terms.length <= 100 && terms.every(t => t.length > 0 && utf8.encode(t).length <= 256));
  else {
    requireThat(terms.length <= 1);
    if (terms.length) {
      let value: unknown; try { value = JSON.parse(terms[0]); } catch { throw new Refusal(400, "invalid_request"); }
      requireThat(Array.isArray(value) && value.length <= 100 && value.every(t => typeof t === "string" && t.length > 0 && utf8.encode(t).length <= 256));
    }
  }
  return query.toString();
}
function messages(env: CloudEnv, raw: string): string {
  let value: any; try { value = JSON.parse(raw); } catch { throw new Refusal(400, "invalid_request"); }
  requireThat(value && typeof value === "object" && !Array.isArray(value));
  requireThat(Object.keys(value).every(k => ["model", "max_tokens", "system", "messages", "tools", "tool_choice"].includes(k)));
  requireThat(value.model === env.CLOUD_ANTHROPIC_MODEL && Number.isSafeInteger(value.max_tokens)
    && value.max_tokens > 0 && value.max_tokens <= number(env.CLOUD_MAX_OUTPUT_TOKENS, 8192));
  // Text-only input and client tool definitions: no URLs, images, files, server tools,
  // extended thinking, caching, beta features or paid tool execution.
  requireThat(typeof value.system === "string" && Array.isArray(value.messages) && value.messages.length > 0);
  requireThat(value.messages.every((m: any) => m && Object.keys(m).length === 2
    && ["user", "assistant"].includes(m.role) && typeof m.content === "string"));
  if (value.tools !== undefined) requireThat(Array.isArray(value.tools) && value.tools.length <= 64 && value.tools.every((t: any) => t
    && Object.keys(t).every(k => ["name", "description", "input_schema"].includes(k))
    && typeof t.name === "string" && typeof t.description === "string" && t.input_schema && typeof t.input_schema === "object"));
  if (value.tool_choice !== undefined) requireThat(value.tool_choice && Object.keys(value.tool_choice).length === 1 && value.tool_choice.type === "auto");
  // Forward the validated parse to avoid duplicate-key parser disagreement.
  return JSON.stringify(value);
}

function speechInput(provider: Provider, data: string | ArrayBuffer): boolean {
  if (provider === "assemblyai" && typeof data !== "string") return data.byteLength % 2 === 0;
  if (typeof data !== "string") return false;
  try {
    const value = parseControl(data) as Record<string, unknown>;
    if (!value || typeof value !== "object" || Array.isArray(value)) return false;
    if (provider === "assemblyai") return Object.keys(value).length === 1 && value.type === "Terminate";
    return Object.keys(value).every(k => ["message_type", "audio_base_64", "sample_rate", "commit"].includes(k))
      && value.message_type === "input_audio_chunk" && typeof value.audio_base_64 === "string"
      && /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value.audio_base_64)
      && value.sample_rate === 16000 && typeof value.commit === "boolean";
  } catch { return false; }
}

interface Lease { id: string; device: string; expires: number }
interface Ledger { day: number; highWater: number; total: number; devices: Record<string, number>; leases: Lease[] }
// One deployment-wide singleton, not one per room/account. Only hashed public
// keys, counters and expiring lease IDs persist; failed calls are never refunded.
export class CloudBudget extends DurableObject<Env> {
  async fetch(request: Request): Promise<Response> {
    return this.ctx.blockConcurrencyWhile(async () => {
      try {
        const now = Date.now(), day = Math.floor(now / 86_400_000);
        let ledger = await this.ctx.storage.get<Ledger>("ledger");
        requireThat(!ledger || now >= ledger.highWater, 503, "clock_unavailable");
        if (!ledger) ledger = { day, highWater: now, total: 0, devices: {}, leases: [] };
        ledger.highWater = now; ledger.leases = ledger.leases.filter(l => l.expires > now);
        if (day > ledger.day) { ledger.day = day; ledger.total = 0; ledger.devices = {}; }
        const input = await request.json() as { device: string; cost: number; duration: number; lease?: string };
        if (new URL(request.url).pathname === "/release") ledger.leases = ledger.leases.filter(l => l.id !== input.lease);
        else {
          const deviceCap = number(this.env.CLOUD_DEVICE_DAILY_MICROUSD), globalCap = number(this.env.CLOUD_GLOBAL_DAILY_MICROUSD);
          const deviceConcurrent = number(this.env.CLOUD_DEVICE_CONCURRENT, 100), globalConcurrent = number(this.env.CLOUD_GLOBAL_CONCURRENT, 1000);
          requireThat(input.cost > 0 && Number.isSafeInteger(input.cost) && input.duration > 0 && input.duration <= 300_000);
          requireThat(ledger.total <= globalCap - input.cost && (ledger.devices[input.device] ?? 0) <= deviceCap - input.cost, 429, "budget_exceeded");
          requireThat(ledger.leases.length < globalConcurrent && ledger.leases.filter(l => l.device === input.device).length < deviceConcurrent, 429, "concurrency_exceeded");
          const lease = crypto.randomUUID();
          ledger.total += input.cost; ledger.devices[input.device] = (ledger.devices[input.device] ?? 0) + input.cost;
          // Grace prevents reallocation while an aborted upstream is tearing down.
          ledger.leases.push({ id: lease, device: input.device, expires: now + input.duration + 5000 });
          await this.ctx.storage.put("ledger", ledger); await this.ctx.storage.setAlarm(Math.min(...ledger.leases.map(l => l.expires)));
          return json({ lease });
        }
        await this.ctx.storage.put("ledger", ledger); return json({});
      } catch (error) { return failure(error); }
    });
  }
  async alarm(): Promise<void> {
    await this.ctx.blockConcurrencyWhile(async () => {
      const ledger = await this.ctx.storage.get<Ledger>("ledger"); if (!ledger) return;
      ledger.leases = ledger.leases.filter(l => l.expires > Date.now());
      await this.ctx.storage.put("ledger", ledger);
      if (ledger.leases.length) await this.ctx.storage.setAlarm(Math.min(...ledger.leases.map(l => l.expires)));
    });
  }
}

interface Session { device: string; abort: AbortController }
export class CloudSessions {
  private readonly active = new Set<Session>();
  constructor(private readonly env: Env, private readonly waitUntil: (task: Promise<unknown>) => void) {}
  revoke(device?: string): void {
    for (const session of this.active) if (device === undefined || session.device === device) session.abort.abort();
  }
  async serve(request: Request, raw: string, provider: Provider, member: { device: string; key: string }, current: () => boolean): Promise<Response> {
    const session: Session = { device: member.device, abort: new AbortController() };
    this.active.add(session);
    let pendingSocket: WebSocket | undefined;
    let lease: string | undefined, timer: ReturnType<typeof setTimeout> | undefined, handedOff = false;
    const gate = this.env.CLOUD_BUDGET?.get(this.env.CLOUD_BUDGET.idFromName("global"));
    const cleanup = () => {
      clearTimeout(timer);
      if (pendingSocket) {
        try { pendingSocket.accept(); pendingSocket.close(1008, "session_ended"); } catch { /* already closed */ }
        pendingSocket = undefined;
      }
      session.abort.abort(); this.active.delete(session);
      if (lease && gate) {
        const id = lease; lease = undefined;
        this.waitUntil(gate.fetch("https://budget/release", { method: "POST", body: JSON.stringify({ lease: id }) }).then(() => {}).catch(() => {}));
      }
    };
    try {
      requireThat(current(), 403, "forbidden");
      const config = settings(this.env, provider), url = new URL(request.url);
      requireThat(utf8.encode(url.search).length <= config.bodyBytes, 413, "too_large");
      let target: string = upstreams[provider];
      if (provider === "anthropic") {
        requireThat(request.headers.get("content-type")?.split(";")[0].trim() === "application/json");
        requireThat(request.headers.get("anthropic-version") === this.env.CLOUD_ANTHROPIC_VERSION);
        raw = messages(this.env, raw);
      } else {
        requireThat(request.headers.get("upgrade")?.toLowerCase() === "websocket", 426, "upgrade_required");
        target += `?${speechQuery(provider, url.searchParams)}`;
      }
      const reservation = await gate!.fetch("https://budget/reserve", { method: "POST", body: JSON.stringify({
        device: await hash(member.key), cost: config.cost, duration: config.duration,
      }) });
      if (!reservation.ok) return reservation;
      lease = (await reservation.json() as { lease: string }).lease;
      requireThat(current() && !session.abort.signal.aborted, 403, "forbidden");
      timer = setTimeout(() => session.abort.abort(), config.duration);
      const headers = new Headers(provider === "anthropic"
        ? { "content-type": "application/json", "x-api-key": config.key, "anthropic-version": this.env.CLOUD_ANTHROPIC_VERSION! }
        : provider === "elevenlabs" ? { upgrade: "websocket", "xi-api-key": config.key } : { upgrade: "websocket", authorization: config.key });
      const response = await fetch(target, { method: provider === "anthropic" ? "POST" : "GET", headers,
        body: provider === "anthropic" ? raw : undefined, redirect: "manual", signal: session.abort.signal });
      pendingSocket = response.webSocket ?? undefined;
      requireThat(current() && !session.abort.signal.aborted, 403, "forbidden");
      const secrets = [this.env.ANTHROPIC_API_KEY, this.env.ELEVENLABS_API_KEY, this.env.ASSEMBLYAI_API_KEY].filter((s): s is string => !!s);
      const safe = (data: string | ArrayBuffer) => {
        const text = typeof data === "string" ? data : new TextDecoder().decode(data);
        let decoded = "";
        try { decoded = JSON.stringify(JSON.parse(text)); } catch { /* audio may be binary */ }
        return !secrets.some(key => text.includes(key) || decoded.includes(key) || text.includes(JSON.stringify(key).slice(1, -1)));
      };
      if (provider === "anthropic") {
        requireThat(response.status === 200, 502, "upstream_failed");
        const result = await body(new Request("https://internal/result", { method: "POST", body: response.body }), 1_048_576, config.duration, session.abort.signal);
        requireThat(current() && !session.abort.signal.aborted, 403, "forbidden");
        requireThat(safe(result), 502, "upstream_failed");
        return new Response(result, { headers: { "content-type": "application/json", "cache-control": "no-store" } });
      }
      requireThat(response.status === 101 && response.webSocket, 502, "upstream_failed");
      const upstream = response.webSocket, pair = new WebSocketPair(), client = pair[0], server = pair[1];
      let ended = false, bytes = 0;
      const end = (code = 1000, reason = "closed") => {
        if (ended) return; ended = true;
        for (const socket of [server, upstream]) if (socket.readyState === 1) socket.close(code, reason);
        cleanup();
      };
      // Close reasons, upstream errors and headers can contain credentials/content.
      // Only payload frames pass; closes use fixed locally generated metadata.
      for (const [source, destination] of [[server, upstream], [upstream, server]]) {
        source.addEventListener("message", event => {
          if (ended) return;
          const size = typeof event.data === "string" ? utf8.encode(event.data).length : event.data.byteLength;
          bytes += size;
          if (!current() || session.abort.signal.aborted) { end(1008, "revoked"); return; }
          if (size > config.frameBytes || bytes > config.streamBytes) { end(1009, "too_large"); return; }
          if (source === server && !speechInput(provider, event.data)) { end(1008, "invalid_request"); return; }
          if (!safe(event.data)) { end(1011, "upstream_failed"); return; }
          try { destination.send(event.data); } catch { end(1011, "upstream_failed"); }
        });
        source.addEventListener("close", () => end());
        source.addEventListener("error", () => end(1011, "upstream_failed"));
      }
      session.abort.signal.addEventListener("abort", () => end(1008, "session_ended"), { once: true });
      upstream.binaryType = "arraybuffer"; server.binaryType = "arraybuffer";
      upstream.accept({ allowHalfOpen: false }); server.accept({ allowHalfOpen: false });
      pendingSocket = undefined;
      handedOff = true;
      return new Response(null, { status: 101, webSocket: client, headers: { "cache-control": "no-store" } });
    } catch (error) { return failure(error); }
    finally { if (!handedOff) cleanup(); }
  }
}
