#pragma once
#include "layout.h"

/* Gesture state only: preview never changes capture/arm/streaming state. Once a
 * finger leaves its original hit zone, it cannot activate another zone. */
typedef struct { vr_hit_t hit; uint32_t since; bool down; } vr_ui_press_t;
static inline void vr_ui_press_cancel(vr_ui_press_t *p) { p->hit=VR_HIT_NONE; }
static inline vr_hit_t vr_ui_press_sample(vr_ui_press_t *p,bool down,vr_hit_t hit,uint32_t now)
{
    vr_hit_t released=VR_HIT_NONE;
    if(down && !p->down) { p->hit=hit; p->since=now; }
    else if(down && hit!=p->hit) vr_ui_press_cancel(p);
    else if(!down && p->down) { if(hit==p->hit) released=hit; vr_ui_press_cancel(p); }
    p->down=down;
    return released;
}
static inline uint8_t vr_ui_preview_capture(uint8_t capture,vr_hit_t hit)
{
    return hit>=VR_HIT_OFF && hit<=VR_HIT_REC ? hit-VR_HIT_OFF : capture;
}
static inline uint8_t vr_ui_preview_mode(uint8_t mode,vr_hit_t hit)
{
    return hit==VR_HIT_ORB ? !mode : mode;
}
