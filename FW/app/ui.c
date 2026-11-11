#ifdef UI_PREVIEW
#include "preview_runtime.h"
#include <assert.h>
#include <stdlib.h>
#define configASSERT assert
#else
#include "runtime.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#endif
#include "board.h"
#include "ui_input.h"
#ifdef REMOTE_TEST_HOOK
#include "test_hook.h"
#endif
#include "timing.h"
#include "lvgl.h"
#include "src/draw/sw/lv_draw_sw.h"
#include <stdio.h>
#include <string.h>

LV_FONT_DECLARE(lexend_24);
LV_FONT_DECLARE(lexend_30);
LV_FONT_DECLARE(lexend_42);
LV_FONT_DECLARE(lexend_84);
extern const lv_image_dsc_t vr_sparkle;
static lv_display_t *display;
static lv_obj_t *screen, *orb_obj;
static vr_layout_t layout;
static lv_layer_t *layer;
/* current is the app mailbox (remote_mutex); view belongs only to LVGL's task.
 * No state/board-I2C mutex is held during drawing or synchronous panel DMA. */
typedef struct {
    vr_phone_t phone;
    bool valid, secure, streaming, offline, full, waiting, syncing, error;
    uint8_t capture, mode, overlay;
    uint32_t number, touch_id, touch_at;
} ui_view_t;
static ui_view_t current, view, drawn;
static bool drawn_valid, flush_ok=true, frame_flushed, error_visible;
static uint32_t error_since, pulse_at, frame_at;
static vr_ui_press_t press;
static vr_phone_t barrier_phone;
static uint32_t barrier_id, barrier_done;
enum { PHONE_RENDER_WAIT_MS=400 };
static bool barrier_active, barrier_ok;
#ifndef UI_PREVIEW
static SemaphoreHandle_t barrier_signal;
#endif
static void lock(void) { remote_lock(); }
static void unlock(void) { remote_unlock(); }
static void cancel_barrier(void) { barrier_active=false; }
/* 0: normal, 1: numeric comparison, 2: forget confirmation. */
static uint32_t forget_since;
static bool long_recognised;
static vr_debounce_t control_filters[2];
static uint8_t control_values[2];
static const uint32_t mode_colors[]={0x6fe3ff,0xff6ad5};
typedef struct { lv_image_dsc_t image; lv_area_t area; } artwork_t;
static artwork_t sectors[3][3], orbs[2][3];
static lv_image_dsc_t small_sparkle;
static uint32_t ticks(void) { return remote_now(); }
static bool linked(void) { return view.secure && view.valid; }
static bool listening(void)
{
    return vr_ui_listening(view.streaming,view.offline);
}
static int sx(float x) { return (int)lroundf(layout.ox+x*layout.scale); }
static int sy(float y) { return (int)lroundf(layout.oy+y*layout.scale); }
static int sz(float n) { int v=(int)lroundf(n*layout.scale); return v>0?v:1; }
static void rect(float x1,float y1,float x2,float y2,uint32_t color)
{
    lv_draw_rect_dsc_t d; lv_draw_rect_dsc_init(&d);
    d.bg_color=lv_color_hex(color); d.bg_opa=255;
    lv_area_t a={sx(x1),sy(y1),sx(x2)-1,sy(y2)-1}; lv_draw_rect(layer,&d,&a);
}
static void circle(float x,float y,float r,uint32_t color,float stroke,uint8_t opa)
{
    lv_draw_rect_dsc_t d; lv_draw_rect_dsc_init(&d);
    d.radius=LV_RADIUS_CIRCLE;
    d.bg_color=lv_color_hex(color); d.bg_opa=stroke?0:opa;
    d.border_color=lv_color_hex(color); d.border_width=stroke?sz(stroke):0; d.border_opa=opa;
    lv_area_t a={sx(x-r),sy(y-r),sx(x+r)-1,sy(y+r)-1}; lv_draw_rect(layer,&d,&a);
}
static void line(float x1,float y1,float x2,float y2,float width,uint32_t color)
{
    lv_draw_line_dsc_t d; lv_draw_line_dsc_init(&d);
    d.p1=(lv_point_precise_t){sx(x1),sy(y1)}; d.p2=(lv_point_precise_t){sx(x2),sy(y2)};
    d.width=sz(width); d.color=lv_color_hex(color); d.round_start=d.round_end=1;
    lv_draw_line(layer,&d);
}
static void arc(float x,float y,float r,float a,float b,float width,uint32_t color)
{
    lv_draw_arc_dsc_t d; lv_draw_arc_dsc_init(&d);
    d.center=(lv_point_t){sx(x),sy(y)}; d.radius=sz(r+width/2);
    d.start_angle=a-90; d.end_angle=b-90;
    while(d.start_angle<0) d.start_angle+=360;
    while(d.end_angle<0) d.end_angle+=360;
    d.width=sz(width); d.rounded=1; d.color=lv_color_hex(color); lv_draw_arc(layer,&d);
}
enum { IC_OFF, IC_HOLD, IC_REC, IC_TYPE, IC_AI, IC_BT_OFF, IC_BT, IC_X, IC_CHECK, IC_BIN, IC_SAVED, IC_FULL, IC_SYNC };
static void icon(int kind,float x,float y,float k,uint32_t color)
{
#define L(a,b,c,d) line(x+(a)*k,y+(b)*k,x+(c)*k,y+(d)*k,3*k,color)
    switch(kind) {
    case IC_HOLD: circle(x,y,12*k,color,3*k,255); circle(x,y,4.5f*k,color,0,255); break;
    case IC_REC: circle(x,y,11*k,color,0,255); break;
    case IC_TYPE: L(-14,-9,14,-9); L(-14,0,6,0); L(-14,9,0,9); L(12,2,12,14); break;
    case IC_AI: {
        lv_draw_image_dsc_t d; lv_draw_image_dsc_init(&d);
        d.src=&vr_sparkle; d.recolor=lv_color_hex(color); d.recolor_opa=255;
        d.pivot=(lv_point_t){0,0};
        d.scale_x=d.scale_y=(int32_t)lroundf(k*layout.scale/(112.f/34)*256);
        lv_area_t a={sx(x-17*k),sy(y-17*k),sx(x-17*k)+111,sy(y-17*k)+111};
        if(small_sparkle.data) {
            d.src=&small_sparkle; d.scale_x=d.scale_y=256;
            a.x2=a.x1+small_sparkle.header.w-1; a.y2=a.y1+small_sparkle.header.h-1;
        }
        lv_draw_image(layer,&d,&a); break;
    }
    case IC_OFF:
        arc(x,y-8*k,5*k,-90,90,3*k,color); L(-5,-8,-5,-1); L(5,-8,5,-1);
        arc(x,y-k,5*k,90,270,3*k,color);
        arc(x,y-2*k,10*k,90,270,3*k,color); L(0,8,0,14); L(-13,-13,13,13); break;
    case IC_BT_OFF: L(-6,-7,7,6); L(7,6,0,13); L(0,13,0,-13); L(0,-13,7,-6); L(7,-6,3,-2); L(-11,-11,11,11); break;
    case IC_BT: L(-7,-7,7,7); L(7,7,0,14); L(0,14,0,-14); L(0,-14,7,-7); L(7,-7,-7,7); break;
    case IC_X: L(-9,-9,9,9); L(9,-9,-9,9); break;
    case IC_CHECK: L(-11,1,-3,9); L(-3,9,12,-8); break;
    case IC_SAVED:
        L(-10,-10,4,-10); L(-10,-10,-10,10); L(-10,10,3,10);
        L(-5,-14,8,-14); L(8,-14,8,-5);
        L(10,14,10,-1); L(10,-1,4,5); L(10,-1,16,5); break;
    case IC_FULL:
        L(-14,-11,14,-11); L(-14,-11,-14,12); L(-14,12,14,12); L(14,12,14,-11);
        L(-14,-4,14,-4); L(0,0,0,5); circle(x,y+9*k,1.5f*k,color,0,255); break;
    case IC_SYNC:
        L(-14,-7,14,-7); L(14,-7,7,-14); L(14,-7,7,0);
        L(14,7,-14,7); L(-14,7,-7,0); L(-14,7,-7,14); break;
    case IC_BIN: L(-13,-9,13,-9); L(-5,-14,5,-14); L(-10,-8,-8,14); L(-8,14,8,14); L(8,14,10,-8); L(-3,-3,-3,8); L(3,-3,3,8); break;
    }
#undef L
}
static int text_width(const char *s,const lv_font_t *font,int spacing)
{
    lv_point_t p; lv_text_get_size(&p,s,font,spacing,0,LV_COORD_MAX,LV_TEXT_FLAG_NONE); return p.x;
}
static void text(const char *s,float x,float baseline,const lv_font_t *font,uint32_t color,int spacing)
{
    lv_draw_label_dsc_t d; lv_draw_label_dsc_init(&d);
    d.font=font; d.text=s; d.text_local=1; d.color=lv_color_hex(color); d.letter_space=spacing;
    int width=text_width(s,font,spacing),height=lv_font_get_line_height(font);
    int top=sy(baseline)-height+font->base_line;
    lv_area_t a={sx(x),top,sx(x)+width-1,top+height-1}; lv_draw_label(layer,&d,&a);
}
static void target_label(void)
{
    float cx=layout.cx,y=layout.baseline;
    /* Crossed out only when nothing is connected; plain blue means connected, waiting for the phone's state. */
    if(!linked() || view.offline) {
        bool up=view.secure && !view.offline;
        icon(up?IC_BT:IC_BT_OFF,cx,y-((layout.ring && !layout.compact)?42:30)*.32f,((layout.ring && !layout.compact)?42:30)/26.f,up?0x2f8bff:0x8a9099); return;
    }
    bool error=view.error && view.phone.error[0];
    char name[96]; vr_ui_ascii(name,sizeof name,error?view.phone.error:view.phone.resolved);
    bool automatic=!error && view.phone.active==0;
    const lv_font_t *fonts[]={&lexend_42,&lexend_30,&lexend_24};
    int first=layout.ring && !layout.compact && layout.scale>.85f?0:1;
    const int sizes[]={42,30,24};
    int available=0, badge=0, font_size=sizes[first];
    const lv_font_t *font=fonts[first];
    /* Fit the whole font box (including descenders) inside the narrowest chord.
     * A small margin also keeps the Auto badge clear of the physical rim. */
    for(int i=first;i<3;i++) {
        font=fonts[i]; font_size=sizes[i]; badge=automatic?(int)ceilf(font_size*1.05f):0;
        float half=layout.width/2.f-10;
        if(layout.round) {
            float r=fminf(layout.width,layout.height)/2.f;
            float bottom=sy(y)+font->base_line-layout.height/2.f;
            float top=bottom-font->line_height;
            float dy=fmaxf(fabsf(top),fabsf(bottom));
            half=sqrtf(fmaxf(0,r*r-dy*dy))-4;
        }
        available=(int)(half*2);
        if(text_width(name,font,0)+badge<=available) break;
    }
    int n=(int)strlen(name);
    if(text_width(name,font,0)+badge>available) {
        while(n>0) {
            name[--n]=0;
            char trial[100]; snprintf(trial,sizeof trial,"%s...",name);
            if(text_width(trial,font,0)+badge<=available) { strcpy(name,trial); break; }
        }
    }
    float x=cx-(text_width(name,font,0)+badge)/(2*layout.scale);
    if(automatic) {
        float size=font_size/layout.scale, bx=x+size*.38f, by=y-size*.34f;
        circle(bx,by,size*.38f,0xffffff,size*.06f,255);
        line(bx-size*.14f,by+size*.15f,bx,by-size*.17f,size*.045f,0xffffff);
        line(bx,by-size*.17f,bx+size*.14f,by+size*.15f,size*.045f,0xffffff);
        line(bx-size*.08f,by+size*.03f,bx+size*.08f,by+size*.03f,size*.045f,0xffffff);
        x+=badge/layout.scale;
    }
    text(name,x,y,font,error?0xff453a:0xffffff,0);
}
static void draw_sector(unsigned i,bool selected)
{
    const float starts[]={-116,-29,50},ends[]={-50,29,116};
    const uint32_t cols[]={0x8a9099,0xffd60a,0xff453a},dim[]={0x8a9099,0xa8922e,0xa8524d};
    float cx=layout.cx,cy=layout.cy,r=layout.compact?94:193;
    arc(cx,cy,r,starts[i],ends[i],layout.compact?36:60,selected?cols[i]:0x1d2024);
    float a=(starts[i]+ends[i])/2*3.14159265358979323846f/180;
    icon(i,cx+r*sinf(a),cy-r*cosf(a),layout.compact?1:1.8f,selected?0:dim[i]);
}
static void draw_orb_static(unsigned mode,unsigned state)
{
    float cx=layout.cx,cy=layout.cy,r=layout.radius;
    uint32_t color=mode_colors[mode];
    if(state==0) circle(cx,cy,r,0x3a3f45,6,255);
    else circle(cx,cy,r,color,state==2?0:8,255);
    icon(mode?IC_AI:IC_TYPE,cx,cy,r/34,state==0?0x5b616a:state==2?0:color);
}
static bool artwork_draw(const artwork_t *a)
{
    if(!a->image.data) return false;
    lv_draw_image_dsc_t d; lv_draw_image_dsc_init(&d); d.src=&a->image;
    lv_draw_image(layer,&d,&a->area); return true;
}
static size_t artwork_init(void)
{
    /* Rasterize with the very same RGB565 renderer and absolute coordinates.
     * This preserves AA pixels exactly, replacing paths with clipped memcpy. */
    static const float bounds[3][4]={{7,76,118,350},{107,7,359,97},{348,76,459,350}};
    lv_obj_t *canvas=lv_canvas_create(screen);
    lv_obj_add_flag(canvas,LV_OBJ_FLAG_HIDDEN);
    lv_draw_buf_t buf;
    size_t total=0;
    for(unsigned kind=0;kind<2;kind++) for(unsigned i=0;i<(kind?2u:3u);i++)
        for(unsigned j=0;j<3;j++) {
            if(!kind && (!layout.ring || layout.compact)) continue;
            artwork_t *a=kind?&orbs[i][j]:&sectors[i][j];
            if(kind) a->area=(lv_area_t){sx(layout.cx-layout.radius),sy(layout.cy-layout.radius),
                sx(layout.cx+layout.radius)-1,sy(layout.cy+layout.radius)-1};
            else a->area=(lv_area_t){sx(bounds[i][0]),sy(bounds[i][1]),sx(bounds[i][2]),sy(bounds[i][3])};
            int w=lv_area_get_width(&a->area),h=lv_area_get_height(&a->area);
            unsigned stride=lv_draw_buf_width_to_stride(w,LV_COLOR_FORMAT_RGB565);
            unsigned bytes=stride*h;
            void *buffer=board_ui_alloc(bytes);
            if(!buffer) continue;
            total+=bytes;
            memset(buffer,0,bytes);
            configASSERT(lv_draw_buf_init(&buf,w,h,LV_COLOR_FORMAT_RGB565,stride,buffer,stride*h)==LV_RESULT_OK);
            lv_canvas_set_draw_buf(canvas,&buf);
            lv_layer_t cache_layer; lv_canvas_init_layer(canvas,&cache_layer);
            cache_layer.buf_area=cache_layer._clip_area=cache_layer.phy_clip_area=a->area;
            layer=&cache_layer;
            if(kind) draw_orb_static(i,j);
            else for(unsigned sector=0;sector<3;sector++) draw_sector(sector,sector==j);
            lv_canvas_finish_layer(canvas,&cache_layer);
            a->image=(lv_image_dsc_t){.header=buf.header,.data_size=bytes,.data=buffer};

        }
    lv_obj_delete(canvas);
    return total;
}
#ifdef REMOTE_TEST_HOOK
void ui_test_control(unsigned actions,uint8_t capture)
{
    /* Same slider mailbox and 25 ms debounce as accepted touch selections. */
    if(actions&VR_TEST_SELECT) control_values[0]=capture;
    if(actions&VR_TEST_MODE) control_values[1]=!control_values[1];
}
#endif
static void draw_base(lv_event_t *e)
{
    layer=lv_event_get_layer(e);
    if(view.overlay) {
        float cx=layout.cx, top=(layout.ring && !layout.compact)?300:180, bottom=(layout.ring && !layout.compact)?466:280;
        rect(0,top,cx,bottom,0x2a2d32); rect(cx,top,(layout.ring && !layout.compact)?466:240,bottom,0x30d158);
        float iy=(layout.ring && !layout.compact)?364:222, gap=(layout.ring && !layout.compact)?81:55;
        icon(IC_X,cx-gap,iy,(layout.ring && !layout.compact)?2:1.5f,0xffffff);
        icon(IC_CHECK,cx+gap,iy,(layout.ring && !layout.compact)?2:1.5f,0);
        if(view.overlay==1) {
            icon(IC_BT,cx,(layout.ring && !layout.compact)?74:32,1.5f,0x2f8bff);
            char digits[8]; snprintf(digits,sizeof digits,"%06lu",(unsigned long)(view.number%1000000));
            const lv_font_t *font=(layout.ring && !layout.compact)?&lexend_84:&lexend_42;
            int spacing=sz((layout.ring && !layout.compact)?6:3);
            for(int i=0;i<2;i++) {
                char row[4]; memcpy(row,digits+3*i,3); row[3]=0;
                text(row,cx-text_width(row,font,spacing)/(2*layout.scale),(layout.ring && !layout.compact)?178+86*i:95+52*i,font,0xffffff,spacing);
            }
        } else icon(IC_BIN,cx,(layout.ring && !layout.compact)?164:91,(layout.ring && !layout.compact)?3.5f:2.5f,0x8a9099);
        return;
    }
    if(layout.ring) for(unsigned i=0;i<3;i++) {
        /* Each opaque tile includes any neighbouring cap in its bounds for
         * this capture state. No A8 blend or overlapping black-corner erasure. */
        if(!artwork_draw(&sectors[i][view.capture])) draw_sector(i,view.capture==i);
    }
    /* Local storage indicators use the existing small-pip row. They remain
     * visible with OFF selected, and never claim a current destination. */
    unsigned status_count=view.full+view.waiting+view.syncing;
    if(status_count) {
        unsigned slot=0; const bool active[]={view.full,view.waiting,view.syncing};
        const int kinds[]={IC_FULL,IC_SAVED,IC_SYNC};
        for(unsigned i=0;i<3;i++) if(active[i]) {
            float x=layout.cx+(slot++-(status_count-1)/2.f)*((layout.ring && !layout.compact)?36:30);
            icon(kinds[i],x,layout.pips_y,(layout.ring && !layout.compact)?.7f:.6f,i==0?0xff453a:0x8a9099);
        }
    } else if(linked() && !view.offline) for(int i=0;i<view.phone.count;i++)
        circle(layout.cx+(i-(view.phone.count-1)/2.f)*((layout.ring && !layout.compact)?20:16),layout.pips_y,(layout.ring && !layout.compact)?5:4,
            i==view.phone.active?0xffffff:0x3a3f45,0,255);
    target_label();
}
static void draw_orb(lv_event_t *e)
{
    layer=lv_event_get_layer(e);
    float cx=layout.cx,cy=layout.cy,r=layout.radius;
    bool off=(!linked() && !view.offline) || view.capture==VR_OFF, live=listening();
    uint32_t color=mode_colors[view.mode==1];
    unsigned state=off?0:live?2:1;
    if(!artwork_draw(&orbs[view.mode==1][state])) draw_orb_static(view.mode==1,state);
    if(!off && live) {
        float phase=(frame_at%1800)/1800.f;
        circle(cx,cy,r+3+phase*17,color,3,(uint8_t)(100*(1-phase)));
    }
}
/* Clip custom drawing to the changed regions; LVGL clears the old pixels too.
 * Bounds include rounded caps and antialiasing. Only overlay transitions are full screen. */
