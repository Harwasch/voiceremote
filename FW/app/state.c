#include "state.h"
#include <string.h>
bool vr_debounce(vr_debounce_t *d, uint8_t raw, uint32_t now, uint32_t *sampled)
{
    if(raw!=d->candidate) { d->candidate=raw; d->since=now; }
    if(d->stable==raw || (uint32_t)(now-d->since)<VR_DEBOUNCE_MS) return false;
    d->stable=raw; *sampled=d->since; return true;
}
void vr_session_reset(vr_state_t *s)
{
    vr_input_t physical=s->input;
    vr_debounce_t buttons[2]; memcpy(buttons,s->buttons,sizeof buttons);
    memset(s,0,sizeof *s); s->input=physical; s->input.seq=0; s->input.streaming=0;
    memcpy(s->buttons,buttons,sizeof buttons);
}
void vr_control(vr_state_t *s, uint8_t event, uint8_t value, uint32_t sampled)
{
    s->input.ms=sampled;
    if(event==VR_DOWN || event==VR_UP) s->input.ptt=value;
    if(event==VR_CAPTURE) s->input.capture=value;
    if(event==VR_MODE) s->input.mode=value;
    if(event==VR_CAPTURE || event==VR_MODE) { s->armed=false; s->controls_epoch++; }
}
vr_input_t vr_prepare_input(const vr_state_t *s, uint8_t event, uint32_t sampled)
{
    vr_input_t v=s->input; v.seq=s->next_seq; v.event=event; v.ms=sampled;
    v.streaming=0; /* Stage 1 has no audio path. */
    return v;
}
void vr_input_sent(vr_state_t *s, const vr_input_t *v, bool success)
{
    if(!success) { s->armed=false; s->snapshot_sent=false; return; }
    s->latest_seq=v->seq; s->next_seq=v->seq+1;
    if(v->event==VR_SNAPSHOT) s->snapshot_sent=true;
}
int vr_state_fragment(vr_state_t *s, const uint8_t *p, size_t n, vr_phone_t *candidate)
{
    if(n>=6 && !vr_get16(p+4)) s->fragment_epoch=s->controls_epoch;
    return vr_fragment(&s->fragments,p,n,candidate);
}
void vr_apply_phone(vr_state_t *s, const vr_phone_t *p)
{
    s->phone=*p; s->has_phone=true;
    s->armed=(p->flags&2) && s->secure && s->input_sub && s->audio_sub && s->info_read &&
        s->snapshot_sent && p->ack==s->latest_seq && s->input.capture!=VR_OFF &&
        s->fragment_epoch==s->controls_epoch;
    if(!s->armed) s->phone.flags &= (uint8_t)~2u;
}
bool vr_capture_gate(const vr_state_t *s)
{
    /* No lock field exists in v1 Phone state: fail closed for hold without PTT.
       This is a control-state gate only. Stage 1 never invokes an audio producer. */
    return s->armed && s->secure && s->input_sub && s->audio_sub && s->info_read && s->snapshot_sent &&
        s->has_phone && s->input.capture!=VR_OFF && s->phone.capture!=VR_OFF && s->phone.recording==1 &&
        (s->phone.capture!=VR_PTT || s->input.ptt);
}
