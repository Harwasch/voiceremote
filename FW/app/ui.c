#include "runtime.h"
#include "board.h"
#include "layout.h"
#include "lvgl.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include <stdio.h>
#include <string.h>
static lv_display_t *display;
static lv_obj_t *capture, *mode, *target, *destination, *recording, *link_label, *error_label;
static lv_obj_t *pair_overlay, *number_label;
static bool flush_ok=true;
static vr_debounce_t control_filters[2];
static uint8_t control_values[2];
static const char *capture_map[]={"OFF","PTT","REC",""};
static const char *mode_map[]={"TRANSCRIBE","AI",""};
static uint32_t ticks(void) { return remote_now(); }
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
    if(data->state==LV_INDEV_STATE_PRESSED) { data->point.x=x; data->point.y=y; }
}
static void select_control(lv_event_t *e)
{
    lv_obj_t *o=lv_event_get_target_obj(e);
    uint32_t v=lv_buttonmatrix_get_selected_button(o);
    if(o==capture && v<=2) control_values[0]=v;
    if(o==mode && v<=1) control_values[1]=v;
}
static void pairing(lv_event_t *e) { (void)e; ble_pair_start(); }
static void revoke(lv_event_t *e) { (void)e; ble_revoke(); }
static void answer(lv_event_t *e) { ble_pair_answer((uintptr_t)lv_event_get_user_data(e)==1); }
static lv_obj_t *label(lv_obj_t *parent,int x,int y,int w,int h,const char *text)
{
    lv_obj_t *o=lv_label_create(parent); lv_obj_set_pos(o,x,y); lv_obj_set_size(o,w,h);
    lv_label_set_long_mode(o,LV_LABEL_LONG_MODE_SCROLL_CIRCULAR);
    lv_label_set_text(o,text); return o;
}
static lv_obj_t *button(lv_obj_t *parent,int x,int y,int w,int h,const char *text,lv_event_cb_t cb,void *arg)
{
    lv_obj_t *b=lv_button_create(parent); lv_obj_set_pos(b,x,y); lv_obj_set_size(b,w,h);
    lv_obj_set_style_pad_all(b,2,0); lv_obj_t *l=lv_label_create(b); lv_label_set_text(l,text); lv_obj_center(l);
    lv_obj_add_event_cb(b,cb,LV_EVENT_CLICKED,arg); return b;
}
void ui_init(void)
{
    const board_info_t *b=board_info();
    if(!b->operational) return;
    lv_init(); lv_tick_set_cb(ticks);
    display=lv_display_create(b->width,b->height); configASSERT(display);
    /* One small internal DMA strip, no shared-code PSRAM dependency. */
    size_t bytes=b->width*16u*2u;
    void *buffer=heap_caps_malloc(bytes,MALLOC_CAP_DMA|MALLOC_CAP_INTERNAL); configASSERT(buffer);
    lv_display_set_color_format(display,LV_COLOR_FORMAT_RGB565);
    lv_display_set_buffers(display,buffer,NULL,bytes,LV_DISPLAY_RENDER_MODE_PARTIAL);
    lv_display_set_flush_cb(display,flush);
    lv_indev_t *indev=lv_indev_create(); lv_indev_set_type(indev,LV_INDEV_TYPE_POINTER); lv_indev_set_read_cb(indev,touch_read);
    lv_obj_t *screen=lv_screen_active(); lv_obj_set_style_bg_color(screen,lv_color_hex(0x09121c),0);
    lv_obj_set_style_text_color(screen,lv_color_white(),0);
    lv_obj_set_style_text_font(screen,&lv_font_montserrat_14,0);
    /* Inscribed rectangle leaves every widget inside the circular boundary. */
    vr_layout_t box=vr_layout(b->width,b->height,b->round);
    int w=box.width,h=box.height,x=box.x,y=box.y,row=box.row;
    label(screen,x,y,w,row,"Voice remote | stage 1: no audio");
    capture=lv_buttonmatrix_create(screen); lv_obj_set_pos(capture,x,y+row); lv_obj_set_size(capture,w,row);
    lv_buttonmatrix_set_map(capture,capture_map); lv_buttonmatrix_set_one_checked(capture,true);
    lv_buttonmatrix_set_button_ctrl_all(capture,LV_BUTTONMATRIX_CTRL_CHECKABLE);
    lv_obj_set_style_pad_all(capture,0,0); lv_obj_set_style_pad_column(capture,2,0);
    lv_obj_add_event_cb(capture,select_control,LV_EVENT_VALUE_CHANGED,NULL);
    mode=lv_buttonmatrix_create(screen); lv_obj_set_pos(mode,x,y+2*row); lv_obj_set_size(mode,w,row);
    lv_buttonmatrix_set_map(mode,mode_map); lv_buttonmatrix_set_one_checked(mode,true);
    lv_buttonmatrix_set_button_ctrl_all(mode,LV_BUTTONMATRIX_CTRL_CHECKABLE);
    lv_obj_set_style_pad_all(mode,0,0); lv_obj_set_style_pad_column(mode,2,0);
    lv_obj_add_event_cb(mode,select_control,LV_EVENT_VALUE_CHANGED,NULL);
    target=label(screen,x,y+3*row,w,row,"Target: unavailable");
    destination=label(screen,x,y+4*row,w,row,"To: unavailable");
    recording=label(screen,x,y+5*row,w,row,"Phone: unavailable | Audio: off");
    link_label=label(screen,x,y+6*row,w,row,"Disconnected");
    error_label=label(screen,x,y+7*row,w,row,"Stage 1 lacks required Opus capability");
    button(screen,x,y+8*row,w/2-2,row,"Pair",pairing,NULL);
    button(screen,x+w/2+2,y+8*row,w/2-2,row,"Revoke bond",revoke,NULL);
    pair_overlay=lv_obj_create(screen); lv_obj_set_pos(pair_overlay,x,y); lv_obj_set_size(pair_overlay,w,h);
    lv_obj_set_style_pad_all(pair_overlay,8,0); lv_obj_remove_flag(pair_overlay,LV_OBJ_FLAG_SCROLLABLE);
    label(pair_overlay,0,row,w-16,2*row,"Compare on phone\nand confirm both");
    number_label=label(pair_overlay,0,3*row,w-16,row,"------");
    button(pair_overlay,0,5*row,w-16,row,"Numbers match",answer,(void*)1);
    button(pair_overlay,0,7*row,w-16,row,"Reject",answer,NULL);
    lv_obj_add_flag(pair_overlay,LV_OBJ_FLAG_HIDDEN);
    ui_refresh(); lv_refr_now(display);
}
static void phone_labels(const vr_phone_t *p)
{
    char text[128];
    snprintf(text,sizeof text,"Target: %s",p->names[p->active]); lv_label_set_text(target,text);
    snprintf(text,sizeof text,"To: %s",p->resolved); lv_label_set_text(destination,text);
    static const char *states[]={"stopped","recording","paused","error"};
    snprintf(text,sizeof text,"Phone: %s | Audio: off",states[p->recording]); lv_label_set_text(recording,text);
    lv_label_set_text(link_label,p->link);
    lv_label_set_text(error_label,p->error);
}
bool ui_phone(const vr_phone_t *p)
{
    if(!display) return false;
    /* Do not acknowledge a destination change while the pairing overlay hides it. */
    if(!lv_obj_has_flag(pair_overlay,LV_OBJ_FLAG_HIDDEN)) return false;
    flush_ok=true; phone_labels(p); lv_refr_now(display); return flush_ok;
}
void ui_refresh(void)
{
    if(!display) return;
    lv_buttonmatrix_set_button_ctrl(capture,remote_state.input.capture,LV_BUTTONMATRIX_CTRL_CHECKED);
    lv_buttonmatrix_set_button_ctrl(mode,remote_state.input.mode,LV_BUTTONMATRIX_CTRL_CHECKED);
    if(!remote_state.has_phone) {
        lv_label_set_text(target,"Target: unavailable"); lv_label_set_text(destination,"To: unavailable");
        lv_label_set_text(recording,"Phone: unavailable | Audio: off");
        lv_label_set_text(error_label,"Stage 1: no Opus; incompatible with full v1");
    }
}
void ui_pair_number(uint32_t number)
{
    if(!display) return;
    char b[16]; snprintf(b,sizeof b,"%06lu",(unsigned long)number); lv_label_set_text(number_label,b);
    lv_obj_remove_flag(pair_overlay,LV_OBJ_FLAG_HIDDEN); lv_refr_now(display);
}
void ui_pair_hide(void) { if(display) lv_obj_add_flag(pair_overlay,LV_OBJ_FLAG_HIDDEN); }
void ui_link(const char *text) { if(display) lv_label_set_text(link_label,text); }
void ui_tick(void)
{
    if(!display) return;
    lv_timer_handler();
    for(unsigned i=0;i<2;i++) {
        uint32_t sampled;
        if(vr_debounce(&control_filters[i],control_values[i],remote_now(),&sampled))
            remote_event(i?VR_MODE:VR_CAPTURE,control_values[i],sampled);
    }
}
