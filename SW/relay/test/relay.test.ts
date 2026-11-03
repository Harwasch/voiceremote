import { build } from "esbuild";
import WebSocket from "ws";
import { once } from "node:events";
import { convertV4MiniflareOptions, Log, LogLevel, Miniflare, Response as MFResponse, type Request as MFRequest, type WebSocket as MFWebSocket } from "miniflare";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { RelayFrame, RelayCiphertext } from "../src/protocol/generated.js";
import { ARCHIVE_LIMITS, archiveHash } from "../src/archive.js";
import type { AuditArchiveBlock } from "../src/protocol/generated.js";
import { hash, LIMITS } from "../src/security.js";
import { mutationPlugin } from "./mutations.js";

const provisionSecret = "SYNTHETIC-test-provisioning-only-00000000";
const runtimeOutput: string[] = [];
const outbound: { url: string; headers: Record<string, string>; body: string }[] = [];
let mf: Miniflare;
let serial = 0;
interface Device { device_id: string; public_key: string; privateKey: CryptoKey }
interface Invite { one_use_token: string; expires_at: number }
const b64 = (bytes: ArrayBuffer | Uint8Array): string => Buffer.from(bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes)).toString("base64");
async function device(name: string): Promise<Device> {
  const keys = await crypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]) as CryptoKeyPair;
  return { device_id: name, public_key: b64(await crypto.subtle.exportKey("raw", keys.publicKey)), privateKey: keys.privateKey };
}
async function sign(d: Device, message: string): Promise<string> {
  return b64(await crypto.subtle.sign("Ed25519", d.privateKey, new TextEncoder().encode(message)));
}
class Socket {
  readonly inbox: RelayFrame[] = [];
  private changed: (() => void)[] = [];
  closed?: { code: number; reason: string };
  constructor(readonly socket: MFWebSocket, readonly dropped = 0) {
    socket.addEventListener("message", event => {
      this.inbox.push(JSON.parse(event.data as string)); this.changed.splice(0).forEach(f => f());
    });
    socket.addEventListener("close", event => {
      this.closed = { code: event.code, reason: event.reason }; this.changed.splice(0).forEach(f => f());
    });
    socket.accept();
  }
  send(value: unknown): void { this.socket.send(typeof value === "string" ? value : JSON.stringify(value)); }
  async until(check: () => boolean): Promise<void> {
    const deadline = Date.now() + 5000;
    while (!check()) {
      if (Date.now() > deadline) throw new Error("Synthetic client timed out");
      await new Promise<void>(resolve => {
        const timer = setTimeout(resolve, 25);
        this.changed.push(() => { clearTimeout(timer); resolve(); });
      });
    }
  }
  async next(kind: RelayFrame["kind"], deviceId?: string): Promise<RelayFrame> {
    const match = (f: RelayFrame): boolean => f.kind === kind && (!deviceId || f.sender_device_id === deviceId);
    await this.until(() => this.inbox.some(match));
    return this.inbox.splice(this.inbox.findIndex(match), 1)[0];
  }
  async close(): Promise<void> {
    if (this.closed) return;
    this.socket.close(1000, "test done");
    await this.until(() => !!this.closed);
  }
}
class RoomClient {
  readonly account: string;
  readonly room: string;
  readonly ip: string;
  constructor(account = `account-${++serial}`, room = Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString("hex")) {
    this.account = account; this.room = room; this.ip = `192.0.2.${++serial}`;
  }
  path(operation: string): string { return `https://relay.test/v1/accounts/${this.account}/rooms/${this.room}/${operation}`; }
  async post(operation: string, value: unknown, headers: Record<string, string> = {}) {
    return mf.dispatchFetch(this.path(operation), { method: "POST", body: typeof value === "string" ? value : JSON.stringify(value),
      headers: { "CF-Connecting-IP": this.ip, ...headers } });
  }
  async create(d: Device) {
    const raw = JSON.stringify({ device_id: d.device_id, public_key: d.public_key });
    return this.post("create", raw, { authorization: `Bearer ${provisionSecret}`, "x-relay-signature": await sign(d,
      JSON.stringify(["voiceremote-relay-create-v1", this.account, this.room, await hash(raw)])) });
  }
  async proof(d: Device, operation: string, raw = "") {
    const challengeBody = JSON.stringify({ device_id: d.device_id, operation, body_sha256: await hash(raw) });
    const response = await this.post("challenge", challengeBody, { "x-relay-signature": await sign(d,
      JSON.stringify(["voiceremote-relay-challenge-v1", this.account, this.room, await hash(challengeBody)])) });
    expect(response.status).toBe(200);
    const challenge = await response.json() as { challenge: string; message: string };
    return { "x-relay-challenge": challenge.challenge, "x-relay-signature": await sign(d, challenge.message) };
  }
  async auth(d: Device, operation: string, value: unknown) {
    const raw = JSON.stringify(value);
    return this.post(operation, raw, await this.proof(d, operation, raw));
  }
  async invite(admin: Device): Promise<Invite> {
    const one_use_token = b64(crypto.getRandomValues(new Uint8Array(32))), expires_at = Date.now() + LIMITS.tokenTtlMs;
    const response = await this.auth(admin, "invite", { token_sha256: await hash(one_use_token), expires_at });
    expect(response.status).toBe(201); return { one_use_token, expires_at };
  }
  async join(d: Device, invite: Invite) {
    const message = JSON.stringify(["voiceremote-relay-join-v1", this.account, this.room,
      d.device_id, d.public_key, invite.one_use_token, invite.expires_at]);
    return this.post("join", { device_id: d.device_id, public_key: d.public_key,
      one_use_token: invite.one_use_token, expires_at: invite.expires_at, signature: await sign(d, message) });
  }
  async connect(d: Device): Promise<Socket> {
    const response = await mf.dispatchFetch(this.path("connect"), { headers: {
      "CF-Connecting-IP": this.ip, upgrade: "websocket", ...await this.proof(d, "connect"),
    } });
    expect(response.status).toBe(101);
    const client = new Socket(response.webSocket!, Number(response.headers.get("x-relay-dropped-frames")));
    await client.next("presence", d.device_id);
    return client;
  }
  async inspect(expire?: string): Promise<any> {
    return (await this.inspectAll(expire)).room;
  }
  async inspectAll(expire?: string): Promise<any> {
    const ns = await mf.getDurableObjectNamespace("ROOMS");
    const stub = ns.get(ns.idFromName(JSON.stringify([this.account, this.room])));
    const response = await stub.fetch("https://test/__test", expire ? { method: "POST", body: expire } : {});
    return response.json();
  }
  async alarm(): Promise<void> {
    const ns = await mf.getDurableObjectNamespace("ROOMS");
    await ns.get(ns.idFromName(JSON.stringify([this.account, this.room]))).fetch("https://test/__alarm");
  }
  async evict(): Promise<void> {
    await mf.unsafeEvictDurableObject("relay-test", "Room", { name: JSON.stringify([this.account, this.room]), webSockets: "hibernate" });
  }
  frame(d: Device, ciphertext = b64(crypto.getRandomValues(new Uint8Array(24)))): RelayCiphertext {
    return { kind: "ciphertext", account_id: this.account, room_id: this.room, sender_device_id: d.device_id, ciphertext };
  }
}
async function pair() {
  const room = new RoomClient(), a = await device("desktop"), b = await device("phone");
  expect((await room.create(a)).status).toBe(201);
  const invite = await room.invite(a);
  expect((await room.join(b, invite)).status).toBe(201);
  return { room, a, b };
}
async function queued(room: RoomClient, count: number) {
  return waitState(room, state => state.queue.length === count);
}
async function waitState(room: RoomClient, check: (state: any) => boolean) {
  for (let attempt = 0; attempt < 100; attempt++) {
    const state = await room.inspect();
    if (check(state)) return state;
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  throw new Error("Synthetic queue did not reach expected count");
}

beforeAll(async () => {
  const bundled = await build({ entryPoints: [new URL("runtime-fixture.ts", import.meta.url).pathname], bundle: true,
    format: "esm", target: "es2022", platform: "browser", external: ["cloudflare:workers"], write: false, plugins: [mutationPlugin()] });
  // Only ephemeral synthetic keys, generated in memory; no credentials in files.
  const apnsKey = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  mf = new Miniflare(convertV4MiniflareOptions({ name: "relay-test", modules: true, script: bundled.outputFiles[0].text,
    compatibilityDate: "2026-07-01", durableObjects: {
      ROOMS: { className: "Room", useSQLite: true }, ADMISSION: { className: "Admission", useSQLite: true },
      WAKE: { className: "WakeProvider", useSQLite: true },
    }, bindings: { APNS_TEAM_ID: "SYNTHETIC", APNS_KEY_ID: "SYNTHETIC",
      APNS_TOPIC: "invalid.synthetic.app", APNS_PRIVATE_KEY: `-----BEGIN PRIVATE KEY-----\n${b64(await crypto.subtle.exportKey("pkcs8", apnsKey.privateKey))}\n-----END PRIVATE KEY-----` },
    log: new Log(LogLevel.ERROR),
    handleStructuredLogs(log) { runtimeOutput.push(log.message + "\n"); },
    async outboundService(request: MFRequest) {
      outbound.push({ url: request.url, headers: Object.fromEntries(request.headers), body: await request.text() });
      return new MFResponse(null, { status: 200 });
    },
  }));
  await mf.ready;
});
afterAll(async () => { await mf?.dispose(); });

describe("real local Durable Object relay", () => {
  it("review: creator cannot claim the archive writer before the enrolled phone", async () => {
    const { room, a, b } = await pair();
    const first = await block(room);
    const denied = await room.auth(a, "archive/append", first);
    expect(denied.status).toBe(403);
    expect((await denied.json() as any).error).toBe("archive_writer_mismatch");
    expect((await room.auth(b, "archive/append", first)).status).toBe(201);
    expect((await room.auth(a, "revoke", { device_id: b.device_id })).status).toBe(200);
    expect((await room.join(b, await room.invite(a))).status).toBe(201);
    expect((await room.auth(b, "archive/append", await block(room, 1, first.block_hash))).status).toBe(201);
  });
  it("review: only an old-writer-signed handoff can replace the phone key", async () => {
    const { room, a, b } = await pair(), replacement = await device("replacement-phone");
    expect((await room.join(replacement, await room.invite(a))).status).toBe(201);
    const message = JSON.stringify(["voiceremote-audit-writer-v1", room.account, room.room, b.public_key,
      replacement.device_id, replacement.public_key, 0]);
    const value = { account_id: room.account, room_id: room.room, device_id: replacement.device_id,
      public_key: replacement.public_key, revision: 0, old_signature: await sign(a, message) };
    expect((await room.auth(a, "archive/writer", value)).status).toBe(403);
    value.old_signature = await sign(b, message);
    expect((await room.auth(replacement, "archive/writer", value)).status).toBe(200);
    expect((await room.auth(b, "archive/append", await block(room))).status).toBe(403);
    expect((await room.auth(replacement, "archive/append", await block(room))).status).toBe(201);
    expect((await room.auth(replacement, "archive/writer", value)).status).toBe(403);
  });
  it("review: deletes memberless rooms and expires inactive archives", async () => {
    const { room, a, b } = await pair();
    expect((await room.auth(b, "archive/append", await block(room))).status).toBe(201);
    expect((await room.auth(a, "revoke", { device_id: b.device_id })).status).toBe(200);
    expect((await room.auth(a, "revoke", { device_id: a.device_id })).status).toBe(200);
    expect((await room.inspectAll()).sql).toEqual({});
    const other = await pair();
    expect((await other.room.auth(other.b, "archive/append", await block(other.room))).status).toBe(201);
    await other.room.inspect("archiveExpired"); await other.room.alarm();
    expect((await other.room.inspectAll()).sql).toEqual({});
  });
  it("review: a signed epoch checkpoint releases archive_full without allowing stale writes", async () => {
    const { room, a, b } = await pair();
    let previous = "0".repeat(64);
    for (let sequence = 0; sequence < 128; sequence++) {
      const next = await block(room, sequence, previous);
      expect((await room.auth(b, "archive/append", next)).status).toBe(201); previous = next.block_hash;
    }
    const full = await room.auth(b, "archive/append", await block(room, 128, previous));
    expect((await full.json() as any).error).toBe("archive_full");
    const unsigned = { ...await block(room, 0, previous, "A".repeat(100_000)), epoch: 1 };
    const checkpoint = { ...unsigned, block_hash: await archiveHash(unsigned) };
    expect((await room.auth(b, "archive/checkpoint", checkpoint)).status).toBe(201);
    expect((await room.auth(b, "archive/checkpoint", checkpoint)).status).toBe(201);
    expect((await room.auth(a, "archive/checkpoint", checkpoint)).status).toBe(403);
    const rows = (await room.inspectAll()).sql.audit_archive;
    expect(rows).toHaveLength(1);
    const page = await (await room.auth(b, "archive/read", { account_id: room.account, room_id: room.room, epoch: 1, sequence: 0 })).json() as any;
    expect(page.epoch).toBe(1); expect(page.blocks).toEqual([checkpoint]);
    const nextUnsigned = { ...await block(room, 1, checkpoint.block_hash), epoch: 1 };
    const next = { ...nextUnsigned, block_hash: await archiveHash(nextUnsigned) };
    expect((await room.auth(b, "archive/append", next)).status).toBe(201);
    expect((await room.auth(b, "archive/checkpoint", checkpoint)).status).toBe(201);
    expect((await room.inspectAll()).sql.audit_archive).toHaveLength(2);

    expect((await room.auth(b, "archive/append", await block(room, 1, checkpoint.block_hash))).status).toBe(409);
  }, 30_000);
  async function block(room: RoomClient, sequence = 0, previous_hash = "0".repeat(64), ciphertext = b64(crypto.getRandomValues(new Uint8Array(30)))): Promise<AuditArchiveBlock> {
    const value = { account_id: room.account, room_id: room.room, sequence, previous_hash, ciphertext };
    return { ...value, epoch: 0, block_hash: await archiveHash(value) };
  }
  it("archives only endpoint-sealed bytes, survives eviction and refuses nonmembers and altered proofs", async () => {
    const { room, a, b } = await pair(), outsider = await device("outsider");
    const key = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
    const marker = "SYNTHETIC-AUDIT-PRIVATE-METADATA";
    const nonce = crypto.getRandomValues(new Uint8Array(12));
    const sealed = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, key, new TextEncoder().encode(marker)));
    const first = await block(room, 0, "0".repeat(64), b64(new Uint8Array([...nonce, ...sealed])));
    expect((await room.post("archive/append", first)).status).toBe(403);
    expect((await room.post("archive/read", { account_id: room.account, room_id: room.room, sequence: 0 })).status).toBe(403);
    const challenge = JSON.stringify({ device_id: outsider.device_id, operation: "archive/read", body_sha256: await hash("") });
    expect((await room.post("challenge", challenge, { "x-relay-signature": await sign(outsider,
      JSON.stringify(["voiceremote-relay-challenge-v1", room.account, room.room, await hash(challenge)])) })).status).toBe(403);
    expect((await room.auth(b, "archive/append", first)).status).toBe(201);
    expect((await room.auth(b, "archive/append", first)).status).toBe(201);
    // A fresh signature binds these differently ordered transport bytes, while
    // logical idempotency still compares the same closed block fields.
    const reordered = Object.fromEntries(Object.entries(first).reverse());
    expect((await room.auth(b, "archive/append", reordered)).status).toBe(201);
    expect((await room.auth(a, "archive/append", first)).status).toBe(403);
    expect(JSON.stringify(await room.inspectAll())).not.toContain(marker);
    expect(runtimeOutput.join("")).not.toContain(first.ciphertext);
    await room.evict();
    const query = { account_id: room.account, room_id: room.room, sequence: 0 };
    const page = await (await room.auth(a, "archive/read", query)).json() as any;
    expect(page.blocks).toEqual([first]);
    const encrypted = Buffer.from(page.blocks[0].ciphertext, "base64");
    expect(new TextDecoder().decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv: encrypted.subarray(0, 12) }, key, encrypted.subarray(12)))).toBe(marker);
    const changed = await block(room, 0);
    expect((await room.auth(b, "archive/append", changed)).status).toBe(409);
    expect((await room.auth(b, "archive/append", await block(room, 2, first.block_hash))).status).toBe(409);
    expect((await room.auth(b, "archive/append", await block(room, 1))).status).toBe(409);
    expect((await room.auth(b, "archive/append", { ...await block(room, 1, first.block_hash), block_hash: "1".repeat(64) })).status).toBe(400);
    const next = await block(room, 1, first.block_hash), raw = JSON.stringify(next);
    const proof = await room.proof(b, "archive/append", raw);
    expect((await room.post("archive/append", JSON.stringify({ ...next, ciphertext: "A".repeat(40) }), proof)).status).toBe(403);
    expect((await room.post("archive/append", raw, proof)).status).toBe(403);
    expect((await room.auth(a, "revoke", { device_id: b.device_id })).status).toBe(200);
    expect((await room.post("archive/read", query, proof)).status).toBe(403);
    // Reenrollment with the same device id cannot inherit the old archive writer.
    const replacement = await device(b.device_id);
    expect((await room.join(replacement, await room.invite(a))).status).toBe(201);
    expect((await room.auth(replacement, "archive/append", next)).status).toBe(403);
    expect((await (await room.auth(a, "archive/read", query)).json() as any).blocks).toEqual([first]);
  });
  it("bounds archive count and bytes without eviction, pages eight blocks and retries at capacity", async () => {
    for (const large of [false, true]) {
      const { room, b } = await pair();
      let previous = "0".repeat(64), last: AuditArchiveBlock | undefined, accepted = 0;
      for (let sequence = 0; sequence <= ARCHIVE_LIMITS.blocks; sequence++) {
        const next = await block(room, sequence, previous, large ? "A".repeat(65_536) : "A".repeat(40));
        const response = await room.auth(b, "archive/append", next);
        if (response.status === 409) { expect((await response.json() as any).error).toBe("archive_full"); break; }
        expect(response.status).toBe(201); accepted++; previous = next.block_hash; last = next;
      }
      expect(accepted).toBe(large ? 31 : 128);
      expect((await room.auth(b, "archive/append", last!)).status).toBe(201);
      const stored = (await room.inspectAll()).sql.audit_archive;
      expect(stored.length).toBe(accepted);
      expect(stored.reduce((n: number, row: any) => n + row.bytes, 0)).toBeLessThanOrEqual(ARCHIVE_LIMITS.bytes);
      const page = await (await room.auth(b, "archive/read", { account_id: room.account, room_id: room.room, sequence: 0 })).json() as any;
      expect(page.blocks).toHaveLength(8); expect(page.blocks[0].sequence).toBe(0);
      expect(page.blocks[7].sequence).toBe(7);
      expect((await room.auth(b, "archive/append", { ...last!, plaintext: "SYNTHETIC-REJECT" })).status).toBe(400);
      expect((await room.post("archive/append", "x".repeat(ARCHIVE_LIMITS.bodyBytes + 1))).status).toBe(413);
    }
  }, 30_000);

  it("a failed join to an unknown room allocates no persistent application tables", async () => {
    const room = new RoomClient(); expect((await room.post("join", {})).status).toBe(403);
    const stored = await room.inspectAll(); expect(stored.kv).toEqual({}); expect(stored.sql).toEqual({});
  });
  it("deletes unpaired rooms at the last invite deadline using the real alarm handler", async () => {
    const room = new RoomClient(), a = await device("a");
    expect((await room.create(a)).status).toBe(201);
    await room.invite(a);
    await room.evict(); await room.inspect("orphan"); await room.alarm();
    expect((await room.inspectAll()).room).toBeUndefined();
    expect((await room.inspectAll()).kv).toEqual({});
    expect((await room.create(a)).status).toBe(201);
  });
  it("denies an in-flight frame after membership removal before a close can arrive", async () => {
    const { room, a, b } = await pair(), sa = await room.connect(a), sb = await room.connect(b);
    await room.inspect("remove:" + b.device_id);
    const frame = room.frame(b); sb.send(frame);
    await sb.until(() => !!sb.closed || sa.inbox.some(f => f.kind === "ciphertext"));
    expect(sb.closed?.code).toBe(1008);
    expect(sa.inbox.filter(f => f.kind === "ciphertext")).toHaveLength(0);
    expect((await room.inspect()).queue).toHaveLength(0); await sa.close();
  });
  it("denies a frame with a stale enrollment generation on an otherwise live socket", async () => {
    const { room, a, b } = await pair(), sa = await room.connect(a), sb = await room.connect(b);
    await room.inspect("generation:" + b.device_id); sb.send(room.frame(b));
    await sb.until(() => !!sb.closed || sa.inbox.some(f => f.kind === "ciphertext"));
    expect(sb.closed?.code).toBe(1008); expect(sa.inbox.filter(f => f.kind === "ciphertext")).toHaveLength(0); await sa.close();
  });
  it("purges actual queued frames both sent by and addressed to a revoked member", async () => {
    const { room, a, b } = await pair(), c = await device("c");
    expect((await room.join(c, await room.invite(a))).status).toBe(201);
    const sa = await room.connect(a), sb = await room.connect(b);
    sb.send(room.frame(b)); await sa.next("ciphertext"); await queued(room, 1);
    await sb.close(); sa.send(room.frame(a)); await queued(room, 3);
    expect((await room.auth(a, "revoke", { device_id: b.device_id })).status).toBe(200);
    const rows = (await room.inspect()).queue;
    expect(rows).toHaveLength(1); expect(rows[0].target).toBe(c.device_id); expect(rows[0].sender).toBe(a.device_id); await sa.close();
  });
  it("schema-closed ciphertext rejects plaintext fields and logs only metadata counts", async () => {
    const { room, a, b } = await pair(), sb = await room.connect(b);
    const marker = "SYNTHETIC-REJECTED-INNER-TEXT-9248";
    for (const field of ["text", "transcript", "inner_payload", "payload"]) {
      const sa = await room.connect(a);
      sa.send({ ...room.frame(a), [field]: marker });
      await sa.until(() => !!sa.closed || sb.inbox.some(f => f.kind === "ciphertext"));
      expect(sa.closed?.code).toBe(1008); expect(sb.inbox.filter(f => f.kind === "ciphertext")).toHaveLength(0);
      expect(JSON.stringify(await room.inspectAll())).not.toContain(marker);
    }
    const sa = await room.connect(a), frame = room.frame(a); sa.send(frame); expect(await sb.next("ciphertext")).toEqual(frame);
    await new Promise(resolve => setTimeout(resolve, 25));
    const logged = runtimeOutput.join(""); expect(logged).not.toContain(marker); expect(logged).not.toContain(frame.ciphertext);
    for (const line of logged.split("\n").filter(line => line.startsWith("{"))) {
      expect(Object.keys(JSON.parse(line)).sort()).toEqual(["bytes", "count", "event"]);
    }
    await sa.close(); await sb.close();
  });
  it("creates a self-signed first-pair room without knowing the phone key", async () => {
    const room = new RoomClient("create", Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString("hex"));
    const desktop = await device("desktop");
    const raw = JSON.stringify({ device_id: desktop.device_id, public_key: desktop.public_key });
    const response = await room.post("create", raw, { "x-relay-signature": await sign(desktop,
      JSON.stringify(["voiceremote-relay-create-v1", room.account, room.room, await hash(raw)])) });
    expect(response.status).toBe(201);
    const socket = await room.connect(desktop);
    const token = b64(crypto.getRandomValues(new Uint8Array(32))), expires = Date.now() + 120_000;
    const registered = await room.auth(desktop, "invite", { token_sha256: await hash(token), expires_at: expires });
    expect(registered.status).toBe(201);
    await room.evict();
    const phone = await device("new-phone");
    expect((await room.join(phone, { one_use_token: token, expires_at: expires })).status).toBe(201);
    await socket.close();
  });
  it("requires the optional provision bearer in addition to the creator signature", async () => {
    const room = new RoomClient(), d = await device("desktop");
    const raw = JSON.stringify({ device_id: d.device_id, public_key: d.public_key });
    const headers = { "x-test-provision": "true", "x-relay-signature": await sign(d,
      JSON.stringify(["voiceremote-relay-create-v1", room.account, room.room, await hash(raw)])) };
    expect((await room.post("create", raw, headers)).status).toBe(403);
    expect((await room.post("create", raw, { ...headers, authorization: "Bearer WRONG" })).status).toBe(403);
    expect((await room.post("create", raw, { ...headers, authorization: `Bearer ${provisionSecret}` })).status).toBe(201);
  });
  it("atomically binds exactly one newly supplied key when two phones redeem one QR", async () => {
    const room = new RoomClient(), desktop = await device("desktop"); expect((await room.create(desktop)).status).toBe(201);
    const invite = await room.invite(desktop);
    const pending = await room.inspect();
    expect(pending.invites[0].digest).toBe(await hash(invite.one_use_token));
    expect(JSON.stringify(await room.inspectAll())).not.toContain(invite.one_use_token);
    const first = await device("first-phone"), second = await device("second-phone");
    const result = await Promise.all([room.join(first, invite), room.join(second, invite)]);
    expect(result.map(r => r.status).sort()).toEqual([201, 403]);
    expect((await room.inspect()).members).toHaveLength(2);
  });
  it("closes a revoked socket that has never sent, including after hibernation", async () => {
    const { room, a, b } = await pair();
    const sa = await room.connect(a);
    const base = await mf.ready;
    const url = new URL(room.path("connect").replace("https://relay.test", base.origin)); url.protocol = "ws:";
    const native = new WebSocket(url, { headers: { ...await room.proof(b, "connect"), "CF-Connecting-IP": room.ip } });
    await once(native, "open");
    const closed = once(native, "close");
    await room.evict();
    expect((await room.auth(a, "revoke", { device_id: b.device_id })).status).toBe(200);
    const result = await Promise.race([closed, new Promise<undefined>(resolve => setTimeout(resolve, 1500))]);
    if (!result) native.terminate();
    expect(result?.[0]).toBe(1008); await sa.close();
  });
  it("keeps live fanout moving when another member queue overflows", async () => {
    const { room, a, b } = await pair(), c = await device("offline");
    expect((await room.join(c, await room.invite(a))).status).toBe(201);
    const sa = await room.connect(a), sb = await room.connect(b);
    for (let i = 0; i < 33; i++) sa.send(room.frame(a, b64(new TextEncoder().encode(`SYNTHETIC-${i}`))));
    await sb.until(() => !!sa.closed || sb.inbox.filter(f => f.kind === "ciphertext").length === 33);
    expect(sa.closed).toBeUndefined(); expect(sb.inbox.filter(f => f.kind === "ciphertext")).toHaveLength(33);
    await sa.close(); const reconnected = await room.connect(a); reconnected.send(room.frame(a));
    await sb.until(() => !!reconnected.closed || sb.inbox.filter(f => f.kind === "ciphertext").length === 34);
    expect(reconnected.closed).toBeUndefined(); expect(sb.inbox.filter(f => f.kind === "ciphertext")).toHaveLength(34);
    await reconnected.close(); await sb.close();
  });
  it("junk joins cannot prevent a valid token redemption", async () => {
    const { room, a } = await pair(), target = await device("target");
    const invite = await room.invite(a);
    for (let i = 0; i < 59; i++) await room.post("join", {}, { "CF-Connecting-IP": "198.18.0.55" });
    expect((await room.join(target, invite)).status).toBe(201);
  });
  it("limits creation by IPv6 /64 rather than individual addresses", async () => {
    const desktop = await device("desktop");
    for (let i = 0; i <= LIMITS.attemptsPerMinute; i++) {
      const room = new RoomClient(`ipv6-${i}`);
      const raw = JSON.stringify({ device_id: desktop.device_id, public_key: desktop.public_key });
      const response = await room.post("create", raw, { "CF-Connecting-IP": `2001:db8:abcd:1234::${i.toString(16)}`,
        "x-relay-signature": await sign(desktop, JSON.stringify(["voiceremote-relay-create-v1", room.account, room.room, await hash(raw)])) });
      expect(response.status).toBe(i === LIMITS.attemptsPerMinute ? 429 : 201);
    }
  });
  it("carries maximum-length legal dictation after encryption and base64", async () => {
    const { room, a, b } = await pair();
    const sa = await room.connect(a), sb = await room.connect(b);
    const inner = JSON.stringify({ kind: "dictation_text", account_id: room.account, segment_id: "s", revision: 0,
      state: "committed", target_device_id: b.device_id, text: "🚀".repeat(16_384) });
    const size = new TextEncoder().encode(inner).length;
    const frame = room.frame(a, b64(new Uint8Array(size + 2 * 18)));
    sa.send(frame);
    await sb.until(() => !!sa.closed || sb.inbox.some(f => f.kind === "ciphertext"));
    expect(sa.closed).toBeUndefined(); expect(await sb.next("ciphertext")).toEqual(frame);
    await sa.close(); await sb.close();
  });
  it("a slow unauthenticated upload cannot hold the room lock against revoke", async () => {
    const { room, a, b } = await pair();
    const raw = JSON.stringify({ device_id: b.device_id });
    const proof = await room.proof(a, "revoke", raw);
    let streamController!: ReadableStreamDefaultController<Uint8Array>;
    const stream = new ReadableStream<Uint8Array>({ start(c) { streamController = c; c.enqueue(new TextEncoder().encode("{")); } });
    const pending = mf.dispatchFetch(room.path("join"), { method: "POST", body: stream,
      headers: { "CF-Connecting-IP": room.ip }, duplex: "half" } as any);
    await new Promise(resolve => setTimeout(resolve, 50));
    let response;
    try {
      response = await Promise.race([room.post("revoke", raw, proof), new Promise<undefined>(resolve => setTimeout(resolve, 1000))]);
    } finally { streamController.close(); await pending; }
    expect(response?.status).toBe(200);
  });
  it("exchanges endpoint-encrypted frames both ways and survives hibernation", async () => {
    const { room, a, b } = await pair();
    const key = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
    const marker = "SYNTHETIC-INNER-PLAINTEXT-ONLY-9c652a";
    const inner = JSON.stringify({ kind: "dictation_text", account_id: room.account, segment_id: "s", revision: 0,
      state: "committed", target_device_id: b.device_id, text: marker });
    const nonce = crypto.getRandomValues(new Uint8Array(12));
    const sealed = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, key, new TextEncoder().encode(inner)));
    const frame = room.frame(a, b64(new Uint8Array([...nonce, ...sealed])));
    const sa = await room.connect(a);
    sa.send(frame);
    const state = await queued(room, 1);
    expect(state.queue[0].frame).toBe(JSON.stringify(frame));
    const sb = await room.connect(b);
    const received = await sb.next("ciphertext");
    expect(received).toEqual(frame);
    if (received.kind !== "ciphertext") throw new Error("unexpected frame");
    const bytes = Buffer.from(received.ciphertext, "base64");
    expect(new TextDecoder().decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv: bytes.subarray(0, 12) }, key, bytes.subarray(12)))).toBe(inner);
    await room.evict();
    const reply = room.frame(b); sb.send(reply);
    expect(await sa.next("ciphertext")).toEqual(reply);
    expect((await room.inspect()).queue).toHaveLength(0);
    expect(runtimeOutput.join("")).toContain('"event":"accepted"');
    expect(runtimeOutput.join("")).not.toContain(frame.ciphertext);
    // Logs are allowlisted event names and numeric counts only.
    for (const line of runtimeOutput.join("").split("\n").filter(line => line.startsWith('{"event":'))) {
      expect(Object.keys(JSON.parse(line)).sort()).toEqual(["bytes", "count", "event"]);
    }
    await sa.close(); await sb.close();
  });

  it("rejects expired, replayed, wrong-key and wrong-account join tokens", async () => {
    const room = new RoomClient(), a = await device("a"), b = await device("b");
    expect((await room.create(a)).status).toBe(201);
    const invite = await room.invite(a);
    const other = new RoomClient("other-account", room.room);
    expect((await other.join(b, invite)).status).toBe(403);
    const wrong = { ...await device("b"), public_key: b.public_key };
    expect((await room.join(wrong, invite)).status).toBe(403);
    expect((await room.join(b, invite)).status).toBe(201);
    expect((await room.join(b, invite)).status).toBe(403);
    const c = await device("c"), stale = await room.invite(a);
    await room.inspect("invites");
    expect((await room.join(c, stale)).status).toBe(403);
    const fresh = await room.invite(a);
    await room.evict();
    expect((await room.join(c, fresh)).status).toBe(201);
  });

  it("revoke deletes membership/key, sockets, registrations, invites and queued frames; next frame is blocked", async () => {
    const { room, a, b } = await pair();
    const c = await device("third"), pending = await room.invite(b);
    const sa = await room.connect(a), sb = await room.connect(b);
    sb.send({ kind: "wake_registration", account_id: room.account, room_id: room.room, sender_device_id: b.device_id,
      apns_wake_token: b64(new Uint8Array(32)), environment: "sandbox" });
    const proof = await room.proof(b, "connect");
    const before = room.frame(b); sb.send(before); expect(await sa.next("ciphertext")).toEqual(before);
    expect((await room.auth(a, "revoke", { device_id: b.device_id })).status).toBe(200);
    await sb.until(() => !!sb.closed);
    expect(sb.closed?.code).toBe(1008);
    // Native socket may already be closed; either transport rejection or no routing.
    try { sb.send(room.frame(b)); } catch { /* revoked transport */ }
    const state = await room.inspect();
    expect(state.members.some((m: any) => m.device === b.device_id)).toBe(false);
    expect(JSON.stringify(state.members)).not.toContain(b.public_key);
    expect(state.archiveWriterKey).toBe(b.public_key); // Public verification tombstone, not transport membership.
    expect(state.queue).toHaveLength(0);
    expect((await room.post("challenge", { device_id: b.device_id, operation: "connect", body_sha256: await hash("") })).status).toBe(403);
    expect((await mf.dispatchFetch(room.path("connect"), { headers: { upgrade: "websocket", "CF-Connecting-IP": room.ip, ...proof } })).status).toBe(403);
    expect((await room.join(c, pending)).status).toBe(403);
    const active = room.frame(a); sa.send(active);
    await queued(room, 0);
    expect(sa.inbox.filter(f => f.kind === "ciphertext")).toHaveLength(0);
    await sa.close();
  });

  it("drops oldest only for the overflowing member and reports/reset drops at reconnect", async () => {
    const { room, a, b } = await pair();
    const sa = await room.connect(a);
    const frame = room.frame(a);
    for (let i = 0; i < LIMITS.queueCount; i++) sa.send(frame);
    await queued(room, LIMITS.queueCount);
    const newest = room.frame(a); sa.send(newest);
    await waitState(room, state => state.queue.at(-1)?.frame === JSON.stringify(newest));
    expect(sa.closed).toBeUndefined();
    const sb = await room.connect(b);
    expect(sb.dropped).toBe(1);
    for (let i = 0; i < LIMITS.queueCount - 1; i++) expect(await sb.next("ciphertext")).toEqual(frame);
    expect(await sb.next("ciphertext")).toEqual(newest);
    expect((await room.inspect()).queue).toHaveLength(0);
    await sb.close(); const again = await room.connect(b); expect(again.dropped).toBe(0);
    await sa.close(); await again.close();
  });

  it("bounds queue bytes and removes expired ciphertext before replay", async () => {
    const { room, a, b } = await pair();
    const sa = await room.connect(a), frame = room.frame(a, b64(new Uint8Array(786_432)));
    sa.send(frame); sa.send(frame); await queued(room, 2);
    sa.send(frame); await waitState(room, state => state.drops.some((d: any) => d.target === b.device_id && d.count === 1));
    expect(sa.closed).toBeUndefined();
    expect((await room.inspect()).queue.reduce((s: number, q: any) => s + q.bytes, 0)).toBeLessThanOrEqual(LIMITS.queueBytes);
    await room.inspect("queue");
    const sb = await room.connect(b);
    expect((await room.inspect()).queue).toHaveLength(0);
    await sa.close();
    const check = room.frame(b); sb.send(check);
    // The replayed queue is gone; a round trip confirms earlier socket delivery.
    const back = await room.connect(a);
    expect(await back.next("ciphertext")).toEqual(check);
    const answer = room.frame(a); back.send(answer);
    expect(await sb.next("ciphertext")).toEqual(answer);
    expect(sb.inbox.filter(f => f.kind === "ciphertext")).toHaveLength(0);
    await back.close(); await sb.close();
  });

  it("rejects oversize, binary, spoofed sender/account/room and plaintext-shaped frames", async () => {
    for (const kind of ["oversize", "binary", "sender", "account", "room", "inner", "extra"]) {
      const { room, a, b } = await pair(), sa = await room.connect(a);
      const frame = room.frame(a) as any;
      if (kind === "oversize") frame.ciphertext = b64(new Uint8Array(LIMITS.frameBytes));
      if (kind === "sender") frame.sender_device_id = b.device_id;
      if (kind === "account") frame.account_id = "another";
      if (kind === "room") frame.room_id = "another";
      if (kind === "inner") frame.kind = "dictation_text";
      if (kind === "extra") frame.text = "SYNTHETIC-REJECTED-PLAINTEXT";
      if (kind === "binary") sa.socket.send(new Uint8Array(8)); else sa.send(frame);
      await sa.until(() => !!sa.closed);
      expect(sa.closed?.code).toBe(kind === "oversize" ? 1009 : 1008);
      expect((await room.inspect()).queue).toHaveLength(0);
    }
    expect(runtimeOutput.join("")).not.toContain("SYNTHETIC-REJECTED-PLAINTEXT");
  });

  it("binds single-use challenge signatures to the body, operation, device and room", async () => {
    const { room, a, b } = await pair();
    const raw = JSON.stringify({ device_id: b.device_id });
    const proof = await room.proof(a, "revoke", raw);
    expect((await room.post("revoke", { device_id: a.device_id }, proof)).status).toBe(403);
    expect((await room.post("revoke", raw, proof)).status).toBe(403);
    const second = await room.proof(a, "revoke", raw);
    expect((await room.post("invite", raw, second)).status).toBe(403);
    const third = await room.proof(a, "revoke", raw);
    expect((await room.post("revoke", raw, { ...third, "x-relay-signature": await sign(b, "wrong") })).status).toBe(403);
    const expired = await room.proof(a, "revoke", raw);
    await room.inspect("challenges");
    expect((await room.post("revoke", raw, expired)).status).toBe(403);
    const another = new RoomClient(room.account);
    expect((await another.create(a)).status).toBe(201);
    const cross = await room.proof(a, "revoke", raw);
    expect((await another.post("revoke", raw, cross)).status).toBe(403);
    expect((await room.inspect()).members).toHaveLength(2);
  });

  it("any signed member may remove another; unsigned creation and malformed JSON are rejected", async () => {
    const room = new RoomClient(), a = await device("a"), b = await device("b");
    expect((await room.post("create", { device_id: a.device_id, public_key: a.public_key })).status).toBe(403);
    expect((await room.create(a)).status).toBe(201);
    expect((await room.create(b)).status).toBe(409);
    const invite = await room.invite(a); expect((await room.join(b, invite)).status).toBe(201);
    expect((await room.auth(b, "revoke", { device_id: a.device_id })).status).toBe(200);
    expect((await room.post("challenge", '{"device_id":"a","device_id":"b"}')).status).toBe(400);
    expect((await room.post("join", "x".repeat(LIMITS.controlBytes + 1))).status).toBe(413);
    await room.inspect("rollback");
    expect((await room.post("challenge", { device_id: a.device_id, operation: "connect", body_sha256: await hash("") })).status).toBe(503);
  });

  it("counts only mismatched joins per source/room and never blocks a valid token", async () => {
    const source = `198.51.100.${++serial}`;
    const { room, a } = await pair();
    const c = await device("c"), invite = await room.invite(a);
    let response;
    for (let i = 0; i <= LIMITS.attemptsPerMinute; i++) {
      response = await room.post("join", {}, { "CF-Connecting-IP": source });
      expect(response.status).toBe(i < LIMITS.attemptsPerMinute ? 403 : 429);
    }
    const other = new RoomClient(); expect((await other.post("join", {}, { "CF-Connecting-IP": source })).status).toBe(403);
    const original = room.ip; Object.defineProperty(room, "ip", { value: source, configurable: true });
    expect((await room.join(c, invite)).status).toBe(201);
    Object.defineProperty(room, "ip", { value: original });
  });

  it("unauthenticated joins and challenge requests cannot exhaust device control capacity", async () => {
    const { room, a, b } = await pair();
    const raw = JSON.stringify({ device_id: a.device_id, operation: "connect", body_sha256: await hash("") });
    for (let i = 0; i < 3; i++) expect((await room.post("challenge", raw)).status).toBe(403);
    expect((await room.post("challenge", raw, { "x-relay-signature": await sign(b,
      JSON.stringify(["voiceremote-relay-challenge-v1", room.account, room.room, await hash(raw)])) })).status).toBe(403);
    expect((await room.inspect()).challenges).toHaveLength(0);
    const first = await room.proof(a, "connect");
    await room.proof(a, "connect");
    const third = await room.post("challenge", raw, { "x-relay-signature": await sign(a,
      JSON.stringify(["voiceremote-relay-challenge-v1", room.account, room.room, await hash(raw)])) });
    expect(third.status).toBe(429);
    // A different member retains its own challenge capacity.
    await room.proof(b, "connect");
    for (let i = 0; i < LIMITS.attemptsPerMinute; i++) {
      expect((await room.post("join", {}, { "CF-Connecting-IP": "203.0.113.60" })).status).toBe(403);
    }
    expect((await room.post("join", {}, { "CF-Connecting-IP": "203.0.113.60" })).status).toBe(429);
    const response = await mf.dispatchFetch(room.path("connect"), { headers: {
      "CF-Connecting-IP": room.ip, upgrade: "websocket", ...first,
    } });
    expect(response.status).toBe(101);
    const socket = new Socket(response.webSocket!); await socket.close();
  });

  it("sends only fixed APNs wake metadata, coalesces repeated queued frames", async () => {
    const { room, a, b } = await pair(), sb = await room.connect(b);
    const start = outbound.length;
    const token = b64(crypto.getRandomValues(new Uint8Array(32)));
    sb.send({ kind: "wake_registration", account_id: room.account, room_id: room.room, sender_device_id: b.device_id,
      apns_wake_token: token, environment: "sandbox" });
    await sb.close();
    const sa = await room.connect(a); sa.send(room.frame(a)); sa.send(room.frame(a));
    await queued(room, 2);
    await sa.until(() => outbound.length > start);
    const push = outbound[start];
    expect(push.url).toBe(`https://api.sandbox.push.apple.com/3/device/${Buffer.from(token, "base64").toString("hex")}`);
    expect(push.body).toBe('{"aps":{"content-available":1}}');
    expect(push.headers["apns-push-type"]).toBe("background"); expect(push.headers["apns-priority"]).toBe("5");
    expect(push.headers.authorization).toMatch(/^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
    expect(outbound).toHaveLength(start + 1);
    expect(runtimeOutput.join("")).not.toContain(token);
    await mf.unsafeEvictDurableObject("relay-test", "WakeProvider", { name: "apns" });
    const other = await pair(), phone = await other.room.connect(other.b);
    phone.send({ kind: "wake_registration", account_id: other.room.account, room_id: other.room.room,
      sender_device_id: other.b.device_id, apns_wake_token: token, environment: "sandbox" });
    await phone.close(); const desktop = await other.room.connect(other.a); desktop.send(other.room.frame(other.a));
    await desktop.until(() => outbound.length === start + 2);
    expect(outbound[start + 1].headers.authorization).toBe(push.headers.authorization);
    await desktop.close();
    await sa.close();
  });
});
