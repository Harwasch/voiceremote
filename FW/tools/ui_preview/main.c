/* Purpose: render the production ui.c and exercise its event/barrier behavior.
 * Inputs: synthetic state only, no device or personal data. Verified by --check.
 */
#include "preview_runtime.h"
#include "board.h"
#include "lvgl.h"
#include "src/libs/lodepng/lodepng.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

vr_state_t remote_state;
static board_info_t info={1,466,466,0,true,true,true};
static uint8_t pixels[466*466*4];
static uint32_t now=450;
static bool touched, fail_flush;
static uint16_t touch_x,touch_y;
static unsigned haptics,pairs,answers,revokes,events,flushes;
static bool accepted;
static unsigned sent_pixels;
static int min_x=466,min_y=466,max_x,max_y;
uint32_t remote_now(void) { return now; }
const board_info_t *board_info(void) { return &info; }
esp_err_t board_init(void) { return ESP_OK; }
bool board_button(unsigned button) { (void)button; return false; }
void board_poll(uint32_t ms) { (void)ms; }
bool board_touch(uint16_t *x,uint16_t *y) { *x=touch_x; *y=touch_y; return touched; }
void board_haptic(uint32_t ms) { (void)ms; haptics++; }
void ble_pair_start(void) { pairs++; }
void ble_pair_answer(bool accept) { answers++; accepted=accept; }
void ble_revoke(void) { revokes++; }
void remote_event(uint8_t event,uint8_t value,uint32_t sampled)
{
    events++; vr_control(&remote_state,event,value,sampled); ui_refresh();
}
esp_err_t board_flush(int x1,int y1,int x2,int y2,const void *data)
{
    flushes++; sent_pixels+=(x2-x1+1)*(y2-y1+1);
    if(x1<min_x) min_x=x1;
    if(y1<min_y) min_y=y1;
    if(x2>max_x) max_x=x2;
    if(y2>max_y) max_y=y2;
    if(fail_flush) return ESP_FAIL;
    const uint8_t *p=data;
    for(int y=y1;y<=y2;y++) for(int x=x1;x<=x2;x++,p+=2) {
        uint16_t c=(uint16_t)p[0]<<8|p[1];
        unsigned at=(y*info.width+x)*4;
        pixels[at]=((c>>11)&31)*255/31; pixels[at+1]=((c>>5)&63)*255/63;
        pixels[at+2]=(c&31)*255/31; pixels[at+3]=255;
    }
    return ESP_OK;
}
static void advance(unsigned ms)
{
    for(unsigned i=0;i<ms;i+=5) { now+=5; ui_tick(); }
}
static void tap(int x,int y)
{
    touched=true; touch_x=x; touch_y=y; advance(50);
    touched=false; advance(100);
}
static void fixture(void)
{
    remote_state.secure=true; remote_state.has_phone=true;
    remote_state.input.capture=VR_PTT;
    remote_state.phone=(vr_phone_t){.count=4,.active=1};
    strcpy(remote_state.phone.names[0],"Auto"); strcpy(remote_state.phone.names[1],"Desktop");
    strcpy(remote_state.phone.names[2],"Laptop"); strcpy(remote_state.phone.names[3],"iPhone");
    strcpy(remote_state.phone.resolved,"Desktop");
}
static uint32_t target_hash(void)
{
    uint32_t hash=2166136261u;
    for(int y=384;y<450;y++) for(int x=0;x<466;x++)
        for(int c=0;c<3;c++) hash=(hash^pixels[(y*466+x)*4+c])*16777619u;
    return hash;
}
static unsigned error_pixels(void)
{
    unsigned count=0;
    for(int y=384;y<450;y++) for(int x=0;x<466;x++) {
        const uint8_t *p=pixels+(y*466+x)*4;
        if(p[0]>200 && p[1]<100 && p[2]<100) count++;
    }
    return count;
}
static void check(void)
{
    fixture(); ui_init();
    unsigned initial=flushes; uint32_t before=target_hash();
    vr_phone_t candidate=remote_state.phone; strcpy(candidate.resolved,"Laptop");
    assert(ui_phone(&candidate) && flushes>initial && target_hash()!=before);
    /* Verify the destination slot was actually drawn, not only invalidated. */
    unsigned lit=0;
    for(int y=390;y<432;y++) for(int x=80;x<386;x++) {
        unsigned at=(y*466+x)*4;
        if(pixels[at]>200 && pixels[at+1]>200 && pixels[at+2]>200) lit++;
    }
    assert(lit>100);
    ui_pair_number(90417); assert(!ui_phone(&candidate));
    tap(233,280); assert(answers==0);
    tap(314,364); assert(answers==1 && accepted);
    ui_pair_number(90417); tap(152,364); assert(answers==2 && !accepted);
    fail_flush=true; assert(!ui_phone(&candidate)); fail_flush=false;
    assert(ui_phone(&remote_state.phone));
    remote_state.input.ptt=1; ui_refresh(); advance(100);
    sent_pixels=0; advance(1000); assert(sent_pixels==0); /* Held, but producer stopped. */
    remote_state.input.streaming=1; ui_refresh(); advance(100);
    sent_pixels=0;min_x=min_y=466;max_x=max_y=0; advance(1000);
    assert(sent_pixels>0 && sent_pixels<=6*268*268);
    assert(min_x>=99 && min_y>=99 && max_x<367 && max_y<367);
    printf("Pulse: %u pixels flushed in 1s, bounded to (%d,%d)-(%d,%d).\n",sent_pixels,min_x,min_y,max_x,max_y);
    remote_state.input.ptt=0; ui_refresh(); advance(100);
    sent_pixels=0; advance(1000); assert(sent_pixels>0); /* Producer is the sole source. */
    remote_state.input.streaming=0; ui_refresh(); advance(100);
    sent_pixels=0; advance(1000); assert(sent_pixels==0);
    strcpy(candidate.error,"Destination unavailable"); assert(ui_phone(&candidate));
    assert(error_pixels()>100); advance(5100); assert(error_pixels()==0);
    candidate.error[0]=0; assert(ui_phone(&candidate));
    tap(233,233); assert(remote_state.input.mode==1);
    unsigned e=events;
    tap(320,140); assert(events==e); /* angular gap outside orb */
    tap(42,210); assert(remote_state.input.capture==VR_OFF);
    assert(events==e+1); /* Direct PTT -> OFF: never passes through REC. */
    tap(233,40); assert(remote_state.input.capture==VR_PTT);
    tap(424,210); assert(remote_state.input.capture==VR_REC);
    e=events; tap(233,407); assert(events==e); /* Linked: only the physical button changes target. */
    unsigned before_hold=haptics; e=events;
    touched=true; touch_x=233;touch_y=407;advance(1000);
    touch_y=233;advance(2200);touched=false;advance(50);
    assert(ui_phone(&candidate) && haptics==before_hold && events==e);
    touched=true; touch_x=233;touch_y=407; advance(3100);
    assert(haptics==before_hold+1 && events==e);
    assert(!ui_phone(&candidate)); touched=false; advance(50);
    assert(revokes==0); tap(152,364); assert(revokes==0); assert(ui_phone(&candidate));
    touched=true; touch_x=233;touch_y=407; advance(3100);
    touched=false; advance(50);
    tap(314,364); assert(revokes==1);
    /* An unanswered forget screen closes itself and stops blocking phone writes. */
    touched=true; touch_x=233;touch_y=407; advance(3100); touched=false; advance(50);
    assert(!ui_phone(&candidate)); advance(10100); assert(ui_phone(&candidate) && revokes==1);
    remote_state.secure=false; remote_state.has_phone=false; ui_refresh();
    tap(233,407); assert(pairs==1);
    assert(haptics>=12);
    printf("Preview interaction checks passed: touch, direct selection, modals, haptics, render/flush barrier.\n");
}
int main(int argc,char **argv)
{
    if(argc==2 && !strcmp(argv[1],"--check")) { check(); return 0; }
    if(argc!=3) { fprintf(stderr,"Usage: %s STATE OUTPUT.png | --check\n",argv[0]); return 2; }
    fixture(); const char *state=argv[1];
    if(!strcmp(state,"off")) remote_state.input.capture=VR_OFF;
    else if(!strcmp(state,"ptt-armed")) {}
    else if(!strcmp(state,"ptt-listening-transcribe")) { remote_state.input.ptt=1; remote_state.input.streaming=1; }
    else if(!strcmp(state,"rec-listening-ai")) { remote_state.input.capture=VR_REC;remote_state.input.mode=1;remote_state.input.streaming=1; }
    else if(!strcmp(state,"auto-target")) remote_state.phone.active=0;
    else if(!strcmp(state,"named-target")) { remote_state.phone.active=2;strcpy(remote_state.phone.resolved,"Laptop"); }
    else if(!strcmp(state,"long-name")) strcpy(remote_state.phone.resolved,"A very long destination name 1234");
    else if(!strcmp(state,"error-text")) strcpy(remote_state.phone.error,"Destination unavailable");
    else if(!strcmp(state,"no-link")) { remote_state.secure=false;remote_state.has_phone=false; }
    else if(!strcmp(state,"pairing-number") || !strcmp(state,"forget-confirm")) {}
    else if(!strcmp(state,"rectangular")) { info=(board_info_t){2,240,280,0,false,true,false};remote_state.phone.active=0; }
    else { fprintf(stderr,"Unknown state: %s\n",state);return 2; }
    ui_init();
    if(remote_state.has_phone) assert(ui_phone(&remote_state.phone));
    if(!strcmp(state,"pairing-number")) ui_pair_number(90417);
    if(!strcmp(state,"forget-confirm")) {
        touched=true; touch_x=233;touch_y=407;advance(3100);touched=false;advance(50);
    }
    lv_refr_now(NULL);
    /* Apply physical screen shape only to exported pixels; real panel clips naturally. */
    if(info.round) for(int y=0;y<info.height;y++) for(int x=0;x<info.width;x++) {
        float dx=x+.5f-info.width/2.f,dy=y+.5f-info.height/2.f,r=info.width/2.f;
        if(dx*dx+dy*dy>r*r) memset(pixels+(y*info.width+x)*4,0,4);
    }
    unsigned char *png=NULL; size_t length=0;
    unsigned err=lodepng_encode32(&png,&length,pixels,info.width,info.height);
    if(err) { fprintf(stderr,"PNG encode failed: %s\n",lodepng_error_text(err));return 1; }
    FILE *out=fopen(argv[2],"wb");
    if(!out) { perror(argv[2]);free(png);return 1; }
    bool ok=fwrite(png,1,length,out)==length;
    if(fclose(out)) ok=false;
    free(png); if(!ok) { fprintf(stderr,"PNG write failed\n");return 1; }
    printf("%s (%ux%u)\n",argv[2],info.width,info.height);return 0;
}
