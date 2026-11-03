#include "offline_capture.h"
#include <assert.h>
#include <stdio.h>
int main(void)
{
    vr_local_capture_t p={0};
    vr_local_control(&p,VR_CAPTURE,VR_REC); assert(!p.wanted); /* no owner */
    vr_local_owner(&p,true); assert(!p.wanted); /* enrollment/boot isn't a trigger */
    vr_local_control(&p,VR_CAPTURE,VR_OFF); vr_local_control(&p,VR_CAPTURE,VR_REC);
    assert(p.wanted && p.block_live); uint32_t e=p.epoch;
    vr_local_session(&p,true); assert(p.wanted); /* reconnect finishes locally */
    vr_local_control(&p,VR_MODE,1); assert(p.wanted && p.mode==1 && p.epoch>e);
    vr_local_control(&p,VR_CAPTURE,VR_OFF); assert(!p.wanted && !p.block_live);
    vr_local_control(&p,VR_CAPTURE,VR_REC); assert(!p.wanted); /* phone paused: usable, no offline fallback */
    vr_local_disconnect(&p,true); assert(p.wanted && p.mode==1);
    vr_local_failed(&p); assert(!p.wanted && p.block_live);
    vr_local_session(&p,false); assert(!p.wanted); /* space freed/reconnect never restarts */
    vr_local_control(&p,VR_CAPTURE,VR_PTT); vr_local_control(&p,VR_DOWN,1); assert(p.wanted);
    vr_local_control(&p,VR_MODE,0); assert(!p.wanted && p.block_live);
    vr_local_control(&p,VR_DOWN,1); assert(!p.wanted); /* must release after mode change */
    vr_local_control(&p,VR_UP,0); vr_local_control(&p,VR_DOWN,1); assert(p.wanted);
    vr_local_owner(&p,false); assert(!p.wanted); /* revoke */
    vr_local_owner(&p,true); vr_local_control(&p,VR_UP,0); vr_local_control(&p,VR_DOWN,1); assert(p.wanted);
    vr_local_control(&p,VR_CAPTURE,VR_OFF); assert(!p.wanted); /* OFF during offline */
    vr_local_control(&p,VR_CAPTURE,VR_PTT); vr_local_control(&p,VR_UP,0);
    vr_local_disconnect(&p,true); assert(!p.wanted); /* lock without physical PTT cannot continue */
    puts("offline capture: owner, triggers, mode, reconnect, full/failure, OFF pass");
}
