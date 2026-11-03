/* Purpose/inputs/verification: see offline_store.h; on-flash formats are private. */
#include "offline_store.h"
#include <limits.h>
#include <string.h>
#define JOURNAL_MAGIC 0x314a5256u
#define SECTOR_MAGIC 0x31535256u
#define COMMIT 0x31434d56u
#define HEADER 64u
#define ENTRY 48u
#define JOURNAL_SLOTS (VR_STORE_SECTOR / ENTRY)
#define CLOSED 2u
#define INTERRUPTED 4u
#define QUARANTINE UINT16_MAX
static uint16_t get16(const uint8_t *p) { return (uint16_t)(p[0] | (uint16_t)p[1] << 8); }
static uint32_t get32(const uint8_t *p) { return (uint32_t)get16(p) | (uint32_t)get16(p + 2) << 16; }
static uint64_t get64(const uint8_t *p) { return (uint64_t)get32(p) | (uint64_t)get32(p + 4) << 32; }
static void put16(uint8_t *p, uint16_t x) { p[0] = (uint8_t)x; p[1] = (uint8_t)(x >> 8); }
static void put32(uint8_t *p, uint32_t x) { put16(p, (uint16_t)x); put16(p + 2, (uint16_t)(x >> 16)); }
static void put64(uint8_t *p, uint64_t x) { put32(p, (uint32_t)x); put32(p + 4, (uint32_t)(x >> 32)); }
static uint32_t crc_add(uint32_t crc, const uint8_t *p, size_t n) {
    while (n--) { crc ^= *p++; for (unsigned b = 0; b < 8; ++b) crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1u))); }
    return crc;
}
uint32_t vr_store_crc32(const uint8_t *p, size_t n) { return crc_add(UINT32_MAX, p, n) ^ UINT32_MAX; }
static bool erased(const uint8_t *p, size_t n) { while (n--) if (*p++ != 0xff) return false; return true; }
static int fail(vr_store_t *s) { s->error = true; return VR_STORE_ERROR; }
static bool read_at(vr_store_t *s, uint32_t pos, void *p, size_t n) { return s->flash.read(s->flash.ctx, pos, p, n); }
static bool write_at(vr_store_t *s, uint32_t pos, const void *p, size_t n) { return s->flash.write(s->flash.ctx, pos, p, n); }
static bool erase_sector(vr_store_t *s, unsigned sector) { return s->flash.erase(s->flash.ctx, sector * VR_STORE_SECTOR, VR_STORE_SECTOR); }
/* Check the entire requested range before deciding it contains no retained data. */
static int range_erased(vr_store_t *s, uint32_t at, size_t size, bool *empty) {
    uint8_t block[256]; *empty=true;
    while (size) {
        size_t n=size<sizeof block?size:sizeof block;
        if (!read_at(s,at,block,n)) return fail(s);
        if (!erased(block,n)) { *empty=false; break; }
        at+=(uint32_t)n; size-=n;
    }
    return VR_STORE_OK;
}
static int record_index(vr_store_t *s, uint64_t id) {
    for (unsigned i = 0; i < VR_STORE_MAX_RECORDS; ++i) if (s->records[i].used && s->records[i].meta.id == id) return (int)i;
    return -1;
}
static int free_record(vr_store_t *s) {
    for (unsigned i = 0; i < VR_STORE_MAX_RECORDS; ++i) if (!s->records[i].used) return (int)i;
    return -1;
}
/* A committed journal entry always precedes data writes/counter use. Compaction
 * first erases the other bank; the latest committed bank survives every boundary. */