static void region(float x1,float y1,float x2,float y2)
{
    lv_area_t a={sx(x1),sy(y1),sx(x2),sy(y2)}; lv_obj_invalidate_area(screen,&a);
}
static void sector(unsigned i)
{
    static const float bounds[3][4]={{7,76,118,350},{107,7,359,97},{348,76,459,350}};
    if(layout.compact && i<3) region(0,0,239,224);
    else if(layout.ring && i<3) region(bounds[i][0],bounds[i][1],bounds[i][2],bounds[i][3]);
}
static void target(void) { region(0,(layout.ring && !layout.compact)?356:212,(layout.ring && !layout.compact)?466:240,(layout.ring && !layout.compact)?450:279); }
static void invalidate_changes(bool force_target)
{
    if(!drawn_valid || view.overlay!=drawn.overlay || (view.overlay && view.number!=drawn.number)) {
        if(view.overlay) lv_obj_add_flag(orb_obj,LV_OBJ_FLAG_HIDDEN);
        else lv_obj_remove_flag(orb_obj,LV_OBJ_FLAG_HIDDEN);
        lv_obj_invalidate(screen);
    } else if(!view.overlay) {
        if(view.capture!=drawn.capture) { sector(drawn.capture); sector(view.capture); }
        if((view.capture==VR_OFF)!=(drawn.capture==VR_OFF) || view.mode!=drawn.mode || view.secure!=drawn.secure ||
           view.valid!=drawn.valid || view.streaming!=drawn.streaming || view.offline!=drawn.offline) lv_obj_invalidate(orb_obj);
        if(force_target || view.offline!=drawn.offline || view.full!=drawn.full || view.waiting!=drawn.waiting ||
           view.syncing!=drawn.syncing || view.valid!=drawn.valid || view.secure!=drawn.secure || view.error!=drawn.error ||
           view.phone.count!=drawn.phone.count || view.phone.active!=drawn.phone.active ||
           strcmp(view.phone.resolved,drawn.phone.resolved) || strcmp(view.phone.error,drawn.phone.error)) target();
    }
}
/* OFF bypasses release/debounce but uses the same event/capture stop path. */
static void commit_off(uint32_t now)
{
    control_values[0]=VR_OFF;
    control_filters[0]=(vr_debounce_t){VR_OFF,VR_OFF,now};
    if(remote_state.input.capture!=VR_OFF) remote_event(VR_CAPTURE,VR_OFF,now);
}
static void act(vr_hit_t hit)
{
    if(hit==VR_HIT_NONE) return;
    board_haptic(remote_now());
    if(current.overlay) {
        uint8_t previous=current.overlay; current.overlay=0; cancel_barrier();
        if(previous==1) ble_pair_answer(hit==VR_HIT_CONFIRM);
        else if(hit==VR_HIT_CONFIRM) ble_revoke();
    } else if(hit>=VR_HIT_OFF && hit<=VR_HIT_REC) control_values[0]=hit-VR_HIT_OFF;
    else if(hit==VR_HIT_ORB) control_values[1]=!control_values[1];
    else if(hit==VR_HIT_TARGET) {
        /* Linked target taps remain inert: only the physical button reroutes. */
        if(!(current.secure && current.valid)) ble_pair_start();
    }
}
/* AMOLED controllers such as the CO5300 need even start and odd end coordinates;
 * anything else distorts partial updates. */
