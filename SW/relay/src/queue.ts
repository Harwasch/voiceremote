import { LIMITS } from "./security.js";
export type Queued = { id: number; target: string; sender: string; frame: string; bytes: number; expires: number };

// SQLite avoids the KV value limit; synchronous methods share the room transaction.
export class CiphertextQueue {
  constructor(private readonly sql: SqlStorage) {}
  initialize(): void {
    this.sql.exec("CREATE TABLE IF NOT EXISTS frames (id INTEGER PRIMARY KEY AUTOINCREMENT, target TEXT, sender TEXT, frame TEXT, bytes INTEGER, expires INTEGER)");
    this.sql.exec("CREATE INDEX IF NOT EXISTS frames_target ON frames(target, id)");
    this.sql.exec("CREATE TABLE IF NOT EXISTS drops (target TEXT PRIMARY KEY, count INTEGER NOT NULL)");
  }
  all(): Queued[] { return this.sql.exec<Queued>("SELECT * FROM frames ORDER BY id").toArray(); }
  forDevice(device: string): Queued[] { return this.sql.exec<Queued>("SELECT * FROM frames WHERE target = ? ORDER BY id", device).toArray(); }
  expire(now: number): void { this.sql.exec("DELETE FROM frames WHERE expires <= ?", now); }
  enqueue(target: string, sender: string, frame: string, bytes: number, expires: number): number {
    this.sql.exec("INSERT INTO frames(target, sender, frame, bytes, expires) VALUES (?, ?, ?, ?, ?)", target, sender, frame, bytes, expires);
    const queued = this.forDevice(target);
    let total = queued.reduce((sum, q) => sum + q.bytes, 0), count = queued.length, dropped = 0;
    for (const oldest of queued) {
      if (count <= LIMITS.queueCount && total <= LIMITS.queueBytes) break;
      this.sql.exec("DELETE FROM frames WHERE id = ?", oldest.id); total -= oldest.bytes; count--; dropped++;
    }
    if (dropped) this.sql.exec("INSERT INTO drops(target, count) VALUES (?, ?) ON CONFLICT(target) DO UPDATE SET count = count + excluded.count", target, dropped);
    return dropped;
  }
  dropped(device: string): number { return this.sql.exec<{ count: number }>("SELECT count FROM drops WHERE target = ?", device).toArray()[0]?.count ?? 0; }
  delivered(device: string): void {
    this.sql.exec("DELETE FROM frames WHERE target = ?", device); this.sql.exec("DELETE FROM drops WHERE target = ?", device);
  }
  revoke(device: string): void {
    this.sql.exec("DELETE FROM frames WHERE target = ? OR sender = ?", device, device); this.sql.exec("DELETE FROM drops WHERE target = ?", device);
  }
  deadline(): number | undefined {
    return this.sql.exec<{ expires: number | null }>("SELECT MIN(expires) AS expires FROM frames").one().expires ?? undefined;
  }
}
