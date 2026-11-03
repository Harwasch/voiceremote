#include "state.h"
#include "layout.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static unsigned checks;
#define CHECK(x) do { checks++; assert(x); } while(0)
static size_t unhex(const char *s,uint8_t *out)
{
    size_t n=0; unsigned v; int used;
    while(sscanf(s," %2x%n",&v,&used)==1) { out[n++]=v; s+=used; }
    return n;
}
static const char *example_i="01 00 ff ff 00 01 02 00 3f 00 01 01 f0 00 18 01 00 02 00 00";
static const char *examples_e[]={
    "2a 00 00 00 e8 03 00 00 00 01 01 00 00 00",
    "2a 00 00 00 e8 03 00 00 01 01 01 01 00 00",
    "2a 00 00 00 e8 03 00 00 02 01 01 00 00 00",
    "2a 00 00 00 e8 03 00 00 03 01 01 00 00 00",
    "2a 00 00 00 e8 03 00 00 04 01 01 00 00 00",
    "2a 00 00 00 e8 03 00 00 05 01 01 00 00 00"};
static const char *examples_p[]={
    "07 00 21 00 00 00 01 00 00 00 02 00 2a 00 00 00 04 41 75 74",
    "07 00 21 00 0e 00 6f 02 50 43 02 50 43 03 42 4c 45 07 4d 69",
    "07 00 21 00 1c 00 63 20 6f 66 66"};
static const char *examples_a[]={
    "78 56 34 12 00 00 01 00 00 00 0c 00 00 01 02 03 04 05 06 07",
    "78 56 34 12 00 00 05 00 08 00 0c 00 08 09 0a 0b",
    "78 56 34 12 01 00 06 00 00 00 00 00"};
