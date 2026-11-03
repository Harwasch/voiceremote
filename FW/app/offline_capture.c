#include "offline_capture.h"
static void end(vr_local_capture_t *p) { if(p->wanted) { p->wanted=false; p->epoch++; } }
static void start(vr_local_capture_t *p) { if(p->owner) { p->wanted=true; p->block_live=true; p->epoch++; } }
void vr_local_owner(vr_local_capture_t *p, bool owner)
{ p->owner=owner; if(!owner) { end(p); p->block_live=true; } }
void vr_local_session(vr_local_capture_t *p, bool usable) { p->usable=usable; }
void vr_local_disconnect(vr_local_capture_t *p, bool was_live)
{
    p->usable=false;
    if(was_live && (p->capture==VR_REC || (p->capture==VR_PTT && p->ptt))) start(p);
}
void vr_local_control(vr_local_capture_t *p, uint8_t event, uint8_t value)
{
    if(event==VR_UP) { p->ptt=0; if(p->capture==VR_PTT) end(p); p->block_live=false; }
    if(event==VR_DOWN) {
        bool fresh=!p->ptt; p->ptt=1;
        if(fresh && p->capture==VR_PTT) { p->block_live=false; if(!p->usable) start(p); }
    }
    if(event==VR_CAPTURE && value!=p->capture) {
        end(p); p->capture=value; p->block_live=false;
        if(value==VR_REC && !p->usable) start(p);
    }
    if(event==VR_MODE && value!=p->mode) {
        bool local=p->wanted; end(p); p->mode=value;
        if(p->capture==VR_REC && local) start(p);
        else if(p->capture==VR_PTT && p->ptt) p->block_live=true;
    }
    if(p->capture==VR_OFF) { end(p); p->block_live=false; }
}
void vr_local_failed(vr_local_capture_t *p) { end(p); p->block_live=true; }
