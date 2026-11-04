#include "audio.h"
#include <string.h>
bool vr_stream_begin(vr_stream_t *s)
{
    if(s->running || s->ending || s->exhausted) return false;
    if(s->segment==UINT32_MAX) { s->exhausted=true; return false; }
    uint32_t id=s->segment+1;
    memset(s,0,sizeof *s); s->segment=id; s->running=true; return true;
}
void vr_stream_stop(vr_stream_t *s)
{
    s->running=false; s->dropped+=s->count;
    s->count=0; s->head=0; memset(s->queue,0,sizeof s->queue);
    /* END follows the last notification sent, not the discarded encoded tail.
     * A partially sent packet still consumes its wire sequence (client detects
     * its incomplete payload); an entirely unsent packet consumes none. */
    if(s->offset) s->frame++;
    s->offset=0; s->ending=s->started;
}
bool vr_stream_push(vr_stream_t *s,const uint8_t *p,size_t n)
{
    if(!s->running) return false;
    if(!p || !n || n>VR_MAX_PACKET || s->count==VR_AUDIO_QUEUE || s->next_frame==UINT16_MAX) {
        if(p && n && n<=VR_MAX_PACKET && s->next_frame<UINT16_MAX) s->next_frame++;
        s->dropped++; vr_stream_stop(s); return false;
    }
    vr_packet_t *q=&s->queue[(s->head+s->count)%VR_AUDIO_QUEUE];
    memcpy(q->data,p,n); q->size=n; q->frame=s->next_frame++;
    s->count++; if(s->count>s->high_water) s->high_water=s->count;
    return true;
}
size_t vr_stream_peek(vr_stream_t *s,uint16_t mtu,uint8_t *out,size_t capacity)
{
    if(s->ending) {
        vr_audio_t v={.segment=s->segment,.frame=s->frame,.flags=6};
        return vr_audio_encode(&v,VR_MAX_PACKET,out,capacity);
    }
    if(!s->running || !s->count || mtu<23) return 0;
    if(!s->offset) s->mtu=mtu; /* Freeze MTU for this frame. */
    vr_packet_t *q=&s->queue[s->head];
    size_t n=q->size-s->offset, budget=s->mtu-15;
    if(n>budget) n=budget;
    vr_audio_t v={.segment=s->segment,.frame=q->frame,.offset=s->offset,.total=q->size,
        .flags=(q->frame==0?1:0)|(s->offset+n==q->size?4:0),.payload=q->data+s->offset,.size=n};
    return vr_audio_encode(&v,VR_MAX_PACKET,out,capacity);
}
void vr_stream_sent(vr_stream_t *s)
{
    if(s->ending) { s->ending=false; return; }
    if(!s->running || !s->count) return;
    s->started=true;
    vr_packet_t *q=&s->queue[s->head];
    unsigned n=q->size-s->offset, budget=s->mtu-15;
    s->offset+=n>budget?budget:n;
    if(s->offset==q->size) {
        s->offset=0; s->head=(s->head+1)%VR_AUDIO_QUEUE; s->count--; s->frame=q->frame+1;
        if(s->frame==UINT16_MAX && !s->count) vr_stream_stop(s);
    }
}
