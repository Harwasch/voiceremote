#pragma once
/* Rev G TCA9554 input policy; pure C, timestamps in wrapping milliseconds. */
#include <stdbool.h>
#include <stdint.h>
typedef struct {
    uint8_t capture, mode;
    bool ptt, target;
} c6_controls_value_t;
typedef struct {
    c6_controls_value_t value;
    uint8_t candidate, baseline;
    uint32_t since, last_read, polled_at;
    bool attempted, initialized, tracking, inhibited, ptt_ready, target_ready, changed, irq_low;
} c6_controls_t;
/* Invalid/failed/stale reads stop immediately. Recovery needs a selector change;
 * held buttons need an observed release. REC at boot never starts capture. */
bool c6_controls_decode(uint8_t raw, c6_controls_value_t *out);
void c6_controls_sample(c6_controls_t *s, bool ok, uint8_t raw, bool irq_low, uint32_t now);
void c6_controls_stale(c6_controls_t *s, uint32_t now);
bool c6_controls_due(const c6_controls_t *s, uint32_t now);