static int journal(vr_store_t *s, uint64_t allocated, uint32_t boot, uint64_t pending, uint32_t pending_erase) {
    if (s->journal_seq == UINT64_MAX) return fail(s);
    unsigned bank = s->journal_sector, slot = s->journal_slot;
    if (slot >= JOURNAL_SLOTS) {
        bank ^= 1u; slot = 0;
        if (!erase_sector(s, bank)) return fail(s);
    }
    uint8_t p[ENTRY]; memset(p, 0, sizeof p);
    put32(p, JOURNAL_MAGIC); put64(p + 4, s->journal_seq + 1);
    put64(p + 12, allocated); put32(p + 20, boot); put64(p + 24, pending); put32(p + 32, pending_erase);
    put32(p + 40, vr_store_crc32(p, 40)); put32(p + 44, COMMIT);
    uint32_t pos = bank * VR_STORE_SECTOR + slot * ENTRY;
    /* Never attempt to overwrite an entry abandoned by a failed write. */
    s->journal_sector = (uint16_t)bank; s->journal_slot = (uint16_t)(slot + 1);
    if (!write_at(s, pos, p, 44) || !write_at(s, pos + 44, p + 44, 4)) return fail(s);
    ++s->journal_seq; s->allocated_id = allocated; s->boot_id = boot; s->pending_delete = pending; s->pending_erase = pending_erase;
    return VR_STORE_OK;
}
static bool header(vr_store_t *s, unsigned sector, uint8_t p[HEADER]) {
    return read_at(s, sector * VR_STORE_SECTOR, p, HEADER);
}
static bool header_valid(const uint8_t p[HEADER]) {
    return get32(p) == SECTOR_MAGIC && get32(p + 44) == COMMIT &&
           get32(p + 40) == vr_store_crc32(p, 40) && p[32] <= 1 &&
           p[33] == 0 && p[34] == 0 && p[35] == 0 && get64(p + 4) != 0;
}
/* A single pending-delete intent is recovery state, cleared after erasing. It is
 * never a collection of historical tombstones; allocated missing IDs need none. */
static int complete_delete(vr_store_t *s) {
    uint8_t p[HEADER]; uint64_t id = s->pending_delete;
    if (!id) return VR_STORE_OK;
    /* Persist the physical target before erasing. An interrupted erase may remove
     * magic/ID before the rest of a sector: its header cannot identify it on boot. */
    if (s->pending_erase) {
        if (s->pending_erase < 2 || s->pending_erase >= s->sector_count ||
            !erase_sector(s, s->pending_erase)) return fail(s);
        s->owners[s->pending_erase] = 0;
    }
    for (unsigned sec = 2; sec < s->sector_count; ++sec) {
        if (!header(s, sec, p)) return fail(s);
        /* Other sectors retain their committed headers until their own intent. */
        if (get32(p) == SECTOR_MAGIC && get64(p + 4) == id) {
            if (journal(s, s->allocated_id, s->boot_id, id, sec) || !erase_sector(s, sec)) return fail(s);
            s->owners[sec] = 0;
        }
    }
    int idx = record_index(s, id);
    if (journal(s, s->allocated_id, s->boot_id, 0, 0)) return VR_STORE_ERROR;
    if (idx >= 0) memset(&s->records[idx], 0, sizeof s->records[idx]);
    s->full = false;
    return VR_STORE_OK;
}
int vr_store_init(vr_store_t *s, vr_store_flash_t flash, uint32_t bytes) {
    if (!s || !flash.read || !flash.write || !flash.erase || bytes % VR_STORE_SECTOR ||
        bytes / VR_STORE_SECTOR < 3 || bytes / VR_STORE_SECTOR > VR_STORE_MAX_SECTORS) return VR_STORE_INVALID;
    memset(s, 0, sizeof *s); s->flash = flash; s->sector_count = bytes / VR_STORE_SECTOR; s->active = -1;
    return VR_STORE_OK;
}
/* Scan one sector. Only CRC-verified and commit-marked frames contribute to the
 * export. An incomplete last frame is a tail; a committed bad CRC is corruption. */
