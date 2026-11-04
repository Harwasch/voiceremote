#pragma once
#include "protocol.h"
#define VR_AUDIO_SAMPLES 320
#define VR_AUDIO_BITRATE 24000 /* Starting point, throughput/quality unverified. */
#define VR_AUDIO_QUEUE 8
/* Pure bounded encoded-packet queue. Caller serializes access. */
typedef struct { uint16_t size, frame; uint8_t data[VR_MAX_PACKET]; } vr_packet_t;
typedef struct {
    vr_packet_t queue[VR_AUDIO_QUEUE];
    uint32_t segment;
    uint16_t frame, next_frame, offset, mtu;
    unsigned head, count, high_water, dropped;
    bool running, started, ending, exhausted;
} vr_stream_t;
bool vr_stream_begin(vr_stream_t *s);
bool vr_stream_push(vr_stream_t *s, const uint8_t *packet, size_t size);
/* Stop discards all queued data. Only an empty END can subsequently be emitted. */
void vr_stream_stop(vr_stream_t *s);
size_t vr_stream_peek(vr_stream_t *s, uint16_t mtu, uint8_t *out, size_t capacity);
void vr_stream_sent(vr_stream_t *s);