static void round_area(lv_event_t *e)
{
    lv_area_t *a=lv_event_get_param(e);
    a->x1&=~1; a->y1&=~1; a->x2|=1; a->y2|=1;
}
static void flush(lv_display_t *d,const lv_area_t *a,uint8_t *pixels)
{
    uint64_t start=timing_now_us(); frame_flushed=true;
    lv_draw_sw_rgb565_swap(pixels,(a->x2-a->x1+1)*(a->y2-a->y1+1));
    if(board_flush(a->x1,a->y1,a->x2,a->y2,pixels)!=ESP_OK) flush_ok=false;
    timing_flush(start);
    lv_display_flush_ready(d);
}
void ui_init(void)
{
    const board_info_t *b=board_info(); if(!b->operational) return;
    layout=vr_layout(b->width,b->height,b->round,b->virtual_sliders);
    lv_init(); lv_tick_set_cb(ticks);
    display=lv_display_create(b->width,b->height); configASSERT(display);
    /* One internal DMA strip; the shared renderer never assumes PSRAM. */
    size_t bytes=b->width*board_ui_strip_rows()*2u;
#ifdef UI_PREVIEW
    void *buffer=malloc(bytes);
#else
    void *buffer=heap_caps_malloc(bytes,MALLOC_CAP_DMA|MALLOC_CAP_INTERNAL);
#endif
    if(!buffer && board_ui_strip_rows()>16) {
        bytes=b->width*16u*2u;
#ifdef UI_PREVIEW
        buffer=malloc(bytes);
#else
        buffer=heap_caps_malloc(bytes,MALLOC_CAP_DMA|MALLOC_CAP_INTERNAL);
#endif
    }
    configASSERT(buffer);
    lv_display_set_color_format(display,LV_COLOR_FORMAT_RGB565);
    lv_display_set_buffers(display,buffer,NULL,bytes,LV_DISPLAY_RENDER_MODE_PARTIAL);
    lv_display_set_flush_cb(display,flush);
    lv_display_add_event_cb(display,round_area,LV_EVENT_INVALIDATE_AREA,NULL);
    screen=lv_screen_active(); lv_obj_remove_style_all(screen);
    lv_obj_set_style_bg_color(screen,lv_color_black(),0); lv_obj_set_style_bg_opa(screen,255,0);
    lv_obj_remove_flag(screen,LV_OBJ_FLAG_SCROLLABLE); lv_obj_add_flag(screen,LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_event_cb(screen,draw_base,LV_EVENT_DRAW_MAIN,NULL);
    /* Only this bounded orb area is invalidated at 5 Hz while listening.
     * No full-screen animation, blocking delay or extra framebuffer. */
    orb_obj=lv_obj_create(screen); lv_obj_remove_style_all(orb_obj);
    int extent=sz(layout.radius+22);
    lv_obj_set_pos(orb_obj,sx(layout.cx)-extent,sy(layout.cy)-extent); lv_obj_set_size(orb_obj,extent*2,extent*2);
    lv_obj_remove_flag(orb_obj,LV_OBJ_FLAG_CLICKABLE|LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_event_cb(orb_obj,draw_orb,LV_EVENT_DRAW_MAIN,NULL);
#ifdef REMOTE_TEST_HOOK
    lv_obj_t *mark=lv_obj_create(lv_layer_top()); lv_obj_remove_style_all(mark);
    lv_obj_set_size(mark,6,6); lv_obj_set_pos(mark,sx(layout.cx)-3,sy((layout.ring && !layout.compact)?454:272));
    lv_obj_set_style_bg_color(mark,lv_color_hex(0xff00ff),0); lv_obj_set_style_bg_opa(mark,255,0);
    lv_obj_remove_flag(mark,LV_OBJ_FLAG_CLICKABLE|LV_OBJ_FLAG_SCROLLABLE);
#endif
    /* LVGL 9.5 scaled A8 clipping depends on partial-buffer boundaries at
     * these small sizes (native regression). Pre-scale only the glyph once;
     * keep every sector and Orb primitive. 2500 / 7056 bytes, no PSRAM. */
    if(!layout.round) {
        unsigned n=sz(layout.radius);
        uint8_t *alpha=lv_malloc(n*n); configASSERT(alpha);
        lv_draw_image_dsc_t d; lv_draw_image_dsc_init(&d);
        d.scale_x=d.scale_y=(int32_t)lroundf(layout.radius*layout.scale/112*256);
        d.pivot=(lv_point_t){0,0};
        lv_area_t a={0,0,(int)n-1,(int)n-1};
        lv_draw_sw_transform(&a,vr_sparkle.data,112,112,112,&d,NULL,LV_COLOR_FORMAT_A8,alpha);
        small_sparkle=(lv_image_dsc_t){.header={.magic=LV_IMAGE_HEADER_MAGIC,
            .cf=LV_COLOR_FORMAT_A8,.w=n,.h=n,.stride=n},.data_size=n*n,.data=alpha};
    }
    size_t cache_bytes=artwork_init();
#ifdef UI_PREVIEW
    printf("ui host: artwork_cache_bytes=%zu dma_strip_bytes=%zu\n",cache_bytes,bytes);
#else
    ESP_LOGI("ui","artwork_cache_bytes=%u dma_strip_bytes=%u",(unsigned)cache_bytes,(unsigned)bytes);
#endif
    for(int i=0;i<2;i++) {
        control_values[i]=i?remote_state.input.mode:remote_state.input.capture;
        control_filters[i]=(vr_debounce_t){control_values[i],control_values[i],remote_now()};
    }
#ifndef UI_PREVIEW
    barrier_signal=xSemaphoreCreateBinary(); configASSERT(barrier_signal);
#endif
    current.capture=control_values[0]; current.mode=control_values[1];
    ui_refresh(); ui_tick();
}
bool ui_phone(const vr_phone_t *p)
{
    if(!display || current.overlay || barrier_active) return false;
    /* Called with remote_mutex taken exactly once by the ATT access callback.
     * Release it while LVGL works. Never wait on the renderer with the app lock.
     * Measured streaming redraws reach 175 ms. Bound waiting, but accept a
     * matching completed draw even if lock reacquisition is delayed. */
    uint32_t started=remote_now();
    barrier_phone=*p; barrier_active=true; barrier_ok=false;
    if(!++barrier_id) barrier_id++;
    uint32_t id=barrier_id;
#ifndef UI_PREVIEW
    xSemaphoreTake(barrier_signal,0); /* discard a late completion */
#endif
    unlock();
#ifdef UI_PREVIEW
    (void)preview_render_wait();
#else
    (void)xSemaphoreTake(barrier_signal,pdMS_TO_TICKS(PHONE_RENDER_WAIT_MS));
#endif
    lock();
    bool ok=barrier_done==id && barrier_ok && barrier_active && !current.overlay;
    cancel_barrier();
    if(ok) {
        current.phone=*p; current.valid=true;
        error_visible=p->error[0]!=0; error_since=remote_now(); current.error=error_visible;
    }
    timing_barrier(started,ok);
    return ok;
}
void ui_refresh(void)
{
    if(!display) return;
    current.valid=remote_state.has_phone; current.secure=remote_state.secure;
    current.streaming=remote_state.input.streaming;
    current.offline=remote_state.input.offline; current.full=remote_state.input.full;
    current.waiting=remote_state.input.waiting; current.syncing=remote_state.input.syncing;
    if(current.valid) current.phone=remote_state.phone;
}
void ui_pair_number(uint32_t number)
{
    if(!display) return;
    current.number=number; current.overlay=1; vr_ui_press_cancel(&press); cancel_barrier();
}
void ui_pair_hide(void)
{
    if(display) { current.overlay=0; vr_ui_press_cancel(&press); cancel_barrier(); }
}
void ui_link(const char *status) { (void)status; ui_refresh(); }
void ui_physical_controls(uint8_t capture,uint8_t mode)
{
    if(board_info()->virtual_sliders) return;
    uint32_t now=remote_now();
    if(capture==UINT8_MAX) capture=control_values[0];
    if(mode==UINT8_MAX) mode=control_values[1];
    const uint8_t values[]={capture,mode};
    for(unsigned i=0;i<2;i++) {
        control_values[i]=values[i];
        control_filters[i]=(vr_debounce_t){values[i],values[i],now};
    }
    /* OFF first; mode before a fresh REC so its record has the selected mode. */
    if(capture==VR_OFF && remote_state.input.capture!=VR_OFF) remote_event(VR_CAPTURE,VR_OFF,now);
    if(mode!=remote_state.input.mode) remote_event(VR_MODE,mode,now);
    if(capture!=remote_state.input.capture) remote_event(VR_CAPTURE,capture,now);
    current.capture=capture; current.mode=mode;
}
/* Sample/hit-test in the input task, independently of LVGL and its redraw rate. */
void ui_poll(void)
{
    if(!display) return;
    uint32_t now=remote_now(); uint16_t x=0,y=0;
    uint64_t poll_start=timing_now_us();
    board_touch_t sample=board_touch(&x,&y);
    bool down=sample==BOARD_TOUCH_DOWN;
    timing_touch_poll(poll_start);
    vr_hit_t hit=down?vr_ui_hit(&layout,x,y,current.overlay!=0):press.hit;
    /* With physical sliders the Orb is a status display; touch still pairs,
     * confirms and forgets. It never overrides a physical mode selector. */
    if(!board_info()->virtual_sliders && hit==VR_HIT_ORB) hit=VR_HIT_NONE;
    bool first_down=down && !press.down;
    vr_hit_t previous=press.hit;
    vr_hit_t released=vr_ui_touch_sample(&press,sample!=BOARD_TOUCH_ERROR,down,hit,now);
    down=press.down;
    if(down && previous==VR_HIT_NONE &&
       ((press.hit>=VR_HIT_OFF && press.hit<=VR_HIT_REC) || press.hit==VR_HIT_ORB)) {
        current.touch_id++; if(!current.touch_id) current.touch_id++;
        current.touch_at=now;
    }
    if(first_down && press.hit==VR_HIT_OFF && !current.overlay) {
        commit_off(now); board_haptic(now); vr_ui_press_cancel(&press);
    }
    if(!down && !long_recognised) act(released);
    if(!press.down) long_recognised=false;
    if(sample!=BOARD_TOUCH_ERROR && !current.overlay && press.hit==VR_HIT_TARGET && !long_recognised && now-press.since>=3000) {
        commit_off(now); /* Never hide an active listening state behind the bin. */
        long_recognised=true; current.overlay=2; forget_since=now;
        vr_ui_press_cancel(&press); cancel_barrier(); board_haptic(now);
    }
    if(current.overlay==2 && now-forget_since>=10000) {
        current.overlay=0; vr_ui_press_cancel(&press); cancel_barrier();
    }
    if(error_visible && now-error_since>=5000) error_visible=false;
    current.error=error_visible;
    current.capture=vr_ui_preview_capture(control_values[0],press.hit);
    current.mode=vr_ui_preview_mode(control_values[1],press.hit);
    for(unsigned i=0;i<2;i++) {
        uint32_t sampled;
        if(vr_debounce(&control_filters[i],control_values[i],now,&sampled))
            remote_event(i?VR_MODE:VR_CAPTURE,control_values[i],sampled);
    }
}
static void invalidate_pulse(void)
{
    int cx=sx(layout.cx),cy=sy(layout.cy),outer=sz(layout.radius+22),inner=sz(layout.radius)-2;
    /* Nonoverlapping bands stay below LVGL's invalidation-list capacity. The
     * conservative inner chord includes both the old and new thin pulse ring. */
    int band=(2*outer+11)/12;
    for(int top=cy-outer;top<cy+outer;top+=band) {
        int bottom=LV_MIN(top+band-1,cy+outer-1);
        int dy=LV_MAX(abs(top-cy),abs(bottom-cy));
        int half=dy<inner?(int)sqrtf(inner*inner-dy*dy):0;
        int near=(top<=cy && bottom>=cy)?0:LV_MIN(abs(top-cy),abs(bottom-cy));
        int edge=LV_MIN(outer,(int)ceilf(sqrtf(outer*outer-near*near))+1);
        lv_area_t a={cx-edge,top,cx-half-1,bottom};
        lv_area_t b={cx+half,top,cx+edge-1,bottom};
        lv_obj_invalidate_area(orb_obj,&a); lv_obj_invalidate_area(orb_obj,&b);
    }
}
/* Only the renderer task calls LVGL after initialization. */
void ui_tick(void)
{
    if(!display) return;
    lock();
    view=current;
    uint32_t job=barrier_active?barrier_id:0;
    if(job) { view.phone=barrier_phone; view.valid=true; view.error=barrier_phone.error[0]!=0; }
    unlock();
    frame_at=remote_now();
    uint64_t start=timing_now_us();
    bool touch_changed=!view.overlay && (view.capture!=drawn.capture || view.mode!=drawn.mode);
    flush_ok=true; frame_flushed=false;
    invalidate_changes(job!=0);
    uint32_t now=remote_now();
    if(!view.overlay && listening() && now-pulse_at>=200) { pulse_at=now; invalidate_pulse(); }
    /* Explicit refresh: no LVGL input/timer can call state or I2C while drawing. */
    lv_refr_now(display);
    if(flush_ok) { drawn=view; drawn_valid=true; } else drawn_valid=false;
    timing_redraw(start,frame_flushed,flush_ok,touch_changed?view.touch_id:0,view.touch_at);
    lock();
    if(job && barrier_active && barrier_id==job && !current.overlay) {
        barrier_done=job; barrier_ok=flush_ok;
#ifndef UI_PREVIEW
        xSemaphoreGive(barrier_signal);
#endif
    }
    unlock();
}
