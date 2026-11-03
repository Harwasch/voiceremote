#ifdef UI_PREVIEW
#include "preview_runtime.h"
#include <assert.h>
#include <stdlib.h>
#define configASSERT assert
#else
#include "runtime.h"
#include "esp_heap_caps.h"
#endif
#include "board.h"
#include "layout.h"
#include "lvgl.h"
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
static vr_phone_t shown;
static bool shown_valid, flush_ok=true, error_visible;
static uint32_t error_since, pulse_at, pressed_at, pair_number;
static uint8_t overlay; /* 0: normal, 1: numeric comparison, 2: forget confirmation */
static uint32_t forget_since;
static vr_hit_t pressed;
static bool long_recognised;
static vr_debounce_t control_filters[2];
static uint8_t control_values[2];
static const uint32_t mode_colors[]={0x6fe3ff,0xff6ad5};
static uint32_t ticks(void) { return remote_now(); }
static bool linked(void) { return remote_state.secure && shown_valid; }
static bool listening(void)
{
    return vr_ui_listening(remote_state.input.streaming);
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
enum { IC_OFF, IC_HOLD, IC_REC, IC_TYPE, IC_AI, IC_BT_OFF, IC_BT, IC_X, IC_CHECK, IC_BIN };
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
    if(!linked()) {
        bool up=remote_state.secure;
        icon(up?IC_BT:IC_BT_OFF,cx,y-(layout.ring?42:30)*.32f,(layout.ring?42:30)/26.f,up?0x2f8bff:0x8a9099); return;
    }
    bool error=error_visible && shown.error[0];
    char name[96]; vr_ui_ascii(name,sizeof name,error?shown.error:shown.resolved);
    bool automatic=!error && shown.active==0;
    const lv_font_t *fonts[]={&lexend_42,&lexend_30,&lexend_24};
    int first=layout.ring && layout.scale>.85f?0:1;
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
static void draw_base(lv_event_t *e)
{
    layer=lv_event_get_layer(e);
    if(overlay) {
        float cx=layout.cx, top=layout.ring?300:180, bottom=layout.ring?466:280;
        rect(0,top,cx,bottom,0x2a2d32); rect(cx,top,layout.ring?466:240,bottom,0x30d158);
        float iy=layout.ring?364:222, gap=layout.ring?81:55;
        icon(IC_X,cx-gap,iy,layout.ring?2:1.5f,0xffffff);
        icon(IC_CHECK,cx+gap,iy,layout.ring?2:1.5f,0);
        if(overlay==1) {
            icon(IC_BT,cx,layout.ring?74:32,1.5f,0x2f8bff);
            char digits[8]; snprintf(digits,sizeof digits,"%06lu",(unsigned long)(pair_number%1000000));
            const lv_font_t *font=layout.ring?&lexend_84:&lexend_42;
            int spacing=sz(layout.ring?6:3);
            for(int i=0;i<2;i++) {
                char row[4]; memcpy(row,digits+3*i,3); row[3]=0;
                text(row,cx-text_width(row,font,spacing)/(2*layout.scale),layout.ring?178+86*i:95+52*i,font,0xffffff,spacing);
            }
        } else icon(IC_BIN,cx,layout.ring?164:91,layout.ring?3.5f:2.5f,0x8a9099);
        return;
    }
    if(layout.ring) {
        const float starts[]={-116,-29,50},ends[]={-50,29,116};
        const uint32_t cols[]={0x8a9099,0xffd60a,0xff453a},dim[]={0x8a9099,0xa8922e,0xa8524d};
        for(int i=0;i<3;i++) {
            bool selected=remote_state.input.capture==i;
            arc(233,233,193,starts[i],ends[i],60,selected?cols[i]:0x1d2024);
            float a=(starts[i]+ends[i])/2*3.14159265358979323846f/180;
            icon(i,233+193*sinf(a),233-193*cosf(a),1.8f,selected?0:dim[i]);
        }
    }
    if(linked()) for(int i=0;i<shown.count;i++)
        circle(layout.cx+(i-(shown.count-1)/2.f)*(layout.ring?20:16),layout.pips_y,layout.ring?5:4,
            i==shown.active?0xffffff:0x3a3f45,0,255);
    target_label();
}
static void draw_orb(lv_event_t *e)
{
    layer=lv_event_get_layer(e);
    float cx=layout.cx,cy=layout.cy,r=layout.radius;
    bool off=!linked() || remote_state.input.capture==VR_OFF, live=listening();
    uint32_t color=mode_colors[remote_state.input.mode==1];
    if(off) circle(cx,cy,r,0x3a3f45,6,255);
    else if(live) {
        float phase=(remote_now()%1800)/1800.f;
        circle(cx,cy,r+3+phase*17,color,3,(uint8_t)(100*(1-phase)));
        circle(cx,cy,r,color,0,255);
    } else circle(cx,cy,r,color,8,255);
    icon(remote_state.input.mode?IC_AI:IC_TYPE,cx,cy,r/34,off?0x5b616a:live?0:color);
}
static void invalidate(void)
{
    if(overlay) lv_obj_add_flag(orb_obj,LV_OBJ_FLAG_HIDDEN);
    else lv_obj_remove_flag(orb_obj,LV_OBJ_FLAG_HIDDEN);
    lv_obj_invalidate(screen);
}
static void act(vr_hit_t hit)
{
    if(hit==VR_HIT_NONE) return;
    board_haptic(remote_now());
    if(overlay) {
        uint8_t previous=overlay; overlay=0; invalidate();
        if(previous==1) ble_pair_answer(hit==VR_HIT_CONFIRM);
        else if(hit==VR_HIT_CONFIRM) ble_revoke();
    } else if(hit>=VR_HIT_OFF && hit<=VR_HIT_REC) control_values[0]=hit-VR_HIT_OFF;
    else if(hit==VR_HIT_ORB) control_values[1]=!control_values[1];
    else if(hit==VR_HIT_TARGET) {
        /* Target changes come from the physical button, so a stray touch can't reroute text. */
        if(!linked()) ble_pair_start();
    }
}
static void touch_event(lv_event_t *e)
{
    lv_indev_t *indev=lv_indev_active(); if(!indev) return;
    lv_point_t p; lv_indev_get_point(indev,&p);
    vr_hit_t hit=vr_ui_hit(&layout,p.x,p.y,overlay!=0);
    lv_event_code_t code=lv_event_get_code(e);
    if(code==LV_EVENT_PRESSED) { pressed=hit; pressed_at=remote_now(); long_recognised=false; }
    else if(code==LV_EVENT_PRESSING && hit!=pressed) pressed=VR_HIT_NONE;
    else if(code==LV_EVENT_RELEASED) {
        if(!long_recognised && hit==pressed) act(hit);
        pressed=VR_HIT_NONE;
    } else if(code==LV_EVENT_PRESS_LOST) pressed=VR_HIT_NONE;
}
static void flush(lv_display_t *d,const lv_area_t *a,uint8_t *pixels)
{
    lv_draw_sw_rgb565_swap(pixels,(a->x2-a->x1+1)*(a->y2-a->y1+1));
    if(board_flush(a->x1,a->y1,a->x2,a->y2,pixels)!=ESP_OK) flush_ok=false;
    lv_display_flush_ready(d);
}
static void touch_read(lv_indev_t *dev,lv_indev_data_t *data)
{
    (void)dev; uint16_t x,y;
    data->state=board_touch(&x,&y)?LV_INDEV_STATE_PRESSED:LV_INDEV_STATE_RELEASED;
    if(data->state==LV_INDEV_STATE_PRESSED) data->point=(lv_point_t){x,y};
}
void ui_init(void)
{
    const board_info_t *b=board_info(); if(!b->operational) return;
    layout=vr_layout(b->width,b->height,b->round,b->virtual_sliders);
    lv_init(); lv_tick_set_cb(ticks);
    display=lv_display_create(b->width,b->height); configASSERT(display);
    /* One internal DMA strip; the shared renderer never assumes PSRAM. */
    size_t bytes=b->width*16u*2u;
#ifdef UI_PREVIEW
    void *buffer=malloc(bytes);
#else
    void *buffer=heap_caps_malloc(bytes,MALLOC_CAP_DMA|MALLOC_CAP_INTERNAL);
#endif
    configASSERT(buffer);
    lv_display_set_color_format(display,LV_COLOR_FORMAT_RGB565);
    lv_display_set_buffers(display,buffer,NULL,bytes,LV_DISPLAY_RENDER_MODE_PARTIAL);
    lv_display_set_flush_cb(display,flush);
    lv_indev_t *indev=lv_indev_create(); lv_indev_set_type(indev,LV_INDEV_TYPE_POINTER); lv_indev_set_read_cb(indev,touch_read);
    screen=lv_screen_active(); lv_obj_remove_style_all(screen);
    lv_obj_set_style_bg_color(screen,lv_color_black(),0); lv_obj_set_style_bg_opa(screen,255,0);
    lv_obj_remove_flag(screen,LV_OBJ_FLAG_SCROLLABLE); lv_obj_add_flag(screen,LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_event_cb(screen,draw_base,LV_EVENT_DRAW_MAIN,NULL);
    lv_obj_add_event_cb(screen,touch_event,LV_EVENT_ALL,NULL);
    /* Only this bounded orb area is invalidated at 5 Hz while listening.
     * No full-screen animation, blocking delay or extra framebuffer. */
    orb_obj=lv_obj_create(screen); lv_obj_remove_style_all(orb_obj);
    int extent=sz(layout.radius+22);
    lv_obj_set_pos(orb_obj,sx(layout.cx)-extent,sy(layout.cy)-extent); lv_obj_set_size(orb_obj,extent*2,extent*2);
    lv_obj_remove_flag(orb_obj,LV_OBJ_FLAG_CLICKABLE|LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_event_cb(orb_obj,draw_orb,LV_EVENT_DRAW_MAIN,NULL);
    for(int i=0;i<2;i++) {
        control_values[i]=i?remote_state.input.mode:remote_state.input.capture;
        control_filters[i]=(vr_debounce_t){control_values[i],control_values[i],remote_now()};
    }
    ui_refresh(); lv_refr_now(display);
}
bool ui_phone(const vr_phone_t *p)
{
    if(!display || overlay) return false;
    /* REQ-18: candidate destination is really rendered, including every synchronous
     * DMA flush, before BLE commits it and sends the final write response. Any
     * modal overlay rejects application; BLE restores the old view on failure. */
    shown=*p; shown_valid=true; error_visible=p->error[0]!=0; error_since=remote_now();
    flush_ok=true; invalidate(); lv_refr_now(display); return flush_ok;
}
void ui_refresh(void)
{
    if(!display) return;
    shown_valid=remote_state.has_phone;
    if(shown_valid) shown=remote_state.phone;
    invalidate();
}
void ui_pair_number(uint32_t number)
{
    if(!display) return;
    pair_number=number; overlay=1; pressed=VR_HIT_NONE; invalidate(); lv_refr_now(display);
}
void ui_pair_hide(void) { if(display) { overlay=0; pressed=VR_HIT_NONE; invalidate(); } }
void ui_link(const char *status) { (void)status; ui_refresh(); }
void ui_tick(void)
{
    if(!display) return;
    lv_timer_handler();
    uint32_t now=remote_now();
    if(!overlay && pressed==VR_HIT_TARGET && !long_recognised && now-pressed_at>=3000) {
        long_recognised=true; overlay=2; forget_since=now; board_haptic(now); invalidate();
    }
    /* The confirm screen blocks phone writes, so it must not stay up unattended. */
    if(overlay==2 && now-forget_since>=10000) { overlay=0; pressed=VR_HIT_NONE; invalidate(); }
    if(error_visible && now-error_since>=5000) { error_visible=false; invalidate(); }
    if(!overlay && listening() && now-pulse_at>=200) { pulse_at=now; lv_obj_invalidate(orb_obj); }
    for(unsigned i=0;i<2;i++) {
        uint32_t sampled;
        if(vr_debounce(&control_filters[i],control_values[i],now,&sampled))
            remote_event(i?VR_MODE:VR_CAPTURE,control_values[i],sampled);
    }
}
