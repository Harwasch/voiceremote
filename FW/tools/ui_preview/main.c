/* Purpose: render the production ui.c and exercise its event/barrier behavior.
 * Inputs: synthetic state only, no device or personal data. Verified by --check.
 */
#include "preview_runtime.h"
#include "board.h"
#include "timing.h"
#ifdef REMOTE_TEST_HOOK
#include "test_hook.h"
#endif
#include "lvgl.h"
#include "src/libs/lodepng/lodepng.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

vr_state_t remote_state;
static board_info_t info={1,466,466,0,true,true,true,true};
static uint8_t pixels[466*466*4];
static uint32_t now=450;
static bool touched, fail_flush, fail_touch;
static uint16_t touch_x,touch_y;
static unsigned haptics,pairs,answers,revokes,events,flushes;
static bool accepted, skip_render, interrupt_render, modal_during_render, wait_expired;
static unsigned mutex_depth, input_during_render;
static uint32_t flush_delay;
static unsigned sent_pixels;
static int min_x=466,min_y=466,max_x,max_y;
uint32_t remote_now(void) { return now; }
void remote_lock(void) { mutex_depth++; }
void remote_unlock(void) { assert(mutex_depth); mutex_depth--; }
bool preview_render_wait(void)
{
    assert(!mutex_depth);
    if(skip_render) return false;
    ui_tick(); return !wait_expired;
}
static bool phone(const vr_phone_t *p)
{
    remote_lock(); bool ok=ui_phone(p); remote_unlock(); return ok;
}
void *board_ui_alloc(size_t bytes) { return !info.round || getenv("VR_UI_NO_CACHE")?NULL:malloc(bytes); }
unsigned board_ui_strip_rows(void) { return info.round?32:8; }
const board_info_t *board_info(void) { return &info; }
esp_err_t board_init(void) { return ESP_OK; }
bool board_button(unsigned button) { (void)button; return false; }
void board_poll(uint32_t ms) { (void)ms; }
board_touch_t board_touch(uint16_t *x,uint16_t *y) { assert(mutex_depth); *x=touch_x; *y=touch_y; return fail_touch?BOARD_TOUCH_ERROR:touched?BOARD_TOUCH_DOWN:BOARD_TOUCH_UP; }
void board_haptic(uint32_t ms) { (void)ms; haptics++; }
void ble_pair_start(void) { pairs++; }
void ble_pair_answer(bool accept) { answers++; accepted=accept; }
void ble_revoke(void) { revokes++; }
void remote_event(uint8_t event,uint8_t value,uint32_t sampled)
{
    assert(mutex_depth);
    events++; vr_control(&remote_state,event,value,sampled); ui_refresh();
}
esp_err_t board_flush(int x1,int y1,int x2,int y2,const void *data)
{
    /* Panels like the CO5300 distort updates that aren't aligned this way. */
    if((x1&1)||(y1&1)||!(x2&1)||!(y2&1)) { fprintf(stderr,"bad %d %d %d %d\n",x1,y1,x2,y2); abort(); }
    assert(!mutex_depth); /* Panel DMA never owns the input/audio mutex. */
    now+=flush_delay; flush_delay=0;
    if(interrupt_render) {
        interrupt_render=false;
        remote_lock(); ui_poll(); input_during_render++; remote_unlock();
    }
    if(modal_during_render) {
        modal_during_render=false;
        remote_lock(); ui_pair_number(123456); remote_unlock();
    }
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
    for(unsigned i=0;i<ms;i+=5) { now+=5; remote_lock(); ui_poll(); remote_unlock(); ui_tick(); }
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
    for(int y=356;y<450;y++) for(int x=0;x<466;x++)
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
static void partial_matches_full(void)
{
    static uint8_t partial[sizeof pixels]; memcpy(partial,pixels,sizeof pixels);
    lv_obj_invalidate(lv_screen_active()); ui_tick();
    static unsigned comparison; comparison++;
    if(memcmp(partial,pixels,sizeof pixels)) {
        int x1=466,y1=466,x2=0,y2=0;
        for(int y=0;y<info.height;y++) for(int x=0;x<info.width;x++) if(memcmp(partial+(y*info.width+x)*4,pixels+(y*info.width+x)*4,4)) {
            if(x<x1) x1=x;
            if(x>x2) x2=x;
            if(y<y1) y1=y;
            if(y>y2) y2=y;
        }
        fprintf(stderr,"partial/full comparison %u differs at %d,%d..%d,%d (tick %u)\n",comparison,x1,y1,x2,y2,now);
    }
    assert(!memcmp(partial,pixels,sizeof pixels));
}
static void check(void)
{
    fixture(); ui_init();
    /* Touch-down must draw the selection before release or protocol debounce. */
    uint8_t old_pixels[sizeof pixels]; memcpy(old_pixels,pixels,sizeof pixels);
    unsigned old_events=events;
    touched=true; touch_x=424; touch_y=210; advance(5);
    assert(events==old_events && remote_state.input.capture==VR_PTT);
    assert(memcmp(old_pixels,pixels,sizeof pixels)!=0);
    partial_matches_full();
    touch_x=320; touch_y=140; advance(40); touched=false; advance(100);
    assert(events==old_events && !memcmp(old_pixels,pixels,sizeof pixels));
    /* Orb also previews immediately, then rolls back after leaving its disc. */
    touched=true; touch_x=233; touch_y=233; advance(5);
    assert(remote_state.input.mode==0 && events==old_events);
    assert(memcmp(old_pixels,pixels,sizeof pixels));
    touch_x=320; touch_y=140; advance(5); touched=false; advance(30);
    assert(!memcmp(old_pixels,pixels,sizeof pixels) && events==old_events);
    /* An I2C read failure must not accept a selected control as a release. */
    touched=true; touch_x=424; touch_y=210; advance(5);
    fail_touch=true; advance(50);
    assert(events==old_events && remote_state.input.capture==VR_PTT);
    fail_touch=false; advance(5);
    touched=false; advance(100);
    assert(events==old_events+1 && remote_state.input.capture==VR_REC);
    tap(233,40); old_events=events;
    /* A sustained failure cancels the preview; recovery while still held cannot
     * reactivate it. Only an observed up rearms touch. */
    touched=true; touch_x=424; touch_y=210; advance(5);
    fail_touch=true; advance(100);
    assert(events==old_events && !memcmp(old_pixels,pixels,sizeof pixels));
    fail_touch=false; advance(20); touched=false; advance(100);
    assert(events==old_events && remote_state.input.capture==VR_PTT);
    /* Accepted selection keeps its preview through the unchanged 25 ms filter. */
    touched=true; touch_x=424; touch_y=210; advance(5);
    touched=false; advance(5); assert(events==old_events);
    advance(20); assert(events==old_events && remote_state.input.capture==VR_PTT);
    advance(5); assert(events==old_events+1 && remote_state.input.capture==VR_REC);
    tap(233,40); old_events=events;
    assert(remote_state.input.capture==VR_PTT && !memcmp(old_pixels,pixels,sizeof pixels));
    unsigned initial=flushes; uint32_t before=target_hash();
    vr_phone_t candidate=remote_state.phone; strcpy(candidate.resolved,"Laptop");
    sent_pixels=0; min_x=min_y=466; max_x=max_y=0;
    assert(phone(&candidate) && flushes>initial && target_hash()!=before);
    assert(min_y>=356 && max_y<=451 && sent_pixels<=466*96); /* One row wider: even/odd alignment. */
    printf("Destination update: %u pixels, y=%d..%d.\n",sent_pixels,min_y,max_y);
    skip_render=true; assert(!phone(&remote_state.phone)); skip_render=false;
    ui_tick(); /* A timed-out request cannot acknowledge on a later frame. */
    before=target_hash();
    flush_delay=175; assert(phone(&remote_state.phone)); /* Measured streaming redraw. */
    wait_expired=true; flush_delay=450; assert(phone(&remote_state.phone)); wait_expired=false; /* Completed draw wins even after the wait budget. */
    before=target_hash(); ui_tick(); assert(target_hash()==before); /* Successful slow draw stays applied. */
    touched=true; touch_x=233; touch_y=233;
    interrupt_render=true; assert(phone(&candidate));
    assert(input_during_render==1 && events==old_events); /* Input sampled mid-DMA. */
    touched=false; advance(100); /* Mode debounce remains after release. */
    assert(remote_state.input.mode==1); tap(233,233); assert(remote_state.input.mode==0);
    modal_during_render=true; assert(!phone(&candidate));
    ui_pair_hide(); ui_tick();
    assert(phone(&candidate));
    /* Verify the destination slot was actually drawn, not only invalidated. */
    unsigned lit=0;
    for(int y=390;y<432;y++) for(int x=80;x<386;x++) {
        unsigned at=(y*466+x)*4;
        if(pixels[at]>200 && pixels[at+1]>200 && pixels[at+2]>200) lit++;
    }
    assert(lit>100);
    ui_pair_number(90417); assert(!phone(&candidate));
    tap(233,280); assert(answers==0);
    tap(314,364); assert(answers==1 && accepted);
    ui_pair_number(90417); tap(152,364); assert(answers==2 && !accepted);
    fail_flush=true; assert(!phone(&candidate)); fail_flush=false;
    assert(phone(&remote_state.phone));
    remote_state.input.ptt=1; ui_refresh(); advance(100);
    sent_pixels=0; advance(1000); assert(sent_pixels==0); /* Held, but producer stopped. */
    remote_state.input.streaming=1; ui_refresh(); advance(100);
    sent_pixels=0;min_x=min_y=466;max_x=max_y=0; advance(1000);
    assert(sent_pixels>0 && sent_pixels<6*30000);
    assert(min_x>=98 && min_y>=98 && max_x<=367 && max_y<=367); /* Includes even/odd alignment. */
    printf("Pulse: %u pixels flushed in 1s, bounded to (%d,%d)-(%d,%d).\n",sent_pixels,min_x,min_y,max_x,max_y);
    for(unsigned phase=0;phase<10;phase++) { now+=200; ui_tick(); partial_matches_full(); }
    remote_state.input.ptt=0; ui_refresh(); advance(100);
    sent_pixels=0; advance(1000); assert(sent_pixels>0); /* Producer is the sole source. */
    remote_state.input.streaming=0; ui_refresh(); advance(100);
    sent_pixels=0; advance(1000); assert(sent_pixels==0);
    strcpy(candidate.error,"Destination unavailable"); assert(phone(&candidate));
    assert(error_pixels()>100); advance(5100); assert(error_pixels()==0);
    candidate.error[0]=0; assert(phone(&candidate));
    tap(233,233); assert(remote_state.input.mode==1); partial_matches_full();
    unsigned e=events;
    tap(320,140); assert(events==e); /* angular gap outside orb */
    touched=true; touch_x=42; touch_y=210; advance(5);
    assert(remote_state.input.capture==VR_OFF); /* OFF stops on DOWN, before release/debounce. */
    advance(1000); assert(events==e+1);
    touched=false; advance(50); partial_matches_full();
    assert(events==e+1); /* Direct PTT -> OFF: never passes through REC. */
    tap(233,40); assert(remote_state.input.capture==VR_PTT); partial_matches_full();
    tap(424,210); assert(remote_state.input.capture==VR_REC); partial_matches_full();
    e=events; tap(233,407); assert(events==e); /* Linked: only the physical button changes target. */
    unsigned before_hold=haptics; e=events;
    touched=true; touch_x=233;touch_y=407;advance(1000);
    touch_y=233;advance(2200);touched=false;advance(50);
    assert(phone(&candidate) && haptics==before_hold && events==e);
    touched=true; touch_x=233;touch_y=407; advance(3100);
    assert(haptics==before_hold+1 && events==e+1 && remote_state.input.capture==VR_OFF);
    assert(!phone(&candidate)); touched=false; advance(50);
    assert(revokes==0); tap(152,364); assert(revokes==0); assert(phone(&candidate));
    touched=true; touch_x=233;touch_y=407; advance(3100);
    touched=false; advance(50);
    tap(314,364); assert(revokes==1);
    /* An unanswered forget screen closes itself and stops blocking phone writes. */
    touched=true; touch_x=233;touch_y=407; advance(3100); touched=false; advance(50);
    assert(!phone(&candidate)); advance(10100); assert(phone(&candidate) && revokes==1);
    remote_state.secure=false; remote_state.has_phone=false; ui_refresh();
    tap(233,407); assert(pairs==1);
    assert(haptics>=12);
    /* Offline capture keeps the same filled listening Orb after disconnect and
     * reconnect; its target stays Bluetooth-off until the local record closes. */
    tap(424,210); remote_state.input.offline=1; ui_refresh(); ui_tick();
    assert(pixels[(233*466+300)*4+2]>150); partial_matches_full();
    sent_pixels=0; advance(1000); assert(sent_pixels>0);
    uint32_t offline_target=target_hash();
    remote_state.secure=true; remote_state.has_phone=true; ui_refresh(); ui_tick();
    assert(target_hash()==offline_target); partial_matches_full();
    remote_state.input.waiting=1; ui_refresh(); ui_tick(); partial_matches_full();
    remote_state.input.offline=0; ui_refresh(); advance(100);
    tap(42,210); assert(remote_state.input.capture==VR_OFF);
    remote_state.input.full=1; ui_refresh(); ui_tick(); partial_matches_full();
    uint32_t full_target=target_hash();
    remote_state.input.full=0; ui_refresh(); ui_tick();
    assert(target_hash()!=full_target); partial_matches_full();
    remote_state.input.syncing=1; ui_refresh(); ui_tick(); partial_matches_full();
    uint32_t sync_target=target_hash();
    remote_state.input.syncing=0; ui_refresh(); ui_tick(); assert(target_hash()!=sync_target);
    remote_state.input.waiting=0; ui_refresh(); ui_tick(); partial_matches_full();
    printf("Offline UI checks passed: disconnected/reconnected listening, full/waiting in OFF, syncing, partial redraws.\n");
#ifdef REMOTE_TEST_HOOK
    extern void ui_test_control(unsigned actions,uint8_t capture);
    uint8_t mode=remote_state.input.mode;
    ui_test_control(VR_TEST_SELECT|VR_TEST_MODE,VR_REC);
    advance(20); assert(remote_state.input.capture==VR_OFF && remote_state.input.mode==mode);
    advance(10); assert(remote_state.input.capture==VR_REC && remote_state.input.mode!=mode);
    assert(!remote_state.armed); /* hook cannot set phone authority */
    ui_test_control(VR_TEST_SELECT,VR_PTT); advance(30);
    assert(remote_state.input.capture==VR_PTT && remote_state.input.mode!=mode);
    ui_test_control(VR_TEST_MODE,VR_OFF); advance(30);
    assert(remote_state.input.capture==VR_PTT && remote_state.input.mode==mode);
    unsigned mark=(455*466+233)*4;
    assert(pixels[mark]>200 && pixels[mark+1]<50 && pixels[mark+2]>200);
    ui_pair_number(123456); ui_tick();
    assert(pixels[mark]>200 && pixels[mark+1]<50 && pixels[mark+2]>200);
#endif
    timing_report();
    printf("Preview interaction checks passed: touch, direct selection, modals, haptics, render/flush barrier.\n");
}
static void check_c6(bool physical)
{
    extern void ui_physical_controls(uint8_t capture,uint8_t mode);
    info=(board_info_t){2,240,280,0xbf,false,true,!physical,false};
    fixture(); ui_init();
    assert(phone(&remote_state.phone));
    if(physical) {
        remote_lock(); ui_physical_controls(VR_REC,1); remote_unlock(); advance(30);
        assert(remote_state.input.capture==VR_REC && remote_state.input.mode==1);
        unsigned n=events; tap(120,112); assert(events==n); /* mode slider owns Orb */
        remote_lock(); ui_physical_controls(VR_OFF,0); remote_unlock(); advance(50);
        assert(remote_state.input.capture==VR_OFF && remote_state.input.mode==0);
        remote_lock(); ui_physical_controls(UINT8_MAX,1); remote_unlock(); advance(30);
        assert(remote_state.input.capture==VR_OFF && remote_state.input.mode==1);
    } else {
        tap(26,100); assert(remote_state.input.capture==VR_OFF);
        tap(120,18); assert(remote_state.input.capture==VR_PTT);
        tap(214,100); assert(remote_state.input.capture==VR_REC);
        tap(120,112); assert(remote_state.input.mode==1);
        touched=true; touch_x=26; touch_y=100; advance(5);
        assert(remote_state.input.capture==VR_OFF);
        touched=false; advance(50);
    }
    remote_state.input.offline=1; remote_state.input.waiting=1; ui_refresh(); ui_tick();
    partial_matches_full();
    ui_pair_number(123456); ui_tick();
    tap(65,222); assert(answers==1 && !accepted);
    ui_pair_number(123456); ui_tick();
    tap(175,222); assert(answers==2 && accepted);
    remote_state.secure=false; remote_state.has_phone=false; ui_refresh();
    tap(120,258); assert(pairs==1);
    printf("C6 %s controls, modals, offline UI and render barrier pass.\n",physical?"physical":"on-screen");
}
int main(int argc,char **argv)
{
    if(argc==2 && !strcmp(argv[1],"--check-c6-touch")) { check_c6(false); return 0; }
    if(argc==2 && !strcmp(argv[1],"--check-c6-physical")) { check_c6(true); return 0; }
    if(argc==2 && !strcmp(argv[1],"--timing")) {
        fixture(); ui_init(); timing_report();
        for(unsigned i=0;i<100;i++) { tap(42,210); tap(233,40); tap(424,210); tap(233,233); }
        puts("Control redraw aggregates (native host, no DMA latency):"); timing_report();
        remote_state.input.streaming=1; ui_refresh(); advance(100);
        timing_report();
        advance(20000); puts("Pulse redraw aggregates (native host):"); timing_report();
        return 0;
    }
    if(argc==2 && !strcmp(argv[1],"--check")) { check(); return 0; }
    if(argc!=3) { fprintf(stderr,"Usage: %s STATE OUTPUT.png | --check\n",argv[0]); return 2; }
    fixture(); const char *state=argv[1];
    if(!strcmp(state,"off")) remote_state.input.capture=VR_OFF;
    else if(!strcmp(state,"ptt-armed")) {}
    else if(!strcmp(state,"ptt-listening-transcribe")) { remote_state.input.ptt=1; remote_state.input.streaming=1; }
    else if(!strcmp(state,"rec-listening-ai")) { remote_state.input.capture=VR_REC;remote_state.input.mode=1;remote_state.input.streaming=1; }
    else if(!strcmp(state,"auto-target")) remote_state.phone.active=0;
    else if(!strcmp(state,"named-target")) { remote_state.phone.active=2;strcpy(remote_state.phone.resolved,"Laptop"); }
    else if(!strcmp(state,"long-name")) strcpy(remote_state.phone.resolved,"A very long destination name 123");
    else if(!strcmp(state,"error-text")) strcpy(remote_state.phone.error,"Destination unavailable");
    else if(!strcmp(state,"no-link")) { remote_state.secure=false;remote_state.has_phone=false; }
    else if(!strcmp(state,"offline-recording")) { remote_state.secure=false;remote_state.has_phone=false;remote_state.input.offline=1;remote_state.input.ptt=1; }
    else if(!strcmp(state,"offline-waiting")) { remote_state.secure=false;remote_state.has_phone=false;remote_state.input.offline=1;remote_state.input.waiting=1;remote_state.input.mode=1; }
    else if(!strcmp(state,"storage-full")) { remote_state.input.capture=VR_OFF;remote_state.input.full=1;remote_state.input.waiting=1; }
    else if(!strcmp(state,"recordings-waiting")) { remote_state.input.capture=VR_OFF;remote_state.input.waiting=1; }
    else if(!strcmp(state,"syncing")) { remote_state.input.waiting=1;remote_state.input.syncing=1; }
    else if(!strcmp(state,"pairing-number") || !strcmp(state,"forget-confirm")) {}
    else if(!strcmp(state,"rectangular")) { info=(board_info_t){2,240,280,0,false,true,false,false};remote_state.phone.active=0; }
    else if(!strncmp(state,"c6-",3)) {
        if(strstr(state,"offline")) { remote_state.input.offline=1; remote_state.input.waiting=1; }
        if(strstr(state,"pairing")) {} /* modal applied below */
    }
    else { fprintf(stderr,"Unknown state: %s\n",state);return 2; }
    if(!strncmp(state,"c6-",3)) {
        bool physical=strstr(state,"physical")!=NULL;
        info=(board_info_t){2,240,280,0xbf,false,true,!physical,false};
    }
    ui_init();
    if(remote_state.has_phone) assert(phone(&remote_state.phone));
    if(!strcmp(state,"pairing-number") || strstr(state,"pairing")) ui_pair_number(90417);
    if(!strcmp(state,"forget-confirm")) {
        touched=true; touch_x=233;touch_y=407;advance(3100);touched=false;advance(50);
    }
    ui_tick(); lv_refr_now(NULL);
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
