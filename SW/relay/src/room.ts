import { DurableObject } from "cloudflare:workers";
import type { RelayPresence } from "./protocol/generated.js";
import { decodeFrame, encodeFrame } from "./codec.js";
import { parseControl } from "./control.js";
import { CiphertextQueue } from "./queue.js";
import type { WakeRegistration } from "./apns.js";
import type { Env } from "./worker.js";
import { body, failure, hash, id, json, LIMITS, metric, publicKey, randomToken,
  record, Refusal, requireThat, unbase64, utf8, verify } from "./security.js";

interface Member { device: string; key: string; generation: string; wake?: WakeRegistration; lastWake?: number }
interface Invite { digest: string; issuer: string; expires: number }
interface Challenge { nonce: string; device: string; operation: string; digest: string; expires: number; message: string }
interface State {
  account: string; room: string; members: Member[]; invites: Invite[]; usedInvites: Invite[];
  challenges: Challenge[]; highWater: number; paired: boolean; orphanExpires: number;
}
interface Attachment { device: string; generation: string }

export class Room extends DurableObject<Env> {
  protected readonly queue: CiphertextQueue;
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.queue = new CiphertextQueue(ctx.storage.sql);
  }
  protected stored(): State | undefined {
    if (!this.ctx.storage.sql.exec("SELECT name FROM sqlite_master WHERE name = 'metadata'").toArray().length) return undefined;
    const row = this.ctx.storage.sql.exec<{ value: string }>("SELECT value FROM metadata WHERE key = 'room'").toArray()[0];
    return row ? JSON.parse(row.value) as State : undefined;
  }
  protected write(state: State): void {
    this.ctx.storage.sql.exec("INSERT INTO metadata(key, value) VALUES ('room', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", JSON.stringify(state));
  }
  async fetch(request: Request): Promise<Response> {
    let raw: string;
    try { raw = request.method === "GET" ? "" : await body(request); }
    catch (error) { metric("rejected"); return failure(error); }
    return this.ctx.blockConcurrencyWhile(async () => {
      try { return await this.handle(request, raw); }
      catch (error) {
        metric("rejected"); const response = failure(error);
        if (error instanceof Refusal && error.code === "invalid_join_token") response.headers.set("x-relay-token-mismatch", "1");
        return response;
      }
    });
  }
  private async load(join = false): Promise<State> {
    const state = this.stored(); requireThat(state, 403, join ? "invalid_join_token" : "forbidden");
    const now = Date.now();
    requireThat(Number.isSafeInteger(now) && now > 0 && now >= state.highWater, 503, "clock_unavailable");
    if (!state.paired && state.orphanExpires <= now) {
      await this.destroy(); throw new Refusal(403, join ? "invalid_join_token" : "forbidden");
    }
    state.highWater = now;
    state.invites = state.invites.filter(i => i.expires > now);
    state.usedInvites = state.usedInvites.filter(i => i.expires > now);
    state.challenges = state.challenges.filter(c => c.expires > now); this.queue.expire(now);
    return state;
  }
  private async destroy(): Promise<void> {
    for (const socket of this.ctx.getWebSockets()) this.close(socket, "room_expired");
    await this.ctx.storage.deleteAll();
  }
  private async save(state: State): Promise<void> {
    this.write(state);
    const deadlines = [...state.invites, ...state.usedInvites, ...state.challenges].map(x => x.expires);
    const queueDeadline = this.queue.deadline(); if (queueDeadline !== undefined) deadlines.push(queueDeadline);
    if (!state.paired) deadlines.push(state.orphanExpires);
    if (deadlines.length) await this.ctx.storage.setAlarm(Math.min(...deadlines)); else await this.ctx.storage.deleteAlarm();
  }
  private member(state: State, device: unknown): Member {
    const member = state.members.find(m => m.device === device); requireThat(member, 403, "forbidden"); return member;
  }
  private async authenticate(state: State, request: Request, operation: string, raw: string): Promise<Member> {
    const index = state.challenges.findIndex(c => c.nonce === request.headers.get("x-relay-challenge")); requireThat(index >= 0, 403, "forbidden");
    const [challenge] = state.challenges.splice(index, 1); await this.save(state);
    const member = this.member(state, challenge.device);
    requireThat(challenge.operation === operation && challenge.digest === await hash(raw), 403, "forbidden");
    requireThat(await verify(member.key, request.headers.get("x-relay-signature"), challenge.message)
      && challenge.expires > Date.now(), 403, "forbidden"); return member;
  }
  private async handle(request: Request, raw: string): Promise<Response> {
    const parts = new URL(request.url).pathname.split("/");
    const account = parts[3], room = parts[5], operation = parts[6];
    if (operation === "create") {
      const value = parseControl(raw); record(value, ["device_id", "public_key"]); id(value.device_id); await publicKey(value.public_key);
      requireThat(await verify(value.public_key as string, request.headers.get("x-relay-signature"),
        JSON.stringify(["voiceremote-relay-create-v1", account, room, await hash(raw)])), 403, "forbidden");
      const existing = this.stored(); if (existing && !existing.paired && existing.orphanExpires <= Date.now()) await this.destroy();
      requireThat(!this.stored(), 409, "already_exists");
      this.ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
      this.queue.initialize();
      const now = Date.now(); requireThat(Number.isSafeInteger(now) && now > 0, 503, "clock_unavailable");
      await this.save({ account, room, members: [{ device: value.device_id, key: value.public_key as string, generation: randomToken() }],
        invites: [], usedInvites: [], challenges: [], highWater: now, paired: false, orphanExpires: now + LIMITS.tokenTtlMs });
      return json({ created: true, server_time: now, expires_at: now + LIMITS.tokenTtlMs }, 201);
    }
    const state = await this.load(operation === "join"); requireThat(account === state.account && room === state.room, 403, "forbidden");
    let value: unknown;
    if (operation === "join") {
      try { value = parseControl(raw); record(value, ["device_id", "public_key", "one_use_token", "expires_at", "signature"]);
        id(value.device_id); unbase64(value.one_use_token, 32); } catch { throw new Refusal(403, "invalid_join_token"); }
      const digest = await hash(value.one_use_token as string);
      const expires = value.expires_at, device = value.device_id;
      const invite = state.invites.find(i => i.digest === digest && i.expires === expires);
      requireThat(invite && invite.expires > Date.now() && invite.expires - Date.now() <= LIMITS.tokenTtlMs, 403, "invalid_join_token");
      const message = JSON.stringify(["voiceremote-relay-join-v1", account, room, value.device_id, value.public_key, value.one_use_token, invite.expires]);
      requireThat(await verify(value.public_key as string, value.signature, message) && invite.expires > Date.now(), 403, "forbidden");
      requireThat(!state.members.some(m => m.device === device), 409, "already_exists"); requireThat(state.members.length < LIMITS.devices, 409, "room_full");
      state.invites = state.invites.filter(i => i.digest !== digest); state.usedInvites.push(invite);
      state.members.push({ device: value.device_id, key: value.public_key as string, generation: randomToken() }); state.paired = true;
      await this.save(state); metric("joined"); return json({ joined: true }, 201);
    }
    value = operation === "connect" ? undefined : parseControl(raw); await this.save(state);
    if (operation === "challenge") {
      record(value, ["device_id", "operation", "body_sha256"]); id(value.device_id); const member = this.member(state, value.device_id);
      requireThat(["connect", "invite", "revoke"].includes(value.operation as string)); unbase64(value.body_sha256, 32);
      requireThat(await verify(member.key, request.headers.get("x-relay-signature"),
        JSON.stringify(["voiceremote-relay-challenge-v1", account, room, await hash(raw)])), 403, "forbidden");
      requireThat(state.challenges.filter(c => c.device === member.device).length < 2 && state.challenges.length < LIMITS.challenges, 429, "rate_limited");
      const nonce = randomToken(), expires = Date.now() + LIMITS.challengeTtlMs;
      const message = JSON.stringify(["voiceremote-relay-auth-v1", account, room, value.device_id, value.operation, value.body_sha256, nonce, expires]);
      state.challenges.push({ nonce, device: value.device_id, operation: value.operation as string, digest: value.body_sha256 as string, expires, message });
      await this.save(state); return json({ challenge: nonce, message, expires_at: expires, server_time: Date.now() });
    }
    const member = await this.authenticate(state, request, operation, raw);
    if (operation === "invite") {
      record(value, ["token_sha256", "expires_at"]); unbase64(value.token_sha256, 32);
      requireThat(typeof value.expires_at === "number" && Number.isSafeInteger(value.expires_at)
        && value.expires_at > Date.now() && value.expires_at - Date.now() <= LIMITS.tokenTtlMs);
      requireThat(!state.usedInvites.some(i => i.digest === value.token_sha256) && !state.invites.some(i => i.digest === value.token_sha256), 409, "token_reused");
      requireThat(state.members.length < LIMITS.devices, 409, "room_full"); state.invites = state.invites.filter(i => i.issuer !== member.device);
      requireThat(state.invites.length < LIMITS.invites, 409, "room_full");
      state.invites.push({ digest: value.token_sha256 as string, issuer: member.device, expires: value.expires_at });
      if (!state.paired) state.orphanExpires = value.expires_at;
      await this.save(state); return json({ registered: true, expires_at: value.expires_at }, 201);
    }
    if (operation === "revoke") {
      record(value, ["device_id"]); id(value.device_id); this.member(state, value.device_id);
      state.members = state.members.filter(m => m.device !== value.device_id); state.invites = state.invites.filter(i => i.issuer !== value.device_id);
      state.challenges = state.challenges.filter(c => c.device !== value.device_id);
      this.ctx.storage.transactionSync(() => { this.queue.revoke(value.device_id as string); this.write(state); }); await this.save(state);
      for (const socket of this.ctx.getWebSockets()) if (this.attachment(socket).device === value.device_id) this.close(socket, "revoked");
      this.broadcastPresence(state, value.device_id, "offline"); metric("revoked"); return json({ revoked: true });
    }
    requireThat(operation === "connect", 404, "not_found"); requireThat(request.headers.get("upgrade")?.toLowerCase() === "websocket", 426, "upgrade_required");
    for (const old of this.ctx.getWebSockets()) if (this.attachment(old).device === member.device) this.close(old, "replaced");
    const pair = new WebSocketPair(), client = pair[0], server = pair[1];
    this.ctx.acceptWebSocket(server); server.serializeAttachment({ device: member.device, generation: member.generation } satisfies Attachment);
    for (const peer of state.members) server.send(encodeFrame(this.presence(state, peer.device,
      peer.device === member.device || this.online(state, peer.device).length ? "online" : "offline")));
    this.broadcastPresence(state, member.device, "online", server);
    const dropped = this.queue.dropped(member.device); for (const queued of this.queue.forDevice(member.device)) server.send(queued.frame);
    this.ctx.storage.transactionSync(() => { this.queue.delivered(member.device); this.write(state); }); await this.save(state);
    return new Response(null, { status: 101, webSocket: client, headers: { "cache-control": "no-store", "x-relay-dropped-frames": String(dropped) } });
  }
  private attachment(socket: WebSocket): Attachment { return socket.deserializeAttachment() as Attachment; }
  private close(socket: WebSocket, reason: string): void {
    socket.close(1008, reason);
  }
  private online(state: State, device: string): WebSocket[] {
    const member = state.members.find(m => m.device === device);
    return this.ctx.getWebSockets().filter(s => { const a = this.attachment(s);
      return s.readyState === 1 && a.device === device && a.generation === member?.generation; });
  }
  private presence(state: State, device: string, status: "online" | "offline"): RelayPresence {
    return { kind: "presence", account_id: state.account, room_id: state.room, sender_device_id: device, state: status };
  }
  private broadcastPresence(state: State, device: string, status: "online" | "offline", except?: WebSocket): void {
    const raw = encodeFrame(this.presence(state, device, status));
    for (const member of state.members) for (const socket of this.online(state, member.device)) if (socket !== except) {
      try { socket.send(raw); } catch { /* close handler updates presence */ }
    }
  }
  async webSocketMessage(socket: WebSocket, message: string | ArrayBuffer): Promise<void> {
    return this.ctx.blockConcurrencyWhile(async () => {
      try {
        const state = await this.load(), attachment = this.attachment(socket);
        const member = this.member(state, attachment.device);
        requireThat(member.generation === attachment.generation && socket.readyState === 1, 403, "forbidden");
        requireThat(typeof message === "string", 415, "text_required");
        requireThat(message.length <= LIMITS.frameBytes && utf8.encode(message).length <= LIMITS.frameBytes, 413, "too_large");
        const frame = decodeFrame(message);
        requireThat(frame.account_id === state.account && frame.room_id === state.room && frame.sender_device_id === member.device, 403, "forbidden");
        if (frame.kind === "wake_registration") {
          const token = unbase64(frame.apns_wake_token); requireThat(token.length > 0 && token.length <= 256);
          member.wake = { token: frame.apns_wake_token, environment: frame.environment }; await this.save(state); return;
        }
        if (frame.kind === "presence") {
          if (frame.state === "offline") socket.close(1000, "offline"); else this.broadcastPresence(state, member.device, "online"); return;
        }
        const raw = encodeFrame(frame), bytes = utf8.encode(raw).length, offline: Member[] = [], live: WebSocket[] = [];
        for (const target of state.members.filter(m => m.device !== member.device)) {
          const peers = this.online(state, target.device); if (peers.length) live.push(...peers); else offline.push(target);
        }
        const wakes: WakeRegistration[] = []; let dropped = 0;
        this.ctx.storage.transactionSync(() => {
          for (const target of offline) {
            dropped += this.queue.enqueue(target.device, member.device, raw, bytes, Date.now() + LIMITS.queueTtlMs);
            if (target.wake && Date.now() - (target.lastWake ?? 0) >= LIMITS.wakeCooldownMs) { target.lastWake = Date.now(); wakes.push(target.wake); }
          }
          this.write(state);
        });
        await this.save(state);
        for (const peer of live) { try { peer.send(raw); } catch { /* peer raced disconnect; endpoints retry */ } }
        metric("accepted", 1, bytes); if (dropped) metric("dropped", dropped);
        for (const registration of wakes) this.ctx.waitUntil(this.env.WAKE.get(this.env.WAKE.idFromName("apns")).fetch(
          "https://wake/", { method: "POST", body: JSON.stringify(registration) }).then(() => {}, () => { metric("wake_failed"); }));
      } catch (error) {
        metric("rejected"); socket.close(error instanceof Refusal && error.status === 413 ? 1009 : 1008,
          error instanceof Refusal ? error.code : "invalid_frame");
      }
    });
  }
  async webSocketClose(socket: WebSocket, code: number): Promise<void> { await this.disconnected(socket, code); }
  async webSocketError(socket: WebSocket): Promise<void> { await this.disconnected(socket, 1011); }
  private async disconnected(socket: WebSocket, code: number): Promise<void> {
    return this.ctx.blockConcurrencyWhile(async () => {
      socket.close(code === 1005 || code === 1006 ? 1000 : code, "closed"); if (!this.stored()) return;
      const state = await this.load(), { device } = this.attachment(socket);
      if (!this.online(state, device).length) this.broadcastPresence(state, device, "offline"); await this.save(state);
    });
  }
  async alarm(): Promise<void> {
    await this.ctx.blockConcurrencyWhile(async () => { if (!this.stored()) return;
      try { await this.save(await this.load()); } catch (error) { if (this.stored()) throw error; } });
  }
}
