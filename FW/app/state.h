#pragma once
#include "protocol.h"
#define VR_DEBOUNCE_MS 25u

typedef struct { uint8_t stable, candidate; uint32_t since; } vr_debounce_t;
bool vr_debounce(vr_debounce_t *d, uint8_t raw, uint32_t now, uint32_t *sampled);
typedef struct {
    vr_input_t input;
    vr_phone_t phone;
    vr_fragments_t fragments;
    vr_debounce_t buttons[2];
    uint32_t next_seq, latest_seq, controls_epoch, fragment_epoch;
    uint32_t control_seq;
    bool audio_fault, recovery_release;
    bool secure, input_sub, audio_sub, info_read, snapshot_sent, has_phone, armed;
} vr_state_t;
/* Retain physical positions/levels across reconnect; erase all connection state. */
void vr_session_reset(vr_state_t *s);
void vr_control(vr_state_t *s, uint8_t event, uint8_t value, uint32_t sampled);
vr_input_t vr_prepare_input(const vr_state_t *s, uint8_t event, uint32_t sampled);
void vr_input_sent(vr_state_t *s, const vr_input_t *v, bool success);
int vr_state_fragment(vr_state_t *s, const uint8_t *p, size_t n, vr_phone_t *candidate);
void vr_apply_phone(vr_state_t *s, const vr_phone_t *p);
bool vr_capture_gate(const vr_state_t *s);