static vr_phone_t fixture(void)
{
    vr_fragments_t f={0}; vr_phone_t p;
    for(unsigned i=0;i<3;i++) {
        uint8_t bytes[20]; size_t n=unhex(examples_p[i],bytes);
        CHECK(vr_fragment(&f,bytes,n,&p)==(i==2?1:0));
    }
    return p;
}
static void examples(void)
{
    uint8_t bytes[512],encoded[512];
    size_t n=unhex(example_i,bytes); vr_info_t info;
    CHECK(n==20 && vr_info_decode(bytes,n,&info)); CHECK(vr_info_encode(&info,encoded)); CHECK(!memcmp(bytes,encoded,n));
    CHECK(info.board==65535 && info.width==240 && info.height==280 && info.max_packet==512);
    for(unsigned i=0;i<6;i++) {
        n=unhex(examples_e[i],bytes); vr_input_t event;
        CHECK(n==14 && vr_input_decode(bytes,n,&event)); CHECK(event.event==i);
        CHECK(vr_input_encode(&event,encoded)); CHECK(!memcmp(bytes,encoded,n));
    }
    vr_phone_t phone=fixture(); CHECK(phone.ack==42 && phone.count==2 && !strcmp(phone.error,"Mic off"));
    n=vr_phone_encode(&phone,encoded); CHECK(n==33);
    size_t offset=0;
    for(unsigned i=0;i<3;i++) {
        size_t len=unhex(examples_p[i],bytes);
        CHECK(vr_get16(bytes)==7 && vr_get16(bytes+2)==n && vr_get16(bytes+4)==offset);
        CHECK(!memcmp(encoded+offset,bytes+6,len-6)); offset+=len-6;
    }
    for(unsigned i=0;i<3;i++) {
        n=unhex(examples_a[i],bytes); vr_audio_t a;
        CHECK(vr_audio_decode(bytes,n,512,&a)); CHECK(vr_audio_encode(&a,512,encoded,sizeof encoded)==n);
        CHECK(!memcmp(bytes,encoded,n));
    }
}
static void invalid_fixed(void)
{
    uint8_t b[512]; vr_info_t info; vr_input_t input; vr_audio_t audio;
    size_t n=unhex(example_i,b);
    for(size_t i=0;i<n;i++) CHECK(!vr_info_decode(b,i,&info));
    const unsigned fields[]={0,1,7,9,11,18,19};
    for(unsigned i=0;i<sizeof fields/sizeof fields[0];i++) {
        unhex(example_i,b); b[fields[i]]=255; CHECK(!vr_info_decode(b,n,&info));
    }
    unhex(example_i,b); b[10]=0; CHECK(!vr_info_decode(b,n,&info));
    b[10]=1; b[16]=1; b[17]=16; CHECK(!vr_info_decode(b,n,&info));
    for(unsigned i=0;i<6;i++) {
        n=unhex(examples_e[i],b);
        for(size_t k=0;k<n;k++) CHECK(!vr_input_decode(b,k,&input));
        for(unsigned k=8;k<14;k++) {
            unhex(examples_e[i],b); b[k]=255; CHECK(!vr_input_decode(b,n,&input));
        }
    }
    unhex(examples_e[1],b); b[11]=0; CHECK(!vr_input_decode(b,14,&input));
    unhex(examples_e[2],b); b[11]=1; CHECK(!vr_input_decode(b,14,&input));
    for(unsigned i=0;i<3;i++) {
        n=unhex(examples_a[i],b);
        for(size_t k=0;k<12;k++) CHECK(!vr_audio_decode(b,k,512,&audio));
        for(unsigned k=6;k<12;k++) {
            unhex(examples_a[i],b); b[k]=255; if(k==10) { b[10]=1; b[11]=2; } CHECK(!vr_audio_decode(b,n,512,&audio));
        }
        unhex(examples_a[i],b); memset(b,0,4); CHECK(!vr_audio_decode(b,n,512,&audio));
    }
    unhex(examples_a[0],b); CHECK(!vr_audio_decode(b,20,11,&audio));
    CHECK(!vr_audio_decode(b,20,4097,&audio)); b[6]|=4; CHECK(!vr_audio_decode(b,20,512,&audio));
    unhex(examples_a[1],b); b[6]&=~4; CHECK(!vr_audio_decode(b,16,512,&audio));
    b[6]=4; CHECK(!vr_audio_decode(b,16,512,&audio)); /* frame zero must START */
    unhex(examples_a[0],b); b[4]=1; CHECK(!vr_audio_decode(b,20,512,&audio));
    unhex(examples_a[2],b); b[4]=0; CHECK(!vr_audio_decode(b,12,512,&audio));
    unhex(examples_a[0],b); vr_put16(b+4,65535); b[6]=0; CHECK(!vr_audio_decode(b,20,512,&audio));
}
static void invalid_phone(void)
{
    vr_phone_t p=fixture(),out; uint8_t b[512],good[512]; size_t n=vr_phone_encode(&p,good);
    for(size_t i=0;i<n;i++) CHECK(!vr_phone_decode(good,i,&out));
    const unsigned fields[]={0,1,2,3,4,5,10,15,18,21,25};
    for(unsigned i=0;i<sizeof fields/sizeof fields[0];i++) {
        memcpy(b,good,n); b[fields[i]]=255; CHECK(!vr_phone_decode(b,n,&out));
    }
    memcpy(b,good,n); b[n]=0; CHECK(!vr_phone_decode(b,n+1,&out));
    memcpy(b,good,n); b[11]='a'; CHECK(!vr_phone_decode(b,n,&out));
    memcpy(b,good,n); b[5]=1; b[19]='X'; CHECK(!vr_phone_decode(b,n,&out));
    /* Reject invalid UTF-8 (overlong, surrogate, >U+10FFFF, continuation, truncation), controls. */
    const char *bad[]={"\xc0\x80","\xed\xa0\x80","\xf4\x90\x80\x80","\x80","\xe2\x82","a\n","\xc2\x85"};
    for(unsigned i=0;i<sizeof bad/sizeof bad[0];i++) { p=fixture(); strcpy(p.error,bad[i]); CHECK(!vr_phone_encode(&p,b)); }
    p=fixture(); strcpy(p.error,"\xf0\x9f\x8e\x99"); CHECK(vr_phone_encode(&p,b)>0);
    p=fixture(); p.flags=2; CHECK(!vr_phone_encode(&p,b));
    p.flags=0; p.recording=1; CHECK(!vr_phone_encode(&p,b));
    p.capture=1; p.flags=2; CHECK(vr_phone_encode(&p,b)>0);
    for(unsigned r=0;r<=3;r++) { p.recording=r; CHECK((vr_phone_encode(&p,b)>0)==(r==1)); }
    p=fixture(); p.count=8;
    for(unsigned i=1;i<8;i++) { memset(p.names[i],'T',32); p.names[i][32]=0; }
    memset(p.resolved,'R',32); p.resolved[32]=0;
    memset(p.link,'L',48); p.link[48]=0; memset(p.error,'E',64); p.error[64]=0;
    CHECK(vr_phone_encode(&p,b)==393); CHECK(vr_phone_decode(b,393,&out));
    p.count=9; CHECK(!vr_phone_encode(&p,b));
}
static void fragments(void)
{
    vr_phone_t p=fixture(),out=fixture(); uint8_t logical[512],b[518]; size_t n=vr_phone_encode(&p,logical);
    for(unsigned split=1;split<n;split++) {
        vr_fragments_t f={0}; vr_put16(b,65535); vr_put16(b+2,n); vr_put16(b+4,0);
        memcpy(b+6,logical,split); CHECK(vr_fragment(&f,b,split+6,&out)==0);
        CHECK(!strcmp(out.error,"Mic off"));
        vr_put16(b+4,split); memcpy(b+6,logical+split,n-split);
        CHECK(vr_fragment(&f,b,n-split+6,&out)==1); CHECK(out.ack==42);
        CHECK(vr_fragment(&f,b,n-split+6,&out)==-1); /* duplicate final rejected */
    }
    vr_fragments_t f={0};
    for(size_t i=0;i<7;i++) CHECK(vr_fragment(&f,b,i,&out)==-1);
    vr_put16(b,7); vr_put16(b+2,513); vr_put16(b+4,0); CHECK(vr_fragment(&f,b,7,&out)==-1);
    vr_put16(b+2,18); CHECK(vr_fragment(&f,b,7,&out)==-1);
    vr_put16(b+2,n); memcpy(b+6,logical,n);
    CHECK(vr_fragment(&f,b,20,&out)==0);
    vr_put16(b+4,15); CHECK(vr_fragment(&f,b,7,&out)==-1); /* gap */
    vr_put16(b+4,0); CHECK(vr_fragment(&f,b,20,&out)==0);
    vr_put16(b+4,13); CHECK(vr_fragment(&f,b,7,&out)==-1); /* overlap */
    vr_put16(b+4,0); CHECK(vr_fragment(&f,b,20,&out)==0);
    vr_put16(b,8); vr_put16(b+4,14); CHECK(vr_fragment(&f,b,7,&out)==-1);
    vr_put16(b+4,0); memcpy(b+6,logical,n); CHECK(vr_fragment(&f,b,20,&out)==0);
    vr_put16(b,0); CHECK(vr_fragment(&f,b,n+6,&out)==1); /* offset zero replaces, including ID wrap */
    vr_put16(b+4,65535); CHECK(vr_fragment(&f,b,7,&out)==-1);
    vr_put16(b+4,0); CHECK(vr_fragment(&f,b,n+7,&out)==-1);
    b[6]=255; CHECK(vr_fragment(&f,b,n+6,&out)==-1); CHECK(out.flags==1); /* atomic previous retained */
}
static vr_state_t ready(void)
{
    vr_state_t s={0}; s.secure=s.input_sub=s.audio_sub=s.info_read=true;
    vr_control(&s,VR_CAPTURE,VR_PTT,1);
    vr_control(&s,VR_DOWN,1,1);
    vr_input_t v=vr_prepare_input(&s,VR_SNAPSHOT,2); vr_input_sent(&s,&v,true);
    return s;
}
static void apply(vr_state_t *s,vr_phone_t *p)
{
    uint8_t b[518]; size_t n=vr_phone_encode(p,b+6); CHECK(n>0);
    vr_put16(b,1); vr_put16(b+2,n); vr_put16(b+4,0); vr_phone_t candidate;
    CHECK(vr_state_fragment(s,b,n+6,&candidate)==1); vr_apply_phone(s,&candidate);
}
static void arming(void)
{
    vr_state_t s=ready(); vr_phone_t p=fixture(); p.capture=1; p.recording=1; p.flags=2; p.ack=s.latest_seq;
    apply(&s,&p); CHECK(s.armed && vr_capture_gate(&s));
    vr_control(&s,VR_UP,0,3); CHECK(!vr_capture_gate(&s));
    vr_control(&s,VR_DOWN,1,4); CHECK(vr_capture_gate(&s));
    p.ack--; strcpy(p.resolved,"iPhone"); apply(&s,&p);
    CHECK(!s.armed && !strcmp(s.phone.resolved,"iPhone"));
    p.ack=s.latest_seq; apply(&s,&p); CHECK(s.armed);
    vr_control(&s,VR_MODE,1,3); CHECK(!s.armed);
    vr_input_t v=vr_prepare_input(&s,VR_MODE,3); vr_input_sent(&s,&v,true);
    apply(&s,&p); CHECK(!s.armed); p.ack=s.latest_seq; apply(&s,&p); CHECK(s.armed);
    vr_control(&s,VR_CAPTURE,VR_OFF,4); v=vr_prepare_input(&s,VR_CAPTURE,4); vr_input_sent(&s,&v,true);
    CHECK(!s.armed); p.ack=s.latest_seq; apply(&s,&p); CHECK(!s.armed && !vr_capture_gate(&s));
    vr_control(&s,VR_CAPTURE,VR_REC,5); v=vr_prepare_input(&s,VR_CAPTURE,5); vr_input_sent(&s,&v,true);
    apply(&s,&p); CHECK(!s.armed); p.ack=s.latest_seq; apply(&s,&p); CHECK(s.armed);
    /* A transaction started before a control transition cannot arm, even with guessed ack. */
    uint8_t b[518]; p.ack=s.next_seq; size_t n=vr_phone_encode(&p,b+6);
    vr_put16(b,1); vr_put16(b+2,n); vr_put16(b+4,0); vr_phone_t candidate;
    CHECK(vr_state_fragment(&s,b,20,&candidate)==0);
    vr_control(&s,VR_MODE,0,6); v=vr_prepare_input(&s,VR_MODE,6); vr_input_sent(&s,&v,true);
    memmove(b+6,b+20,n-14); vr_put16(b+4,14);
    CHECK(vr_state_fragment(&s,b,n-14+6,&candidate)==1); vr_apply_phone(&s,&candidate); CHECK(!s.armed);
    for(unsigned i=0;i<5;i++) {
        s=ready(); p.ack=s.latest_seq;
        if(i==0) s.secure=false;
        if(i==1) s.input_sub=false;
        if(i==2) s.audio_sub=false;
        if(i==3) s.info_read=false;
        if(i==4) s.snapshot_sent=false;
        apply(&s,&p); CHECK(!s.armed);
    }
    s=ready(); p.ack=s.latest_seq; apply(&s,&p); CHECK(s.armed);
    p.flags=0; p.recording=2; apply(&s,&p); CHECK(!s.armed);
    s=ready(); vr_input_sent(&s,&v,false); CHECK(!s.snapshot_sent);
    vr_session_reset(&s); CHECK(!s.secure && !s.has_phone && !s.fragments.active && s.next_seq==0 && s.input.capture==VR_PTT);
    s=ready(); s.next_seq=UINT32_MAX; v=vr_prepare_input(&s,VR_SNAPSHOT,UINT32_MAX); vr_input_sent(&s,&v,true);
    CHECK(s.next_seq==0 && s.latest_seq==UINT32_MAX);
    v=vr_prepare_input(&s,VR_DOWN,0); CHECK(v.seq==0 && v.ms==0); vr_input_sent(&s,&v,true); CHECK(s.next_seq==1);
    CHECK(vr_forward(0,UINT32_MAX)); CHECK(!vr_forward(UINT32_MAX,0)); CHECK(!vr_forward(0,0));
    CHECK(!vr_forward(0x80000000u,0)); CHECK(vr_forward(0x7fffffffu,0));
}
static void debounce(void)
{
    vr_debounce_t d={0}; uint32_t sampled=0;
    CHECK(!vr_debounce(&d,true,100,&sampled)); CHECK(!vr_debounce(&d,false,110,&sampled));
    CHECK(!vr_debounce(&d,true,120,&sampled)); CHECK(!vr_debounce(&d,true,144,&sampled));
    CHECK(vr_debounce(&d,true,145,&sampled) && sampled==120 && d.stable);
    CHECK(!vr_debounce(&d,true,1000,&sampled)); CHECK(!vr_debounce(&d,false,UINT32_MAX-10,&sampled));
    CHECK(vr_debounce(&d,false,14,&sampled) && sampled==UINT32_MAX-10 && !d.stable);
    CHECK(!vr_debounce(&d,VR_REC,100,&sampled));
    CHECK(vr_debounce(&d,VR_REC,125,&sampled) && d.stable==VR_REC && sampled==100);
    CHECK(!vr_debounce(&d,VR_PTT,140,&sampled));
    CHECK(!vr_debounce(&d,VR_OFF,145,&sampled));
    CHECK(vr_debounce(&d,VR_OFF,170,&sampled) && d.stable==VR_OFF && sampled==145);
}
static void layout(void)
{
    vr_layout_t r=vr_layout(466,466,true);
    CHECK(r.row>=30 && r.x>0 && r.y>0 && r.y+9*r.row<=466-r.y);
    int dx=2*r.x-466,dy=2*r.y-466;
    CHECK(dx*dx+dy*dy<466*466); /* outer corner within round panel */
    r=vr_layout(240,280,false);
    CHECK(r.width==224 && r.row>=28 && r.x+r.width<=240 && r.y+9*r.row<=280);
}
int main(void)
{
    examples(); invalid_fixed(); invalid_phone(); fragments(); arming(); debounce(); layout();
    printf("%u checks passed: contract examples, validation, fragments, wrap, arm/OFF, debounce\n",checks);
}
