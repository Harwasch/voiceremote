#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <math.h>
#include <stddef.h>

typedef struct {
    int width, height;
    bool round, ring;
    float scale, ox, oy, cx, cy, radius, pips_y, baseline;
} vr_layout_t;
typedef enum {
    VR_HIT_NONE, VR_HIT_OFF, VR_HIT_PTT, VR_HIT_REC, VR_HIT_ORB,
    VR_HIT_TARGET, VR_HIT_CANCEL, VR_HIT_CONFIRM
} vr_hit_t;
static inline vr_layout_t vr_layout(uint16_t w,uint16_t h,bool round,bool ring)
{
    float rw=ring?466:240, rh=ring?466:280;
    float s=fminf(w/rw,h/rh);
    return (vr_layout_t){w,h,round,ring,s,(w-rw*s)/2,(h-rh*s)/2,
        ring?233:120,ring?233:112,ring?112:84,ring?368:222,ring?424:264};
}
/* The producer publishes this bit only after the first Audio notification. */
static inline bool vr_ui_listening(bool streaming) { return streaming; }
static inline bool vr_ui_inside(const vr_layout_t *l,float x,float y)
{
    if(x<0 || y<0 || x>=l->width || y>=l->height) return false;
    if(!l->round) return true;
    float dx=x-l->width/2.f,dy=y-l->height/2.f;
    float r=fminf(l->width,l->height)/2;
    return dx*dx+dy*dy<=r*r;
}
static inline vr_hit_t vr_ui_hit(const vr_layout_t *l,int px,int py,bool overlay)
{
    if(!vr_ui_inside(l,px,py)) return VR_HIT_NONE;
    float x=(px-l->ox)/l->scale,y=(py-l->oy)/l->scale;
    if(overlay) {
        float top=l->ring?300:180;
        if(y<top || x==l->cx) return VR_HIT_NONE;
        return x<l->cx?VR_HIT_CANCEL:VR_HIT_CONFIRM;
    }
    float dx=x-l->cx,dy=y-l->cy;
    if(dx*dx+dy*dy<=l->radius*l->radius) return VR_HIT_ORB;
    if(y>=(l->ring?384:236) && y<=(l->ring?450:278)) return VR_HIT_TARGET;
    if(l->ring) {
        float a=atan2f(dx,-dy)*180.f/3.14159265358979323846f;
        if(a>=-116 && a<=-50) return VR_HIT_OFF;
        if(a>=-29 && a<=29) return VR_HIT_PTT;
        if(a>=50 && a<=116) return VR_HIT_REC;
    }
    return VR_HIT_NONE;
}
/* Printable ASCII subset. One '?' per unsupported UTF-8 code point, not per byte. */
static inline void vr_ui_ascii(char *out,size_t cap,const char *in)
{
    size_t n=0;
    for(const unsigned char *p=(const unsigned char *)in; *p && n+1<cap; p++) {
        if(*p>=32 && *p<=126) out[n++]=(char)*p;
        else if((*p&0xc0)!=0x80) out[n++]='?';
    }
    if(cap) out[n]=0;
}
