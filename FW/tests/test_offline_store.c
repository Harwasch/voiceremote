/* Purpose: fake-flash crash consistency/integrity tests, synthetic packets only.
 * Inputs: offline_store.c raw flash format; verified by host test runner. */
#include "offline_store.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#define SECTORS 7u
#define BYTES (SECTORS * VR_STORE_SECTOR)
typedef struct {
    uint8_t bytes[BYTES];
    unsigned mutations, cut, reads, erases;
    bool partial;
} flash_t;
static flash_t flash, saved;
static vr_store_t store, recovered;
static bool rd(void *ctx, uint32_t off, void *p, size_t n) {
    flash_t *f = ctx; assert(off + n <= BYTES); ++f->reads; memcpy(p, f->bytes + off, n); return true;
}
static bool wr(void *ctx, uint32_t off, const void *p, size_t n) {
    flash_t *f = ctx; const uint8_t *src = p; assert(off + n <= BYTES && !(off % 4) && !(n % 4));
    bool cut = ++f->mutations == f->cut; size_t limit = cut ? (f->partial ? n / 2 : 0) : n;
    for (size_t i = 0; i < limit; ++i) { assert((f->bytes[off + i] & src[i]) == src[i]); f->bytes[off + i] &= src[i]; }
    return !cut;
}
static bool er(void *ctx, uint32_t off, size_t n) {
    flash_t *f = ctx; ++f->erases; assert(!(off % VR_STORE_SECTOR) && n == VR_STORE_SECTOR && off + n <= BYTES);
    bool cut = ++f->mutations == f->cut;
    memset(f->bytes + off, 0xff, cut ? (f->partial ? n / 2 : 0) : n);
    return !cut;
}
static void init(vr_store_t *s) {
    vr_store_flash_t io = {&flash, rd, wr, er};
    assert(vr_store_init(s, io, BYTES) == VR_STORE_OK);
}
static void blank(void) { memset(&flash, 0, sizeof flash); memset(flash.bytes, 0xff, BYTES); init(&store); assert(!vr_store_mount(&store)); }
static void reboot(void) { flash.cut = 0; flash.mutations = 0; init(&recovered); assert(!vr_store_mount(&recovered)); }
static uint64_t begin(uint8_t mode) {
    uint64_t id; assert(!vr_store_begin(&store, mode, 1000, 0, &id)); return id;
}
static uint64_t record(unsigned frames) {
    uint64_t id = begin(0); uint8_t packet[] = {0, 1, 2};
    for (unsigned i = 0; i < frames; ++i) assert(!vr_store_append(&store, packet, sizeof packet));
    assert(!vr_store_finish(&store, false)); return id;
}
static void stream_check(vr_store_t *s, const vr_store_meta_t *m) {
    uint8_t p[19]; uint32_t offset = 0, crc = 0;
    uint8_t all[2048]; assert(m->bytes <= sizeof all);
    while (offset < m->bytes) {
        size_t n; assert(!vr_store_fetch(s, m->id, offset, p, sizeof p, &n)); assert(n > 0);
        memcpy(all + offset, p, n); offset += (uint32_t)n;
    }
    crc = vr_store_crc32(all, offset); assert(crc == m->crc);
    assert(m->bytes == m->frames * 5);
    for (uint32_t i = 0; i < m->bytes; ++i) { static const uint8_t expected[] = {3, 0, 0, 1, 2}; assert(all[i] == expected[i % 5]); }
    size_t n = 99; assert(!vr_store_fetch(s, m->id, m->bytes, p, sizeof p, &n) && n == 0);
    assert(vr_store_fetch(s, m->id, m->bytes + 1, p, sizeof p, &n) == VR_STORE_INVALID);
}
static void basic_resume_and_examples(void) {
    blank(); assert(store.boot_id == 1); uint64_t id = record(1); assert(id == 1);
    vr_store_meta_t m; assert(!vr_store_next(&store, 0, &m)); stream_check(&store, &m);
    assert(m.crc == 0x7697dda0u && m.flags == 1 && m.bytes == 5 && m.frames == 1);
    m.boot = 7; uint8_t encoded[42]; vr_store_meta_encode(&m, encoded);
    static const uint8_t example[42] = {1,0,0,0,0,0,0,0,7,0,0,0,0xe8,3,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,5,0,0,0,1,0,0,0,0xa0,0xdd,0x97,0x76};
    assert(!memcmp(encoded, example, sizeof example));
    reboot(); assert(recovered.boot_id == 2); assert(!vr_store_next(&recovered, 0, &m)); stream_check(&recovered, &m);
    assert(vr_store_confirm(&recovered, 1, 4, m.crc) == VR_STORE_INVALID);
    assert(!vr_store_confirm(&recovered, 1, m.bytes, m.crc));
    assert(!vr_store_confirm(&recovered, 1, 0, 0)); assert(vr_store_confirm(&recovered, 2, 0, 0) == VR_STORE_NOT_FOUND);
    reboot(); assert(!vr_store_count(&recovered)); assert(!vr_store_confirm(&recovered, 1, 0, 0));
    uint64_t next; assert(!vr_store_begin(&recovered, 1, 3000, 0, &next)); assert(next == 2);
    assert(!vr_store_append(&recovered, example, 42)); assert(!vr_store_finish(&recovered, false));
    assert(!vr_store_next(&recovered, 0, &m)); assert(m.mode == 1 && m.id == 2 && m.tick == 3000);
}
#define SCRIPT_FRAMES 260u
static int script(void) {
    uint64_t id; int rc = vr_store_begin(&store, 0, 1000, 0, &id); if (rc) return rc;
    uint8_t p[] = {0, 1, 2}; for (unsigned i = 0; i < SCRIPT_FRAMES; ++i) if ((rc = vr_store_append(&store, p, sizeof p))) return rc;
    return vr_store_finish(&store, false);
}
static void every_write_boundary(void) {
    blank(); saved = flash; flash.mutations = 0; assert(!script()); unsigned count = flash.mutations;
    for (unsigned partial = 0; partial < 2; ++partial) for (unsigned cut = 1; cut <= count; ++cut) {
        flash = saved; flash.mutations = 0; flash.cut = cut; flash.partial = partial;
        init(&store); /* use already allocated boot; avoid modifying our baseline */
        flash.cut = 0; assert(!vr_store_mount(&store)); flash.mutations = 0; flash.cut = cut;
        (void)script(); reboot();
        vr_store_meta_t m; int rc = vr_store_next(&recovered, 0, &m);
        assert(rc == VR_STORE_END || rc == VR_STORE_OK);
        if (rc == VR_STORE_OK) { assert(m.frames >= 1 && m.frames <= SCRIPT_FRAMES); stream_check(&recovered, &m); if (m.frames < SCRIPT_FRAMES) assert(m.flags & 2); }
        /* A successful capture ID can never reappear as a new record. */
        assert(!recovered.error); { uint64_t id, high = recovered.allocated_id; assert(!vr_store_begin(&recovered, 0, 0, 0, &id)); assert(id == high + 1); }
    }
    printf("offline store: power loss at %u mutation boundaries, whole and torn writes passed\n", count);
}
static void torn_final_frame_and_off(void) {
    blank(); begin(0); uint8_t p[] = {0, 1, 2}; assert(!vr_store_append(&store, p, 3));
    flash.cut = flash.mutations + 2; flash.partial = true; assert(vr_store_append(&store, p, 3) == VR_STORE_ERROR);
    reboot(); vr_store_meta_t m; assert(!vr_store_next(&recovered, 0, &m)); assert(m.frames == 1 && (m.flags & 2)); stream_check(&recovered, &m);
    /* OFF discards its volatile queue; the storage core receives no new append. */
    blank(); begin(1); assert(!vr_store_append(&store, p, 3)); assert(!vr_store_finish(&store, false));
    assert(vr_store_append(&store, p, 3) == VR_STORE_BUSY); assert(!vr_store_next(&store, 0, &m)); assert(m.frames == 1 && m.mode == 1);
}
static void full_and_live_priority(void) {
    blank(); uint8_t p[512]; memset(p, 0x55, sizeof p); begin(0); unsigned frames = 0;
    while (!vr_store_append(&store, p, sizeof p)) ++frames;
    assert(store.full && frames == (SECTORS - 2) * 7); assert(!vr_store_finish(&store, true));
    vr_store_meta_t m; assert(!vr_store_next(&store, 0, &m)); assert(m.frames == frames && (m.flags & 2));
    uint64_t id; assert(vr_store_begin(&store, 0, 0, 0, &id) == VR_STORE_END);
    assert(!vr_store_confirm(&store, m.id, m.bytes, m.crc)); assert(vr_store_free(&store) == vr_store_total(&store));
    record(2); assert(!vr_store_next(&store, 0, &m)); begin(1);
    uint8_t out[8]; size_t n; assert(vr_store_fetch(&store, m.id, 0, out, sizeof out, &n) == VR_STORE_BUSY);
    assert(!vr_store_finish(&store, false)); assert(!vr_store_fetch(&store, m.id, 1, out, sizeof out, &n)); assert(n == sizeof out);
}
static void deletion_boundaries(void) {
    blank(); record(300); record(2); saved = flash; vr_store_meta_t m; assert(!vr_store_next(&store, 0, &m));
    flash.mutations = 0; assert(!vr_store_confirm(&store, m.id, m.bytes, m.crc)); unsigned count = flash.mutations;
    for (unsigned partial = 0; partial < 2; ++partial) for (unsigned cut = 1; cut <= count; ++cut) {
        flash = saved; flash.cut = 0; init(&store); assert(!vr_store_mount(&store));
        flash.mutations = 0; flash.cut = cut; flash.partial = partial; (void)vr_store_confirm(&store, m.id, m.bytes, m.crc);
        reboot(); assert(!recovered.error); vr_store_meta_t other; assert(!vr_store_next(&recovered, 1, &other)); assert(other.id == 2 && other.frames == 2);
        stream_check(&recovered, &other); assert(!vr_store_confirm(&recovered, m.id, m.bytes, m.crc));
        assert(!vr_store_confirm(&recovered, m.id, 123, 456));
        assert(!vr_store_confirm(&recovered, other.id, other.bytes, other.crc));
        assert(vr_store_free(&recovered) == vr_store_total(&recovered));
    }
    printf("offline store: deletion power loss at %u mutation boundaries, whole/torn writes and erases passed\n", count);
}
static void indexed_resume_reads(void) {
    blank(); uint64_t id = record(300); /* 252 frames in first sector, 48 in last. */
    for (unsigned mounted = 0; mounted < 2; ++mounted) {
        vr_store_t *s = mounted ? &recovered : &store;
        if (mounted) reboot();
        uint8_t out[5]; size_t n; flash.reads = 0;
        assert(!vr_store_fetch(s, id, 299 * 5, out, sizeof out, &n));
        static const uint8_t expected[] = {3, 0, 0, 1, 2};
        assert(n == sizeof expected && !memcmp(out, expected, n));
        /* Rebuilt RAM index skips the 252-frame prefix with zero flash reads.
         * Old fetch needed 600 reads; only 48 final-sector frames need 96. */
        assert(flash.reads == 96);
    }
    puts("offline store: RAM-indexed resume skips earlier sectors, before/after mount passed");
}
static void corruption_and_compaction(void) {
    blank(); record(1);
    vr_store_meta_t deleted; assert(!vr_store_next(&store, 0, &deleted));
    assert(!vr_store_confirm(&store, deleted.id, deleted.bytes, deleted.crc));
    /* Recognizable but damaged journal must never reset IDs. */
    for (unsigned bank=0; bank<2; ++bank) for (unsigned slot=0; slot<VR_STORE_SECTOR/48; ++slot)
        flash.bytes[bank*VR_STORE_SECTOR+slot*48+40] = 0;
    init(&recovered);
    assert(vr_store_mount(&recovered) == VR_STORE_ERROR && recovered.error);
    uint64_t denied; assert(vr_store_begin(&recovered, 0, 0, 0, &denied) == VR_STORE_INVALID);
    blank(); record(1); record(1);
    /* Committed payload corruption is retained and blocks confirmation. */
    flash.bytes[2 * VR_STORE_SECTOR + 64 + 8] ^= 1;
    reboot(); assert(recovered.error && vr_store_count(&recovered) == 2);
    vr_store_meta_t m; assert(!vr_store_next(&recovered, 0, &m) && m.id==1 && (m.flags&2) && m.bytes==5 && m.frames==1);
    uint8_t out[8]; size_t n; assert(vr_store_fetch(&recovered,m.id,0,out,sizeof out,&n)==VR_STORE_ERROR);
    assert(!vr_store_next(&recovered,m.id,&m) && m.id==2); stream_check(&recovered,&m);
    assert(vr_store_confirm(&recovered, 1, 5, 0x7697dda0u) == VR_STORE_ERROR);
    blank();
    for (unsigned i = 1; i <= 120; ++i) {
        assert(record(1) == i); assert(!vr_store_next(&store, 0, &m)); assert(!vr_store_confirm(&store, m.id, m.bytes, m.crc));
    }
    reboot(); assert(recovered.allocated_id == 120 && !vr_store_count(&recovered)); assert(!vr_store_confirm(&recovered, 1, 0, 0));
    uint64_t id; assert(!vr_store_begin(&recovered, 0, 1, 0, &id)); assert(id == 121);
}
static void factory_partition(void) {
    memset(&flash,0,sizeof flash); init(&store);
    assert(!vr_store_mount(&store) && !store.error && !vr_store_count(&store));
    record(1); reboot(); assert(vr_store_count(&recovered)==1);
    /* A sector magic with no usable journal protects retained data. */
    memset(flash.bytes,0,2*VR_STORE_SECTOR); init(&recovered); saved=flash;
    assert(vr_store_mount(&recovered)==VR_STORE_ERROR);
    assert(!memcmp(saved.bytes,flash.bytes,BYTES));
}
static void header_body_retention(void) {
    /* An interrupted allocation writes only a header, never any frame body. */
    for (unsigned torn=0; torn<2; ++torn) {
        blank(); begin(0);
        if (torn) memset(flash.bytes+2*VR_STORE_SECTOR+22,255,42);
        else memset(flash.bytes+2*VR_STORE_SECTOR+44,255,4);
        flash.erases=0; reboot();
        assert(!recovered.error && flash.erases==1 && !vr_store_count(&recovered));
        uint64_t id; assert(!vr_store_begin(&recovered,0,0,0,&id) && id==2);
    }
    /* Invalid commit, garbage and erased headers must all retain dirty bodies. */
    for (unsigned damage=0; damage<4; ++damage) {
        blank(); record(1);
        uint8_t *sector=flash.bytes+2*VR_STORE_SECTOR;
        if (!damage) sector[44]^=1;
        else memset(sector,damage==2?255:0,64);
        if (damage==3) { memset(sector+64,255,VR_STORE_SECTOR-64); sector[VR_STORE_SECTOR-1]=0; }
        uint8_t before[VR_STORE_SECTOR]; memcpy(before,sector,sizeof before);
        flash.erases=0; reboot();
        assert(recovered.error && recovered.owners[2]==UINT16_MAX && !flash.erases);
        assert(!memcmp(before,sector,sizeof before));
    }
}
static void dirty_factory_flash(void) {
    memset(&flash,0,sizeof flash); memset(flash.bytes,255,BYTES);
    const unsigned dirty[]={0,3,SECTORS-1};
    for (unsigned i=0; i<3; ++i) flash.bytes[(dirty[i]+1)*VR_STORE_SECTOR-1]=0;
}
static void sparse_factory_format(void) {
    dirty_factory_flash(); saved=flash; init(&store);
    assert(!vr_store_mount(&store) && !store.error && !vr_store_count(&store));
    assert(flash.erases==3 && store.formatted_sectors==3);
    /* The entire magic scan precedes even the first dirty-sector erase. */
    flash=saved; const uint8_t magic[]={0x56,0x52,0x53,0x31};
    memcpy(flash.bytes+BYTES-4,magic,sizeof magic); init(&store);
    assert(vr_store_mount(&store)==VR_STORE_ERROR && !flash.erases);
    for (unsigned partial=0; partial<2; ++partial) for (unsigned cut=1; cut<=3; ++cut) {
        flash=saved; flash.cut=cut; flash.partial=partial; init(&store);
        assert(vr_store_mount(&store)==VR_STORE_ERROR);
        reboot(); assert(!recovered.error && !vr_store_count(&recovered));
        assert(recovered.boot_id==1 && recovered.allocated_id==0);
        for (unsigned at=48; at<BYTES; ++at) assert(flash.bytes[at]==255);
    }
}
int main(int argc, char **argv) {
    if(argc>1 && !strcmp(argv[1],"headers")) { header_body_retention(); return 0; }
    if(argc>1 && !strcmp(argv[1],"sparse")) { sparse_factory_format(); return 0; }
    if(argc>1 && !strcmp(argv[1],"factory")) { factory_partition(); return 0; }
    if(argc>1 && !strcmp(argv[1],"corruption")) { corruption_and_compaction(); return 0; }
    header_body_retention(); sparse_factory_format(); basic_resume_and_examples(); every_write_boundary(); torn_final_frame_and_off(); full_and_live_priority(); deletion_boundaries(); indexed_resume_reads(); corruption_and_compaction();
    puts("offline store: resume/CRC/metadata/full/OFF/preemption/delete/ID+boot persistence passed");
    return 0;
}
