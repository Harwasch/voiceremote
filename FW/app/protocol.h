#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#define VR_MAJOR 1
#define VR_MINOR 0
#define VR_MAX_STATE 512
#define VR_INFO_SIZE 20
#define VR_INPUT_SIZE 14
#define VR_AUDIO_HEADER 12
#define VR_MAX_PACKET 512
#define VR_SERVICE_UUID "f934bb04-9472-4805-8ea8-11f9f5bcabbc"
#define VR_INFO_UUID "cba8d4dd-2aea-4964-a0b7-ef58095a1171"
#define VR_INPUT_UUID "9f0f839c-fe73-46e4-acc3-53518ed5689c"
#define VR_PHONE_UUID "d9306a59-9e64-48c5-8722-827a0592a412"
#define VR_AUDIO_UUID "6df454c4-b29c-4638-b4f5-cc43e81e2427"

enum { VR_OFF, VR_PTT, VR_REC };
enum { VR_SNAPSHOT, VR_DOWN, VR_UP, VR_CYCLE, VR_CAPTURE, VR_MODE };
typedef struct {
    uint16_t board, caps, width, height, max_packet;
    uint8_t fw[3], mics, slider;
} vr_info_t;
typedef struct {
    uint32_t seq, ms;
    uint8_t event, capture, mode, ptt, streaming;
} vr_input_t;
typedef struct {
    uint8_t flags, capture, recording, mode, count, active;
    uint32_t ack;
    char names[8][33], resolved[33], link[49], error[65];
} vr_phone_t;
typedef struct {
    uint8_t bytes[VR_MAX_STATE];
    uint16_t id, total, used;
    bool active;
} vr_fragments_t;
typedef struct {
    uint32_t segment;
    uint16_t frame, offset, total;
    uint8_t flags;
    const uint8_t *payload;
    size_t size;
} vr_audio_t;
uint16_t vr_get16(const uint8_t *p);
uint32_t vr_get32(const uint8_t *p);
void vr_put16(uint8_t *p, uint16_t v);
void vr_put32(uint8_t *p, uint32_t v);
bool vr_forward(uint32_t next, uint32_t previous);
bool vr_info_decode(const uint8_t *p, size_t n, vr_info_t *out);
bool vr_info_encode(const vr_info_t *v, uint8_t p[20]);
bool vr_input_decode(const uint8_t *p, size_t n, vr_input_t *out);
bool vr_input_encode(const vr_input_t *v, uint8_t p[14]);
bool vr_phone_decode(const uint8_t *p, size_t n, vr_phone_t *out);
size_t vr_phone_encode(const vr_phone_t *v, uint8_t p[512]);
/* -1 rejected/reset; 0 pending; 1 complete validated state. Previous display untouched. */
int vr_fragment(vr_fragments_t *f, const uint8_t *p, size_t n, vr_phone_t *out);
/* Audio transport framing; codec and notification policy live in audio modules. */
bool vr_audio_decode(const uint8_t *p, size_t n, uint16_t max_packet, vr_audio_t *out);
size_t vr_audio_encode(const vr_audio_t *v, uint16_t max_packet, uint8_t *p, size_t capacity);
