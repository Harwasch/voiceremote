/* Purpose: exercise the production bounded transport with synthetic/fake codec
 * output. Inputs: contract framing/gates. Verified by this executable + Python
 * round trips; contains no captured audio. */
#include "audio.h"
#include "state.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned checks;
#define CHECK(x) do { checks++; assert(x); } while(0)
static unsigned fake_calls;
static int fake_encoder(const int16_t *pcm,uint8_t *packet)
{
    fake_calls++; for(unsigned i=0;i<60;i++) packet[i]=(uint8_t)(pcm[0]+i);
    return 60;
}
static bool produce(vr_state_t *state,vr_stream_t *stream)
{
    int16_t pcm[320]={0}; uint8_t packet[512];
    if(!vr_capture_gate(state)) return false;
    return vr_stream_push(stream,packet,fake_encoder(pcm,packet));
}
static vr_state_t ready(void)
{
    vr_state_t s={0};
    s.secure=s.input_sub=s.audio_sub=s.info_read=s.snapshot_sent=s.has_phone=s.armed=true;
    s.input.capture=VR_PTT; s.input.ptt=1; s.phone.capture=VR_PTT; s.phone.recording=1;
    return s;
}
static void framing(unsigned mtu)
{
    vr_stream_t s={0}; CHECK(vr_stream_begin(&s));
    vr_state_t state=ready(); CHECK(produce(&state,&s)); CHECK(produce(&state,&s));
    uint8_t value[524]; unsigned packets=0,offset=0,fragments=0;
    while(s.count) {
        size_t n=vr_stream_peek(&s,mtu,value,sizeof value); vr_audio_t a;
        CHECK(n>12 && n<=mtu-3 && vr_audio_decode(value,n,512,&a));
        CHECK(a.segment==1 && a.frame==packets && a.offset==offset && a.total==60);
        CHECK(!!(a.flags&1)==(packets==0));
        CHECK(!!(a.flags&4)==(offset+a.size==60));
        for(unsigned i=0;i<a.size;i++) CHECK(a.payload[i]==offset+i);
        offset+=a.size; fragments++;
        if(a.flags&4) { packets++; offset=0; }
        vr_stream_sent(&s);
    }
    CHECK(packets==2 && fragments==(mtu==23?16u:2u));
    vr_stream_stop(&s); CHECK(s.ending);
    size_t n=vr_stream_peek(&s,mtu,value,sizeof value); vr_audio_t a;
    CHECK(n==12 && vr_audio_decode(value,n,512,&a)); CHECK(a.flags==6 && a.frame==2);
    vr_stream_sent(&s); CHECK(!vr_stream_peek(&s,mtu,value,sizeof value));
    CHECK(vr_stream_begin(&s) && s.segment==2);
    vr_stream_stop(&s); CHECK(!s.ending); /* Never END an empty segment. */
}
static void gating_and_overflow(void)
{
    vr_state_t state=ready(); vr_stream_t s={0}; CHECK(vr_stream_begin(&s));
    unsigned before=fake_calls;
    state.input.ptt=0; CHECK(!produce(&state,&s));
    state.phone.capture=VR_REC; CHECK(!produce(&state,&s)); /* local hold wins */
    state.input.capture=VR_REC; CHECK(produce(&state,&s));
    state.armed=false; CHECK(!produce(&state,&s)); state.armed=true;
    state.input.capture=VR_OFF; CHECK(!produce(&state,&s));
    CHECK(fake_calls==before+1);
    state.input.capture=VR_REC;
    uint8_t bytes[524]; CHECK(vr_stream_peek(&s,23,bytes,sizeof bytes)==20); vr_stream_sent(&s);
    for(unsigned i=1;i<VR_AUDIO_QUEUE;i++) CHECK(produce(&state,&s));
    CHECK(s.high_water==VR_AUDIO_QUEUE);
    CHECK(!produce(&state,&s)); CHECK(!s.running && !s.count && s.ending);
    CHECK(s.dropped==VR_AUDIO_QUEUE+1);
    vr_audio_t end; CHECK(vr_stream_peek(&s,23,bytes,sizeof bytes)==12);
    CHECK(vr_audio_decode(bytes,12,512,&end) && end.flags==6 && end.frame==1);
    CHECK(!vr_stream_begin(&s)); vr_stream_sent(&s); CHECK(vr_stream_begin(&s));
    CHECK(produce(&state,&s)); CHECK(vr_stream_peek(&s,247,bytes,sizeof bytes)==72); vr_stream_sent(&s);
    CHECK(produce(&state,&s));
    vr_control(&state,VR_CAPTURE,VR_OFF,10); vr_stream_stop(&s);
    CHECK(!produce(&state,&s)); CHECK(vr_stream_peek(&s,247,bytes,sizeof bytes)==12);
    CHECK(vr_audio_decode(bytes,12,512,&end) && end.frame==1); /* Dropped queued tail consumes no wire sequence. */
    vr_stream_sent(&s); CHECK(!vr_stream_peek(&s,247,bytes,sizeof bytes)); /* OFF: no flush */
    state=ready(); state.audio_fault=true; state.recovery_release=false;
    CHECK(!vr_capture_gate(&state)); vr_control(&state,VR_DOWN,1,11); CHECK(state.audio_fault);
    vr_control(&state,VR_UP,0,12); vr_control(&state,VR_DOWN,1,13); CHECK(!state.audio_fault);
    state.audio_fault=true; vr_control(&state,VR_CAPTURE,VR_REC,14); CHECK(!state.audio_fault && !state.armed);
    /* Changing MTU applies at the following frame boundary. */
    memset(&s,0,sizeof s); CHECK(vr_stream_begin(&s)); uint8_t packet[12]={0};
    CHECK(vr_stream_push(&s,packet,12)); CHECK(vr_stream_peek(&s,23,bytes,sizeof bytes)==20); vr_stream_sent(&s);
    CHECK(vr_stream_peek(&s,247,bytes,sizeof bytes)==16); vr_stream_sent(&s);
    CHECK(vr_stream_push(&s,packet,12)); CHECK(vr_stream_peek(&s,247,bytes,sizeof bytes)==24); vr_stream_sent(&s);
    /* Finish at 65534; only END may use sequence 65535. */
    s.next_frame=65534; CHECK(vr_stream_push(&s,packet,12));
    CHECK(vr_stream_peek(&s,247,bytes,sizeof bytes)==24); vr_stream_sent(&s);
    CHECK(!s.running && s.ending); CHECK(vr_stream_peek(&s,23,bytes,sizeof bytes)==12);
    CHECK(vr_audio_decode(bytes,12,512,&end) && end.frame==65535); vr_stream_sent(&s);
    s.segment=UINT32_MAX; CHECK(!vr_stream_begin(&s) && s.exhausted);
}
static void fixture(unsigned mtu,const char *hex,bool drop)
{
    uint8_t packet[512],bytes[524]; size_t n=0;
    if(hex) {
        while(*hex) { unsigned v; assert(n<512 && sscanf(hex,"%2x",&v)==1); packet[n++]=v; hex+=2; }
    } else for(;n<60;n++) packet[n]=(uint8_t)n;
    vr_stream_t s={0}; assert(vr_stream_begin(&s));
    for(unsigned frame=0;frame<3;frame++) {
        assert(vr_stream_push(&s,packet,n));
        while(s.count) {
            size_t len=vr_stream_peek(&s,mtu,bytes,sizeof bytes); assert(len);
            putchar(len&255); putchar(len>>8); assert(fwrite(bytes,1,len,stdout)==len); vr_stream_sent(&s);
        }
    }
    if(drop) assert(vr_stream_push(&s,packet,n)); /* Encoded but never sent. */
    vr_stream_stop(&s); size_t len=vr_stream_peek(&s,mtu,bytes,sizeof bytes); assert(len==12);
    putchar(len); putchar(0); assert(fwrite(bytes,1,len,stdout)==len);
}
int main(int argc,char **argv)
{
    if(argc>=3 && !strcmp(argv[1],"--fixture")) { fixture(atoi(argv[2]),argc>3?argv[3]:NULL,false); return 0; }
    if(argc>=3 && !strcmp(argv[1],"--fixture-drop")) { fixture(atoi(argv[2]),NULL,true); return 0; }
    framing(23); framing(247); gating_and_overflow();
    printf("Audio: %u checks passed (fake encoder, MTU23/247, flags, gates, OFF, overflow, wrap).\n",checks);
}
