import { DurableObject } from "cloudflare:workers";
import { failure, hash, id, json, LIMITS, requireThat, secretMatches, sourceBucket } from "./security.js";
import { wake, type CachedToken, type WakeRegistration, type WakeSecrets } from "./apns.js";
import { proxySocket } from "./socket-proxy.js";
import { cloudProvisioned, type CloudEnv } from "./services.js";
export { CloudBudget } from "./services.js";
export { Room } from "./room.js";

export interface Env extends WakeSecrets, CloudEnv {
  ROOMS: DurableObjectNamespace;
  ADMISSION: DurableObjectNamespace;
  WAKE: DurableObjectNamespace;
  RELAY_PROVISION_SECRET?: string;
}
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const url = new URL(request.url);
      const cloud = /\/proxy\/(elevenlabs|assemblyai|anthropic)$/.test(url.pathname);
      requireThat(url.search === "" || (cloud && !url.pathname.endsWith("/anthropic")), 400);
      const match = /^\/v1\/accounts\/([^/]+)\/rooms\/([^/]+)\/(create|challenge|join|invite|revoke|connect|proxy\/(?:elevenlabs|assemblyai|anthropic))$/.exec(url.pathname);
      requireThat(match, 404, "not_found");
      if (cloud) requireThat(cloudProvisioned(env), 503, "cloud_not_configured");
      const [, account, room, operation] = match;
      id(account); requireThat(/^[0-9a-f]{32}$/.test(room));
      requireThat(request.method === ((operation === "connect" || operation === "proxy/elevenlabs" || operation === "proxy/assemblyai") ? "GET" : "POST"), 405, "method_not_allowed");
      const prefix = await hash(sourceBucket(request.headers.get("CF-Connecting-IP") ?? "local"));
      async function admission(key: string): Promise<boolean> {
        const gate = env.ADMISSION.get(env.ADMISSION.idFromName(key));
        return (await gate.fetch("https://admission/check", { method: "POST" })).ok;
      }
      if (operation === "create") {
        requireThat(env.RELAY_PROVISION_SECRET === undefined
          || await secretMatches(request.headers.get("authorization"), env.RELAY_PROVISION_SECRET), 403, "forbidden");
        requireThat(await admission(JSON.stringify(["create", prefix])), 429, "rate_limited");
      }
      const stub = env.ROOMS.get(env.ROOMS.idFromName(JSON.stringify([account, room])));
      const headers = new Headers();
      for (const name of ["upgrade", "content-type", "content-encoding", "x-relay-challenge", "x-relay-signature", "anthropic-version"]) {
        const value = request.headers.get(name); if (value !== null) headers.set(name, value);
      }
      const response = await stub.fetch(new Request(request.url, { method: request.method, headers, body: request.body }));
      if (operation === "join" && response.headers.has("x-relay-token-mismatch")) {
        // Validate before charging a source/room failure bucket. A valid token
        // always bypasses the budget, including behind the same NAT as an attacker.
        const allowed = await admission(JSON.stringify(["join", account, room, prefix]));
        return json({ error: allowed ? "forbidden" : "rate_limited" }, allowed ? 403 : 429);
      }
      return response.status === 101 ? proxySocket(response) : response;
    } catch (error) { return failure(error); }
  },
} satisfies ExportedHandler<Env>;

export class Admission extends DurableObject {
  async fetch(): Promise<Response> {
    return this.ctx.blockConcurrencyWhile(async () => {
      const now = Date.now();
      let bucket = await this.ctx.storage.get<{ start: number; count: number }>("bucket");
      if (!bucket || now - bucket.start >= 60_000) bucket = { start: now, count: 0 };
      if (now < bucket.start || bucket.count >= LIMITS.attemptsPerMinute) return json({}, 429);
      bucket.count++;
      await this.ctx.storage.put("bucket", bucket); await this.ctx.storage.setAlarm(bucket.start + 60_000);
      return json({});
    });
  }
  async alarm(): Promise<void> { await this.ctx.blockConcurrencyWhile(async () => { await this.ctx.storage.deleteAll(); }); }
}

// One signer/cache per deployment. Persistence prevents hibernation or room
// fanout from minting a new provider token on every wake. No public route.
export class WakeProvider extends DurableObject<Env> {
  async fetch(request: Request): Promise<Response> {
    return this.ctx.blockConcurrencyWhile(async () => {
      await wake(this.env, await request.json() as WakeRegistration, {
        get: () => this.ctx.storage.get<CachedToken>("provider"),
        put: value => this.ctx.storage.put("provider", value),
      });
      return json({});
    });
  }
}
