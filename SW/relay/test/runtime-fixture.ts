// Test-only storage inspection/expiry injection. Never a Wrangler entrypoint.
import worker from "../src/worker.js";
import type { Env } from "../src/worker.js";
import { Room as ProductionRoom } from "../src/room.js";
export { Admission, WakeProvider } from "../src/worker.js";
export default { fetch(request: Request, env: Env) {
  return worker.fetch(request, request.headers.has("x-test-provision")
    ? { ...env, RELAY_PROVISION_SECRET: "SYNTHETIC-test-provisioning-only-00000000" } : env);
} };
export class Room extends ProductionRoom {
  async fetch(request: Request): Promise<Response> {
    if (new URL(request.url).pathname === "/__alarm") { await super.alarm(); return Response.json({}); }
    if (new URL(request.url).pathname === "/__test") {
      return this.ctx.blockConcurrencyWhile(async () => {
        const state: any = this.stored();
        if (request.method === "POST") {
          const op = await request.text();
          if (op === "rollback") state.highWater = Date.now() + 60_000;
          else if (op === "orphan") state.orphanExpires = Date.now() - 1;
          else if (op.startsWith("remove:")) state.members = state.members.filter((m: any) => m.device !== op.slice(7));
          else if (op.startsWith("generation:")) state.members.find((m: any) => m.device === op.slice(11)).generation = "SYNTHETIC-NEW-GENERATION";
          else if (op === "queue") this.ctx.storage.sql.exec("UPDATE frames SET expires = ?", Date.now() - 1);
          else for (const item of state[op]) item.expires = Date.now() - 1;
          this.write(state);
        }
        const tables = this.ctx.storage.sql.exec<{ name: string }>("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%'").toArray();
        const sql = Object.fromEntries(tables.map(t => [t.name, this.ctx.storage.sql.exec(`SELECT * FROM "${t.name}"`).toArray()]));
        return Response.json({ sockets: this.ctx.getWebSockets().map(s => ({ attachment: s.deserializeAttachment(), ready: s.readyState })), kv: Object.fromEntries(await this.ctx.storage.list()), sql,
          room: state ? { ...state, queue: this.queue.all(), drops: this.ctx.storage.sql.exec("SELECT * FROM drops").toArray() } : undefined });
      });
    }
    return super.fetch(request);
  }
}
