#pragma once
#include "protocol.h"
/* Pure deliberate-trigger policy. No flash, RTOS or PSRAM dependency. */
typedef struct {
    bool owner, usable, wanted, block_live;
    uint8_t capture, mode, ptt;
    uint32_t epoch;
} vr_local_capture_t;
void vr_local_owner(vr_local_capture_t *p, bool owner);
void vr_local_session(vr_local_capture_t *p, bool usable);
void vr_local_disconnect(vr_local_capture_t *p, bool was_live);
void vr_local_control(vr_local_capture_t *p, uint8_t event, uint8_t value);
void vr_local_failed(vr_local_capture_t *p);
