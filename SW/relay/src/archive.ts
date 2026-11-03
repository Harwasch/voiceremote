import type { AuditArchiveBlock, AuditArchiveRead } from "./protocol/generated.js";
import { parseControl } from "./control.js";
import { id, record, requireThat, utf8 } from "./security.js";

export const ARCHIVE_LIMITS = { blocks: 128, bytes: 2_097_152, bodyBytes: 66_560, checkpointBytes: 2_100_000,
  page: 8, inactivityMs: 30 * 24 * 60 * 60 * 1000 } as const; // TTL TBC product policy.
export const EMPTY_ARCHIVE_HASH = "0".repeat(64);
const epoch = (block: { epoch?: number }): number => block.epoch ?? 0;
export function decodeArchive(raw: string, read = false): AuditArchiveBlock | AuditArchiveRead {
  const value = parseControl(raw);
  const keys = read ? ["account_id", "room_id", "sequence"] : ["account_id", "room_id", "sequence", "previous_hash", "ciphertext", "block_hash"];
  record(value, Object.hasOwn(value as object, "epoch") ? [...keys, "epoch"] : keys);
  id(value.account_id); id(value.room_id);
  for (const n of [value.sequence, value.epoch ?? 0]) requireThat(typeof n === "number" && Number.isSafeInteger(n) && n >= 0);
  if (!read) {
    for (const field of ["previous_hash", "block_hash"]) requireThat(typeof value[field] === "string"
      && value[field].length === 64 && /^[0-9a-f]{64}$/.test(value[field] as string));
    const sealed = value.ciphertext;
    requireThat(typeof sealed === "string" && sealed.length >= 40 && sealed.length <= 1_500_000
      && /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(sealed));
    requireThat(btoa(atob(sealed)) === sealed);
  }
  return value as unknown as AuditArchiveBlock | AuditArchiveRead;
}
export async function archiveHash(block: Omit<AuditArchiveBlock, "block_hash">): Promise<string> {
  const bytes = utf8.encode(JSON.stringify(["voiceremote-audit-archive-v2", block.account_id, block.room_id,
    epoch(block), block.sequence, block.previous_hash, block.ciphertext]));
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map(b => b.toString(16).padStart(2, "0")).join("");
}
function canonical(block: AuditArchiveBlock): string {
  return JSON.stringify({ account_id: block.account_id, room_id: block.room_id, epoch: epoch(block), sequence: block.sequence,
    previous_hash: block.previous_hash, ciphertext: block.ciphertext, block_hash: block.block_hash });
}
// The room serializes all operations; mutations share its SQLite transaction.
export class EncryptedArchive {
  constructor(private readonly sql: SqlStorage) {}
  private initialize(): void {
    this.sql.exec("CREATE TABLE IF NOT EXISTS audit_archive (sequence INTEGER PRIMARY KEY, hash TEXT NOT NULL, block TEXT NOT NULL, bytes INTEGER NOT NULL)");
    this.sql.exec("CREATE TABLE IF NOT EXISTS audit_owner (slot INTEGER PRIMARY KEY CHECK(slot=1), generation TEXT NOT NULL)");
    this.sql.exec("CREATE TABLE IF NOT EXISTS audit_epoch (slot INTEGER PRIMARY KEY CHECK(slot=1), epoch INTEGER NOT NULL)");
  }
  bind(key: string): void {
    this.initialize();
    this.sql.exec("INSERT INTO audit_owner(slot, generation) VALUES (1, ?) ON CONFLICT(slot) DO UPDATE SET generation=excluded.generation", key);
  }
  writer(): string | undefined {
    this.initialize();
    return this.sql.exec<{ generation: string }>("SELECT generation FROM audit_owner WHERE slot=1").toArray()[0]?.generation;
  }
  private currentEpoch(): number {
    this.initialize(); return this.sql.exec<{ epoch: number }>("SELECT epoch FROM audit_epoch WHERE slot=1").toArray()[0]?.epoch ?? 0;
  }
  read(sequence: number, requestedEpoch = 0): AuditArchiveBlock[] {
    requireThat(requestedEpoch === this.currentEpoch(), 409, "archive_epoch_mismatch");
    return this.sql.exec<{ block: string }>("SELECT block FROM audit_archive WHERE sequence >= ? ORDER BY sequence LIMIT 8", sequence).toArray().map(r => JSON.parse(r.block));
  }
  append(block: AuditArchiveBlock, key: string, checkpoint = false): void {
    requireThat(this.writer() === key, 403, "archive_writer_mismatch");
    if (checkpoint) requireThat(block.sequence === 0 && epoch(block) > 0, 409, "archive_epoch_mismatch");
    const raw = canonical(block), bytes = utf8.encode(raw).length, current = this.currentEpoch();
    if (epoch(block) === current) {
      const existing = this.sql.exec<{ block: string }>("SELECT block FROM audit_archive WHERE sequence=?", block.sequence).toArray()[0];
      if (existing) { requireThat(existing.block === raw, 409, "archive_conflict"); return; }
    }
    const head = this.sql.exec<{ hash: string }>("SELECT hash FROM audit_archive ORDER BY sequence DESC LIMIT 1").toArray()[0]?.hash ?? EMPTY_ARCHIVE_HASH;
    if (checkpoint) {
      requireThat(epoch(block) === current + 1 && block.sequence === 0 && block.previous_hash === head, 409, "archive_epoch_mismatch");
      requireThat(bytes <= ARCHIVE_LIMITS.bytes, 409, "archive_full");
      // A member-signed, phone-encrypted replacement checkpoint authorizes pruning.
      // Commit the replacement and epoch together; an uncertain acknowledgement retries exactly.
      this.sql.exec("DELETE FROM audit_archive");
      this.sql.exec("INSERT INTO audit_epoch(slot,epoch) VALUES (1,?) ON CONFLICT(slot) DO UPDATE SET epoch=excluded.epoch", epoch(block));
    } else {
      requireThat(epoch(block) === current, 409, "archive_epoch_mismatch");
      requireThat(block.ciphertext.length <= 65_536, 413, "too_large");
      const rows = this.sql.exec<{ count: number; bytes: number }>("SELECT COUNT(*) AS count, COALESCE(SUM(bytes),0) AS bytes FROM audit_archive").one();
      requireThat(block.sequence === rows.count && block.previous_hash === head, 409, "archive_conflict");
      requireThat(rows.count < ARCHIVE_LIMITS.blocks && rows.bytes + bytes <= ARCHIVE_LIMITS.bytes, 409, "archive_full");
    }
    this.sql.exec("INSERT INTO audit_archive(sequence,hash,block,bytes) VALUES (?,?,?,?)", block.sequence, block.block_hash, raw, bytes);
  }
}
