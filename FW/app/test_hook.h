#pragma once
#include <stdbool.h>
#include <stdint.h>
/* Pure serial decoding; effects are applied at the ordinary sampled-input path. */
typedef struct { bool ptt; uint8_t capture; } vr_test_input_t;
enum { VR_TEST_SELECT=1, VR_TEST_HAPTIC=2, VR_TEST_REBOOT=4, VR_TEST_MODE=8 };
static inline unsigned vr_test_command(vr_test_input_t *s,char command)
{
    switch(command) {
    case 'o': s->capture=0; return VR_TEST_SELECT;
    case 'p': s->capture=1; return VR_TEST_SELECT;
    case 'r': s->capture=2; return VR_TEST_SELECT;
    case 'd': s->ptt=true; return 0;
    case 'u': s->ptt=false; return 0;
    case 't': return VR_TEST_MODE;
    case 'h': return VR_TEST_HAPTIC;
    case 'x': return VR_TEST_REBOOT;
    default: return 0;
    }
}
