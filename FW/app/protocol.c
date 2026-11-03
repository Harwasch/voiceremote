#include "protocol.h"
#include <string.h>

uint16_t vr_get16(const uint8_t *p) { return p[0] | (uint16_t)p[1] << 8; }
uint32_t vr_get32(const uint8_t *p) { return vr_get16(p) | (uint32_t)vr_get16(p+2) << 16; }
void vr_put16(uint8_t *p, uint16_t v) { p[0]=v; p[1]=v>>8; }
void vr_put32(uint8_t *p, uint32_t v) { vr_put16(p,v); vr_put16(p+2,v>>16); }
bool vr_forward(uint32_t n, uint32_t p) { uint32_t d=n-p; return d && d<UINT32_C(0x80000000); }

static bool info_valid(const vr_info_t *v)
{
    return (v->board==1 || v->board==2 || v->board==65535) && !(v->caps & ~127u) &&
        v->mics && v->slider<=1 && v->max_packet && v->max_packet<=4096 &&
        ((v->caps & 2) ? (v->width && v->height) : (!v->width && !v->height));
}
bool vr_info_decode(const uint8_t *p, size_t n, vr_info_t *out)
{
    if(n!=20 || p[0]!=1 || p[1]!=0 || p[7] || p[18] || p[19]) return false;
    vr_info_t v={.board=vr_get16(p+2), .caps=vr_get16(p+8), .mics=p[10], .slider=p[11],
        .width=vr_get16(p+12), .height=vr_get16(p+14), .max_packet=vr_get16(p+16)};
    memcpy(v.fw,p+4,3);
    if(!info_valid(&v)) return false;
    *out=v; return true;
}
bool vr_info_encode(const vr_info_t *v, uint8_t p[20])
{
    if(!info_valid(v)) return false;
    memset(p,0,20); p[0]=1; vr_put16(p+2,v->board); memcpy(p+4,v->fw,3);
    vr_put16(p+8,v->caps); p[10]=v->mics; p[11]=v->slider;
    vr_put16(p+12,v->width); vr_put16(p+14,v->height); vr_put16(p+16,v->max_packet); return true;
}
static bool input_valid(const vr_input_t *v)
{
    return v->event<=5 && v->capture<=2 && v->mode<=1 && v->ptt<=1 && v->streaming<=1 &&
        (v->event!=VR_DOWN || v->ptt==1) && (v->event!=VR_UP || v->ptt==0) &&
        (v->capture!=VR_OFF || !v->streaming);
}
bool vr_input_decode(const uint8_t *p, size_t n, vr_input_t *out)
{
    if(n!=14 || p[13]) return false;
    vr_input_t v={vr_get32(p),vr_get32(p+4),p[8],p[9],p[10],p[11],p[12]};
    if(!input_valid(&v)) return false;
    *out=v; return true;
}
bool vr_input_encode(const vr_input_t *v, uint8_t p[14])
{
    if(!input_valid(v)) return false;
    vr_put32(p,v->seq); vr_put32(p+4,v->ms);
    p[8]=v->event; p[9]=v->capture; p[10]=v->mode; p[11]=v->ptt; p[12]=v->streaming; p[13]=0; return true;
}
/* Reject overlong encodings, surrogates, out-of-range scalars and C0/C1 controls. */
static bool text_valid(const uint8_t *p, size_t n)
{
    for(size_t i=0;i<n;) {
        uint32_t c=p[i++], min=0; unsigned more=0;
        if(c>=0xc2 && c<=0xdf) { c&=31; more=1; min=0x80; }
        else if(c>=0xe0 && c<=0xef) { c&=15; more=2; min=0x800; }
        else if(c>=0xf0 && c<=0xf4) { c&=7; more=3; min=0x10000; }
        else if(c>=0x80) return false;
        if(n-i<more) return false;
        while(more--) { uint8_t b=p[i++]; if((b&0xc0)!=0x80) return false; c=(c<<6)|(b&63); }
        if(c<min || c>0x10ffff || (c>=0xd800 && c<=0xdfff) || c<32 || (c>=127 && c<=159)) return false;
    }
    return true;
}
static bool read_text(const uint8_t *p, size_t n, size_t *at, char *s, size_t max, bool empty)
{
    if(*at>=n) return false;
    size_t len=p[(*at)++];
    if(len>max || (!empty && !len) || len>n-*at || !text_valid(p+*at,len)) return false;
    memcpy(s,p+*at,len); s[len]=0; *at+=len; return true;
}
bool vr_phone_decode(const uint8_t *p, size_t n, vr_phone_t *out)
{
    if(n<19 || n>512 || (p[0]&~3u) || p[1]>2 || p[2]>3 || p[3]>1 || !p[4] || p[4]>8 || p[5]>=p[4]) return false;
    if((p[1]==0 && (p[2]==1 || (p[0]&2))) || ((p[0]&2) && (p[1]==0 || p[2]!=1))) return false;
    vr_phone_t v={.flags=p[0],.capture=p[1],.recording=p[2],.mode=p[3],.count=p[4],.active=p[5],.ack=vr_get32(p+6)};
    size_t at=10;
    for(unsigned i=0;i<v.count;i++) if(!read_text(p,n,&at,v.names[i],32,false)) return false;
    if(strcmp(v.names[0],"Auto") || !read_text(p,n,&at,v.resolved,32,false) ||
        !read_text(p,n,&at,v.link,48,true) || !read_text(p,n,&at,v.error,64,true) || at!=n ||
        (v.active && strcmp(v.resolved,v.names[v.active]))) return false;
    *out=v; return true;
}
static bool write_text(uint8_t *p, size_t *at, const char *s, size_t max, bool empty)
{
    size_t len=0; while(len<=max && s[len]) len++;
    if(len>max || (!empty && !len) || *at+1+len>512 || !text_valid((const uint8_t*)s,len)) return false;
    p[(*at)++]=(uint8_t)len; memcpy(p+*at,s,len); *at+=len; return true;
}
size_t vr_phone_encode(const vr_phone_t *v, uint8_t p[512])
{
    if(!v->count || v->count>8) return 0;
    p[0]=v->flags; p[1]=v->capture; p[2]=v->recording; p[3]=v->mode; p[4]=v->count; p[5]=v->active; vr_put32(p+6,v->ack);
    size_t at=10;
    for(unsigned i=0;i<v->count;i++) if(!write_text(p,&at,v->names[i],32,false)) return 0;
    if(!write_text(p,&at,v->resolved,32,false) || !write_text(p,&at,v->link,48,true) || !write_text(p,&at,v->error,64,true)) return 0;
    vr_phone_t check;
    return vr_phone_decode(p,at,&check) ? at : 0;
}
int vr_fragment(vr_fragments_t *f, const uint8_t *p, size_t n, vr_phone_t *out)
{
    if(n<7) goto bad;
    uint16_t id=vr_get16(p), total=vr_get16(p+2), offset=vr_get16(p+4);
    if(total<19 || total>512 || offset>=total || n-6>(size_t)(total-offset)) goto bad;
    if(!offset) { f->id=id; f->total=total; f->used=0; f->active=true; }
    if(!f->active || id!=f->id || total!=f->total || offset!=f->used) goto bad;
    memcpy(f->bytes+offset,p+6,n-6); f->used+=(uint16_t)(n-6);
    if(f->used!=total) return 0;
    f->active=false;
    return vr_phone_decode(f->bytes,total,out) ? 1 : -1;
bad:
    f->active=false; f->used=0; return -1;
}
bool vr_audio_decode(const uint8_t *p, size_t n, uint16_t max, vr_audio_t *out)
{
    if(n<12 || !max || max>4096 || p[7] || (p[6]&~7u)) return false;
    vr_audio_t v={.segment=vr_get32(p),.frame=vr_get16(p+4),.flags=p[6],.offset=vr_get16(p+8),
        .total=vr_get16(p+10),.payload=p+12,.size=n-12};
    if(!v.segment) return false;
    if(v.flags&2) { if(v.flags!=6 || !v.frame || v.offset || v.total || v.size) return false; }
    else if(!v.size || !v.total || v.total>max || v.offset>=v.total || v.size>(size_t)(v.total-v.offset) ||
        !!(v.flags&1)!=(v.frame==0) || !!(v.flags&4)!=(v.offset+v.size==v.total) || v.frame==65535) return false;
    *out=v; return true;
}
size_t vr_audio_encode(const vr_audio_t *v, uint16_t max, uint8_t *p, size_t capacity)
{
    if(capacity<12 || v->size>capacity-12 || (v->size && !v->payload)) return 0;
    vr_put32(p,v->segment); vr_put16(p+4,v->frame); p[6]=v->flags; p[7]=0;
    vr_put16(p+8,v->offset); vr_put16(p+10,v->total); if(v->size) memcpy(p+12,v->payload,v->size);
    vr_audio_t check; return vr_audio_decode(p,12+v->size,max,&check) ? 12+v->size : 0;
}