static int scan_sector(vr_store_t *s, unsigned sec, vr_store_record_t *r, uint32_t *crc) {
    uint8_t p[8 + VR_STORE_PACKET + 4], prefix[2]; unsigned off = HEADER;
    while (off + 16 <= VR_STORE_SECTOR) {
        if (!read_at(s, sec * VR_STORE_SECTOR + off, p, 8)) return fail(s);
        if (erased(p, 8)) return VR_STORE_OK;
        unsigned n = get16(p), padded = (n + 3u) & ~3u;
        if (!n || n > VR_STORE_PACKET || get16(p + 2) || off + 12 + padded > VR_STORE_SECTOR) {
            if (r->finalized && !(r->meta.flags & 2)) r->corrupt = true;
            return VR_STORE_OK;
        }
        if (!read_at(s, sec * VR_STORE_SECTOR + off + 8, p + 8, padded + 4)) return fail(s);
        if (get32(p + 8 + padded) != COMMIT) {
            if (r->finalized && !(r->meta.flags & 2)) r->corrupt = true;
            return VR_STORE_OK;
        }
        if (get32(p + 4) != vr_store_crc32(p + 8, n)) { r->corrupt = true; return VR_STORE_OK; }
        if (r->meta.bytes > UINT32_MAX - n - 2 || r->meta.frames == UINT32_MAX) { r->corrupt = true; return VR_STORE_OK; }
        put16(prefix, (uint16_t)n); *crc = crc_add(*crc, prefix, 2); *crc = crc_add(*crc, p + 8, n);
        r->meta.bytes += n + 2; s->exported_bytes[sec] += (uint16_t)(n + 2);
        ++r->meta.frames; off += 12 + padded;
    }
    return VR_STORE_OK;
}
static int finish_record(vr_store_t *s, int idx, bool interrupted) {
    vr_store_record_t *r = &s->records[idx];
    if (!r->meta.frames) {
        if (journal(s, s->allocated_id, s->boot_id, r->meta.id, 0)) return VR_STORE_ERROR;
        return complete_delete(s);
    }
    uint8_t summary[12], state[4];
    put32(summary, r->meta.bytes); put32(summary + 4, r->meta.frames); put32(summary + 8, r->meta.crc);
    if (!write_at(s, r->first * VR_STORE_SECTOR + 48, summary, 8) ||
        !write_at(s, r->first * VR_STORE_SECTOR + 60, summary + 8, 4)) return fail(s);
    uint32_t value = UINT32_MAX & ~CLOSED;
    if (interrupted) value &= ~INTERRUPTED;
    put32(state, value);
    if (!write_at(s, r->first * VR_STORE_SECTOR + 56, state, sizeof state)) return fail(s);
    r->finalized = true; if (interrupted) r->meta.flags |= 2;
    return VR_STORE_OK;
}
int vr_store_mount(vr_store_t *s) {
    if (!s || s->mounted) return VR_STORE_INVALID;
    uint8_t p[HEADER]; bool found = false;
    unsigned selected_bank = 0, selected_end = 0, ends[2] = {0, 0};
    for (unsigned bank = 0; bank < 2; ++bank) for (unsigned slot = 0; slot < JOURNAL_SLOTS; ++slot) {
        if (!read_at(s, bank * VR_STORE_SECTOR + slot * ENTRY, p, ENTRY)) return fail(s);
        if (!erased(p, ENTRY)) { ends[bank] = slot + 1; }
        if (get32(p) != JOURNAL_MAGIC || get32(p + 44) != COMMIT || get32(p + 40) != vr_store_crc32(p, 40)) continue;
        uint64_t seq = get64(p + 4);
        if (!found || seq > s->journal_seq) {
            found = true; s->journal_seq = seq; s->allocated_id = get64(p + 12);
            s->boot_id = get32(p + 20); s->pending_delete = get64(p + 24); s->pending_erase = get32(p + 32); selected_bank = bank;
        }
    }
    selected_end = ends[selected_bank]; s->journal_sector = (uint16_t)selected_bank; s->journal_slot = (uint16_t)selected_end;
    if (!found) {
        /* Factory firmware can occupy this region. Format only when no journal
         * or sector magic survives anywhere; damaged stores retain their IDs. */
        uint8_t block[256], dirty[(VR_STORE_MAX_SECTORS+7)/8]={0};
        for (uint32_t at=0; at<s->sector_count*VR_STORE_SECTOR; at+=sizeof block) {
            if (!read_at(s,at,block,sizeof block)) return fail(s);
            for (unsigned off=0; off<sizeof block; off+=4)
                if (get32(block+off)==JOURNAL_MAGIC || get32(block+off)==SECTOR_MAGIC) return fail(s);
            unsigned sec=at/VR_STORE_SECTOR;
            if (!erased(block,sizeof block)) dirty[sec/8] |= (uint8_t)(1u<<(sec%8));
        }
        /* The complete magic scan must finish before the first erase. */
        for (unsigned sec=0; sec<s->sector_count; ++sec) if (dirty[sec/8] & (1u<<(sec%8))) {
            if (!erase_sector(s,sec)) return fail(s);
            ++s->formatted_sectors;
        }
        s->journal_sector=0; s->journal_slot=0;
    }
    if (complete_delete(s)) return VR_STORE_ERROR;
    for (unsigned sec = 2; sec < s->sector_count; ++sec) {
        if (!header(s, sec, p)) return fail(s);
        if (get32(p + 44) != COMMIT) {
            bool body_empty;
            if (range_erased(s,sec*VR_STORE_SECTOR+HEADER,VR_STORE_SECTOR-HEADER,&body_empty)) return VR_STORE_ERROR;
            if (!body_empty) { s->owners[sec]=QUARANTINE; s->error=true; continue; }
            if (erased(p,HEADER)) continue;
            /* Header writes precede every frame. Only an empty sector body
             * proves an uncommitted allocation tail is safe to reclaim. */
            if (!erase_sector(s,sec)) return fail(s);
            continue;
        }
        if (!header_valid(p)) { s->owners[sec] = QUARANTINE; s->error = true; continue; }
        uint64_t id = get64(p + 4); int idx = record_index(s, id);
        if (id > s->allocated_id || (idx < 0 && (idx = free_record(s)) < 0)) { s->owners[sec] = QUARANTINE; s->error = true; continue; }
        vr_store_record_t *r = &s->records[idx];
        if (!r->used) { r->used = true; r->meta.id = id; r->first = UINT16_MAX; }
        s->owners[sec] = (uint16_t)(idx + 1); s->ordinals[sec] = get32(p + 36); ++r->sectors;
        if (s->ordinals[sec] == 0) {
            if (r->first != UINT16_MAX) r->corrupt = true;
            r->first = (uint16_t)sec; r->meta.boot = get32(p + 12); r->meta.tick = get64(p + 16);
            r->meta.utc = get64(p + 24); r->meta.mode = p[32]; r->meta.flags = 1;
            r->finalized = !(get32(p + 56) & CLOSED);
            if (!(get32(p + 56) & INTERRUPTED)) r->meta.flags |= 2;
        }
    }
    for (unsigned i = 0; i < VR_STORE_MAX_RECORDS; ++i) {
        vr_store_record_t *r = &s->records[i]; if (!r->used) continue;
        uint32_t crc = UINT32_MAX;
        if (r->first == UINT16_MAX) { r->corrupt = true; r->finalized = true; s->error = true; continue; }
        for (unsigned ordinal = 0; ordinal < r->sectors; ++ordinal) {
            unsigned match = UINT_MAX;
            for (unsigned sec = 2; sec < s->sector_count; ++sec) if (s->owners[sec] == i + 1 && s->ordinals[sec] == ordinal) {
                if (match != UINT_MAX) r->corrupt = true;
                match = sec;
            }
            if (match == UINT_MAX) { r->corrupt = true; break; }
            if (scan_sector(s, match, r, &crc)) return VR_STORE_ERROR;
            if (ordinal) s->next_sector[r->last] = (uint16_t)match;
            r->last = (uint16_t)match;
            if (r->corrupt) break;
        }
        r->meta.crc = crc ^ UINT32_MAX;
        if (r->finalized) {
            if (!header(s, r->first, p)) return fail(s);
            if (get32(p + 48) != r->meta.bytes || get32(p + 52) != r->meta.frames || get32(p + 60) != r->meta.crc) r->corrupt = true;
            if (r->corrupt) { /* Keep the immutable finalized export description. */
                r->meta.bytes=get32(p+48); r->meta.frames=get32(p+52); r->meta.crc=get32(p+60);
            }
        }
        if (r->corrupt) { r->finalized = true; s->error = true; continue; }
        if (!r->finalized && finish_record(s, (int)i, true)) return VR_STORE_ERROR;
    }
    if (s->boot_id == UINT32_MAX || journal(s, s->allocated_id, s->boot_id + 1, 0, 0)) return fail(s);
    s->mounted = true; s->full = vr_store_free(s) == 0 || free_record(s) < 0;
    return VR_STORE_OK;
}
static int allocate_sector(vr_store_t *s, int idx) {
    unsigned sec;
    for (sec = 2; sec < s->sector_count; ++sec) if (!s->owners[sec]) break;
    if (sec == s->sector_count) { s->full = true; return VR_STORE_END; }
    vr_store_record_t *r = &s->records[idx]; uint8_t p[HEADER]; memset(p, 0xff, sizeof p);
    put32(p, SECTOR_MAGIC); put64(p + 4, r->meta.id); put32(p + 12, r->meta.boot);
    put64(p + 16, r->meta.tick); put64(p + 24, r->meta.utc); p[32] = r->meta.mode;
    p[33] = p[34] = p[35] = 0; put32(p + 36, r->sectors); put32(p + 40, vr_store_crc32(p, 40)); put32(p + 44, COMMIT);
    /* Mark ownership first: any failed write remains reserved until reboot scan. */
    s->owners[sec] = (uint16_t)(idx + 1); s->ordinals[sec] = r->sectors;
    if (!write_at(s, sec * VR_STORE_SECTOR, p, 44) || !write_at(s, sec * VR_STORE_SECTOR + 44, p + 44, 4)) return fail(s);
    s->next_sector[sec] = s->exported_bytes[sec] = 0;
    if (!r->sectors) r->first = (uint16_t)sec;
    else s->next_sector[r->last] = (uint16_t)sec;
    r->last = (uint16_t)sec; ++r->sectors; s->active_sector = (uint16_t)sec; s->active_offset = HEADER;
    return VR_STORE_OK;
}
int vr_store_begin(vr_store_t *s, uint8_t mode, uint64_t tick, uint64_t utc, uint64_t *id) {
    if (!s || !s->mounted || !id || mode > 1) return VR_STORE_INVALID;
    if (s->active >= 0) return VR_STORE_BUSY;
    if (s->error || s->allocated_id == UINT64_MAX) return fail(s);
    int idx = free_record(s);
    if (idx < 0 || !vr_store_free(s)) { s->full = true; return VR_STORE_END; }
    if (journal(s, s->allocated_id + 1, s->boot_id, 0, 0)) return VR_STORE_ERROR;
    vr_store_record_t *r = &s->records[idx]; memset(r, 0, sizeof *r); r->used = true;
    r->meta.id = s->allocated_id; r->meta.boot = s->boot_id; r->meta.tick = tick; r->meta.utc = utc;
    r->meta.mode = mode; r->meta.flags = 1; s->active = idx; s->active_crc = UINT32_MAX;
    int result = allocate_sector(s, idx);
    if (result) { s->active = -1; return result; }
    *id = r->meta.id; s->full = false; return VR_STORE_OK;
}
int vr_store_append(vr_store_t *s, const uint8_t *packet, size_t n) {
    if (!s || !packet || !n || n > VR_STORE_PACKET) return VR_STORE_INVALID;
    if (s->active < 0) return VR_STORE_BUSY;
    if (s->error) return VR_STORE_ERROR;
    vr_store_record_t *r = &s->records[s->active]; size_t padded = (n + 3) & ~(size_t)3;
    if (r->meta.bytes > UINT32_MAX - n - 2 || r->meta.frames == UINT32_MAX) return VR_STORE_END;
    if (s->active_offset + 12 + padded > VR_STORE_SECTOR) { int rc = allocate_sector(s, s->active); if (rc) return rc; }
    uint8_t p[8 + VR_STORE_PACKET + 4]; memset(p, 0, 8 + padded);
    put16(p, (uint16_t)n); put32(p + 4, vr_store_crc32(packet, n)); memcpy(p + 8, packet, n); put32(p + 8 + padded, COMMIT);
    uint32_t pos = s->active_sector * VR_STORE_SECTOR + s->active_offset;
    if (!write_at(s, pos, p, 8 + padded) || !write_at(s, pos + 8 + (uint32_t)padded, p + 8 + padded, 4)) return fail(s);
    s->active_offset = (uint16_t)(s->active_offset + 12 + padded);
    s->active_crc = crc_add(s->active_crc, p, 2); s->active_crc = crc_add(s->active_crc, packet, n);
    s->exported_bytes[s->active_sector] += (uint16_t)(n + 2);
    r->meta.bytes += (uint32_t)n + 2; ++r->meta.frames; r->meta.crc = s->active_crc ^ UINT32_MAX;
    return VR_STORE_OK;
}
int vr_store_finish(vr_store_t *s, bool interrupted) {
    if (!s || s->active < 0) return VR_STORE_BUSY;
    int idx = s->active; s->active = -1;
    return finish_record(s, idx, interrupted || s->error || s->full);
}
int vr_store_next(vr_store_t *s, uint64_t cursor, vr_store_meta_t *meta) {
    if (!s || !s->mounted || !meta) return VR_STORE_INVALID;
    int best = -1;
    for (unsigned i = 0; i < VR_STORE_MAX_RECORDS; ++i) {
        vr_store_record_t *r = &s->records[i];
        if (r->used && r->finalized && r->meta.id > cursor && (best < 0 || r->meta.id < s->records[best].meta.id)) best = (int)i;
    }
    if (best < 0) return VR_STORE_END;
    *meta = s->records[best].meta;
    /* Existing interrupted flag advertises damage; Fetch/Confirm return storage
     * error for this ID. List must remain traversable without a wire change. */
    if (s->records[best].corrupt) meta->flags |= 2;
    return VR_STORE_OK;
}
int vr_store_fetch(vr_store_t *s, uint64_t id, uint32_t offset, uint8_t *data, size_t max, size_t *size) {
    if (!s || !s->mounted || !data || !max || !size) return VR_STORE_INVALID;
    *size = 0;
    if (s->active >= 0) return VR_STORE_BUSY;
    int idx = record_index(s, id); if (idx < 0) return VR_STORE_NOT_FOUND;
    vr_store_record_t *r = &s->records[idx]; if (!r->finalized) return VR_STORE_BUSY;
    if (r->corrupt) return VR_STORE_ERROR;
    if (offset > r->meta.bytes) return VR_STORE_INVALID;
    uint32_t skip = offset; uint8_t p[8 + VR_STORE_PACKET + 4];
    /* The RAM index skips prefix sectors without IO. Only the target sector's
     * frame prefix and requested data are reread for each resumable fetch. */
    unsigned sec = r->first;
    for (unsigned ordinal = 0; ordinal < r->sectors && *size < max && offset + *size < r->meta.bytes;
         ++ordinal, sec = s->next_sector[sec]) {
        if (sec < 2 || sec >= s->sector_count || s->owners[sec] != idx + 1) return fail(s);
        if (skip >= s->exported_bytes[sec]) { skip -= s->exported_bytes[sec]; continue; }
        unsigned off = HEADER;
        while (off + 16 <= VR_STORE_SECTOR && *size < max && offset + *size < r->meta.bytes) {
            if (!read_at(s, sec * VR_STORE_SECTOR + off, p, 8)) return fail(s);
            unsigned n = get16(p), padded = (n + 3u) & ~3u;
            if (erased(p, 8) || !n || n > VR_STORE_PACKET || off + 12 + padded > VR_STORE_SECTOR) break;
            if (!read_at(s, sec * VR_STORE_SECTOR + off + 8, p + 8, padded + 4)) return fail(s);
            if (get32(p + 8 + padded) != COMMIT) break;
            if (get32(p + 4) != vr_store_crc32(p + 8, n)) { r->corrupt = true; return fail(s); }
            for (unsigned b = 0; b < n + 2 && *size < max; ++b) {
                if (skip) --skip;
                else data[(*size)++] = b < 2 ? p[b] : p[8 + b - 2];
            }
            off += 12 + padded;
        }
    }
    if (*size != (size_t)(r->meta.bytes - offset < max ? r->meta.bytes - offset : max)) { r->corrupt = true; return fail(s); }
    return VR_STORE_OK;
}
int vr_store_confirm(vr_store_t *s, uint64_t id, uint32_t bytes, uint32_t crc) {
    if (!s || !s->mounted || !id) return VR_STORE_INVALID;
    if (s->active >= 0) return VR_STORE_BUSY;
    int idx = record_index(s, id);
    if (idx < 0) return id <= s->allocated_id ? VR_STORE_OK : VR_STORE_NOT_FOUND;
    vr_store_record_t *r = &s->records[idx];
    if (!r->finalized) return VR_STORE_BUSY;
    if (r->corrupt) return VR_STORE_ERROR;
    if (r->meta.bytes != bytes || r->meta.crc != crc) return VR_STORE_INVALID;
    if (journal(s, s->allocated_id, s->boot_id, id, 0)) return VR_STORE_ERROR;
    return complete_delete(s);
}
uint32_t vr_store_count(const vr_store_t *s) {
    uint32_t n = 0; for (unsigned i = 0; i < VR_STORE_MAX_RECORDS; ++i) n += s->records[i].used && s->records[i].finalized;
    return n;
}
uint64_t vr_store_total(const vr_store_t *s) { return (uint64_t)(s->sector_count - 2) * (VR_STORE_SECTOR - HEADER); }
uint64_t vr_store_free(const vr_store_t *s) {
    uint64_t n = 0; for (unsigned sec = 2; sec < s->sector_count; ++sec) if (!s->owners[sec]) n += VR_STORE_SECTOR - HEADER;
    if (s->active >= 0) n += VR_STORE_SECTOR - s->active_offset;
    return n;
}
void vr_store_meta_encode(const vr_store_meta_t *m, uint8_t p[VR_STORE_META_SIZE]) {
    put64(p, m->id); put32(p + 8, m->boot); put64(p + 12, m->tick); put64(p + 20, m->utc);
    p[28] = m->mode; p[29] = m->flags; put32(p + 30, m->bytes); put32(p + 34, m->frames); put32(p + 38, m->crc);
}
