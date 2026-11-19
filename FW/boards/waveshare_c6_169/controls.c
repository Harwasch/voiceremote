#include "controls.h"
#include <string.h>
bool c6_controls_decode(uint8_t raw,c6_controls_value_t *v)
{
    unsigned code=raw&3;
    *v=(c6_controls_value_t){.capture=code==3?1:code==2?2:0,
        .mode=!((raw>>2)&1), /* I/O board G2: P2 low = AI, high or open = TXT */.ptt=!(raw&8),.target=!(raw&16)};
    return code!=0;
}
static void publish(c6_controls_t *s,c6_controls_value_t v)
{
    if(v.capture!=s->value.capture || v.mode!=s->value.mode ||
       v.ptt!=s->value.ptt || v.target!=s->value.target) s->changed=true;
    s->value=v;
}
static void fail(c6_controls_t *s)
{
    publish(s,(c6_controls_value_t){.mode=s->value.mode});
    s->inhibited=true; s->ptt_ready=s->target_ready=false; s->tracking=false;
}
void c6_controls_sample(c6_controls_t *s,bool ok,uint8_t raw,bool irq_low,uint32_t now)
{
    raw&=31; s->attempted=true; s->polled_at=now; s->irq_low=irq_low;
    c6_controls_value_t v;
    if(!ok || !c6_controls_decode(raw,&v)) { fail(s); return; }
    s->last_read=now;
    if(!s->initialized) {
        s->initialized=true; s->baseline=raw&3;
        s->inhibited=v.capture==2;
        /* Initial held buttons never synthesize a deliberate press. */
        s->ptt_ready=!v.ptt; s->target_ready=!v.target;
    }
    if(v.capture==0) { /* OFF never waits for debounce. */
        c6_controls_value_t off={.mode=s->value.mode}; publish(s,off);
    }
    if(!s->tracking || raw!=s->candidate) {
        s->candidate=raw; s->since=now; s->tracking=true; return;
    }
    if((uint32_t)(now-s->since)<20) return;
    if((raw&3)!=s->baseline) { s->inhibited=false; s->baseline=raw&3; }
    if(!v.ptt) s->ptt_ready=true;
    if(!v.target) s->target_ready=true;
    v.ptt&=s->ptt_ready; v.target&=s->target_ready;
    if(s->inhibited) v.capture=0;
    publish(s,v);
}
void c6_controls_stale(c6_controls_t *s,uint32_t now)
{
    if(s->initialized && (uint32_t)(now-s->last_read)>=100) fail(s);
}
bool c6_controls_due(const c6_controls_t *s,uint32_t now)
{
    return !s->attempted || (uint32_t)(now-s->polled_at)>=
        (s->irq_low || !s->tracking || (uint32_t)(now-s->since)<20?10u:50u);
}
