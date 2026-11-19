/* Purpose: Rev G digital input safety. Inputs: synthetic bytes/ticks.
 * Verified: host assertions; electrical bounce/IRQ timing unverified. */
#include "controls.h"
#include "storage.h"
#include <assert.h>
#include <stdio.h>
static void stable(c6_controls_t *s,uint8_t raw,uint32_t t)
{ c6_controls_sample(s,true,raw,false,t); c6_controls_sample(s,true,raw,false,t+20); }
int main(void)
{
    assert(c6_storage_fits(0x1000000,0x187000,0xe79000));
    assert(!c6_storage_fits(0x400000,0x187000,0xe79000));
    assert(!c6_storage_fits(0,0x187000,0xe79000));
    assert(!c6_storage_fits(UINT32_MAX,UINT32_MAX-10,20));
    assert(!c6_storage_fits(0x1000000,0,0));
    for(unsigned raw=0;raw<256;raw++) {
        c6_controls_value_t v; bool valid=c6_controls_decode(raw,&v);
        assert(valid==((raw&3)!=0));
        assert(v.capture==((raw&3)==3?1:(raw&3)==2?2:0));
        assert(v.mode==!((raw>>2)&1) && v.ptt==!(raw&8) && v.target==!(raw&16));
    }
    c6_controls_t s={0}; stable(&s,0x1e,0); /* REC at boot, no start. */
    assert(!s.value.capture && !s.value.ptt);
    stable(&s,0x1e,100); assert(!s.value.capture);
    stable(&s,0x1b,200); assert(s.value.capture==1);
    c6_controls_sample(&s,true,0x1e,false,230); assert(s.value.capture==1);
    c6_controls_sample(&s,true,0x1e,false,249); assert(s.value.capture==1);
    c6_controls_sample(&s,true,0x1e,false,250); assert(s.value.capture==2 && s.value.mode==0); /* P2 high: TXT */
    c6_controls_sample(&s,true,0x19,false,251); assert(!s.value.capture); /* immediate OFF */
    stable(&s,0x1b,300); assert(s.value.capture==1);
    c6_controls_sample(&s,true,0,false,330); assert(!s.value.capture && !s.value.ptt);
    stable(&s,0x1b,350); assert(!s.value.capture); /* failure recovery cannot restart */
    stable(&s,0x19,400); stable(&s,0x1b,450); assert(s.value.capture==1);
    stable(&s,0x13,500); assert(s.value.ptt);
    c6_controls_sample(&s,false,0,false,525); assert(!s.value.capture && !s.value.ptt);
    stable(&s,0x13,550); assert(!s.value.capture && !s.value.ptt);
    stable(&s,0x19,600); stable(&s,0x1b,650); stable(&s,0x13,700); assert(s.value.ptt);
    c6_controls_stale(&s,819); assert(s.value.ptt);
    c6_controls_stale(&s,820); assert(!s.value.capture && !s.value.ptt);
    /* Held boot buttons, both selectors and wraparound debounce. */
    s=(c6_controls_t){0}; stable(&s,3,UINT32_MAX-10); assert(!s.value.ptt && !s.value.target);
    stable(&s,0x1b,30); stable(&s,3,60); assert(s.value.ptt && s.value.target);
    /* Stuck INT causes bounded rereads, never a busy loop or false release. */
    c6_controls_sample(&s,true,3,true,100); assert(!c6_controls_due(&s,109));
    assert(c6_controls_due(&s,110));
    for(unsigned t=110;t<200;t+=10) c6_controls_sample(&s,true,3,true,t);
    assert(s.value.ptt && s.value.target && s.value.capture==1);
    puts("C6 controls: all codes, debounce, boot REC, failure/stale, held buttons, wrap, stuck INT pass");
}
