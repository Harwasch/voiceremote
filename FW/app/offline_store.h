#pragma once
/* Purpose: bounded raw-flash recording journal; no ESP-IDF/PSRAM dependency.
 * Inputs: 4 KiB erase sectors, 1->0 writes, raw <=512-byte Opus packets.
 * Verified by fake-flash host tests; physical flash timing/wear unmeasured. */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#define VR_STORE_SECTOR 4096u
#define VR_STORE_MAX_SECTORS 4096u
#define VR_STORE_MAX_RECORDS 128u
#define VR_STORE_PACKET 512u
#define VR_STORE_META_SIZE 42u
/* Values intentionally match Offline result status bytes. */
enum { VR_STORE_OK, VR_STORE_END, VR_STORE_NOT_FOUND, VR_STORE_BUSY,
       VR_STORE_INVALID, VR_STORE_ERROR };
typedef struct {
    void *ctx;
    bool (*read)(void *ctx, uint32_t offset, void *data, size_t size);
    bool (*write)(void *ctx, uint32_t offset, const void *data, size_t size);
    bool (*erase)(void *ctx, uint32_t offset, size_t size);
} vr_store_flash_t;
typedef struct {
    uint64_t id;
    uint32_t boot;
    uint64_t tick, utc;
    uint8_t mode, flags;
    uint32_t bytes, frames, crc;
} vr_store_meta_t;
typedef struct {
    vr_store_meta_t meta;
    uint16_t first, last, sectors;
    bool used, finalized, corrupt;
} vr_store_record_t;
typedef struct {
    vr_store_flash_t flash;
    vr_store_record_t records[VR_STORE_MAX_RECORDS];
    /* 0 free, UINT16_MAX quarantined, otherwise record index + 1. */
    uint16_t owners[VR_STORE_MAX_SECTORS];
    uint32_t ordinals[VR_STORE_MAX_SECTORS];
    /* RAM-only export index, rebuilt at mount. Zero terminates a sector chain. */
    uint16_t next_sector[VR_STORE_MAX_SECTORS];
    uint16_t exported_bytes[VR_STORE_MAX_SECTORS];
    uint32_t sector_count, boot_id, pending_erase;
    uint32_t formatted_sectors; /* RAM-only count of completed factory erases this mount. */
    uint64_t allocated_id, journal_seq, pending_delete;
    uint16_t journal_sector, journal_slot, active_sector, active_offset;
    int active;
    uint32_t active_crc;
    bool mounted, error, full;
} vr_store_t;
/* init does no IO; mount recovers committed prefixes and durably allocates boot ID.
 * All calls serialize on the writer task. No API acquires audio or uses an RTOS. */
int vr_store_init(vr_store_t *s, vr_store_flash_t flash, uint32_t bytes);
int vr_store_mount(vr_store_t *s);
int vr_store_begin(vr_store_t *s, uint8_t mode, uint64_t tick, uint64_t utc, uint64_t *id);
int vr_store_append(vr_store_t *s, const uint8_t *packet, size_t size);
int vr_store_finish(vr_store_t *s, bool interrupted);
int vr_store_next(vr_store_t *s, uint64_t cursor, vr_store_meta_t *meta);
int vr_store_fetch(vr_store_t *s, uint64_t id, uint32_t offset,
                   uint8_t *data, size_t max, size_t *size);
int vr_store_confirm(vr_store_t *s, uint64_t id, uint32_t bytes, uint32_t crc);
uint32_t vr_store_count(const vr_store_t *s);
uint64_t vr_store_total(const vr_store_t *s);
uint64_t vr_store_free(const vr_store_t *s);
void vr_store_meta_encode(const vr_store_meta_t *meta, uint8_t out[VR_STORE_META_SIZE]);
uint32_t vr_store_crc32(const uint8_t *data, size_t size);
