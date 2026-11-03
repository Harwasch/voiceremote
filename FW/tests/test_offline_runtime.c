/* Purpose: execute the production offline writer/transport with synthetic IO.
 * Inputs: fake NOR, bounded FIFO and cooperative FreeRTOS writer pump.
 * Verified by host assertions; real flash/cache/radio timing remains unmeasured. */
#include <assert.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nvs.h"
#include "../app/offline_runtime.c"

vr_state_t remote_state;
SemaphoreHandle_t remote_mutex;
struct test_queue { unsigned capacity, stride, head, count; uint8_t bytes[18*sizeof(job_t)]; };
static uint8_t flash[12*VR_STORE_SECTOR];
static esp_partition_t part={sizeof flash};
static board_info_t board={.capabilities=128};
static TaskFunction_t writer_task;
static jmp_buf pump_exit;
static bool pumping, send_ok=true, write_ok=true;
static unsigned lock_depth, io_calls, result_packets, progress_packets, ui_updates;
static uint64_t fake_ms;
static uint32_t storage_hold;
static bool nvs_ok=true;
int nvs_open(const char *name,int mode,nvs_handle_t *h)
{ assert(!strcmp(name,"remote")); (void)mode; *h=1; return nvs_ok?ESP_OK:ESP_FAIL; }
int nvs_get_u32(nvs_handle_t h,const char *key,uint32_t *v)
{ (void)h; assert(!strcmp(key,"offline_hold")); *v=storage_hold; return ESP_OK; }
int nvs_set_u32(nvs_handle_t h,const char *key,uint32_t v)
{ (void)h; assert(!strcmp(key,"offline_hold")); storage_hold=v; return ESP_OK; }
int nvs_commit(nvs_handle_t h) { (void)h; return ESP_OK; }
void nvs_close(nvs_handle_t h) { (void)h; }
static uint16_t mtu=23;
static void (*write_hook)(void);
typedef struct { uint8_t bytes[512]; uint16_t tx, total, used; unsigned complete; } received_t;
static received_t result_rx, progress_rx;

const board_info_t *board_info(void) { return &board; }
void *heap_caps_calloc(size_t n,size_t size,unsigned caps) { (void)caps; return calloc(n,size); }
void *board_audio_alloc(size_t bytes) { return calloc(1,bytes); }
int64_t esp_timer_get_time(void) { return (int64_t)(fake_ms*1000); }
uint32_t remote_now(void) { return (uint32_t)fake_ms; }
void remote_lock(void) { assert(!lock_depth); ++lock_depth; }
void remote_unlock(void) { assert(lock_depth==1); --lock_depth; }
void ui_refresh(void) { ++ui_updates; }
void ble_emit(uint8_t event,uint32_t sampled) { (void)event; (void)sampled; }
uint16_t ble_audio_mtu(void) { return mtu; }
const esp_partition_t *esp_partition_find_first(int type,int subtype,const char *label)
{ assert(type==ESP_PARTITION_TYPE_DATA && subtype==0x40 && !strcmp(label,"offline")); return &part; }
static void io_check(const esp_partition_t *p,uint32_t at,size_t n)
{ assert(!lock_depth && p==&part && at<=sizeof flash && n<=sizeof flash-at); ++io_calls; }
esp_err_t esp_partition_read(const esp_partition_t *p,uint32_t at,void *out,size_t n)
{ io_check(p,at,n); memcpy(out,flash+at,n); return ESP_OK; }
esp_err_t esp_partition_write(const esp_partition_t *p,uint32_t at,const void *in,size_t n)
{
    io_check(p,at,n); if(!write_ok) return ESP_FAIL;
    if(write_hook) { void (*hook)(void)=write_hook; write_hook=NULL; hook(); }
    const uint8_t *bytes=in;
    for(size_t i=0;i<n;++i) { assert((flash[at+i]&bytes[i])==bytes[i]); flash[at+i]&=bytes[i]; }
    return ESP_OK;
}
esp_err_t esp_partition_erase_range(const esp_partition_t *p,uint32_t at,size_t n)
{ io_check(p,at,n); assert(!(at%VR_STORE_SECTOR) && !(n%VR_STORE_SECTOR)); memset(flash+at,255,n); return ESP_OK; }
QueueHandle_t xQueueCreate(UBaseType_t n,UBaseType_t size)
{ assert(n==18 && size==sizeof(job_t)); struct test_queue *q=calloc(1,sizeof *q); assert(q); q->capacity=n; q->stride=size; return q; }
BaseType_t xQueueSend(QueueHandle_t q,const void *data,TickType_t timeout)
{ assert(q && !timeout); if(q->count==q->capacity) return pdFALSE; memcpy(q->bytes+((q->head+q->count)%q->capacity)*q->stride,data,q->stride); ++q->count; return pdTRUE; }
BaseType_t xQueueReceive(QueueHandle_t q,void *data,TickType_t timeout)
{
    assert(q && timeout==portMAX_DELAY && pumping);
    if(!q->count) longjmp(pump_exit,1);
    memcpy(data,q->bytes+q->head*q->stride,q->stride); q->head=(q->head+1)%q->capacity; --q->count; return pdTRUE;
}
BaseType_t xQueueReset(QueueHandle_t q) { q->head=q->count=0; return pdTRUE; }
UBaseType_t uxQueueMessagesWaiting(QueueHandle_t q) { return q->count; }
BaseType_t xTaskCreate(TaskFunction_t fn,const char *name,uint32_t stack,void *arg,UBaseType_t priority,TaskHandle_t *handle)
{ (void)name; (void)stack; (void)arg; (void)priority; (void)handle; writer_task=fn; return pdPASS; }
bool ble_offline_send(bool is_progress,const uint8_t *p,size_t n)
{
    assert(n>6 && n<=(size_t)mtu-3); if(!send_ok) return false;
    received_t *rx=is_progress?&progress_rx:&result_rx;
    uint16_t tx=vr_get16(p), total=vr_get16(p+2), at=vr_get16(p+4);
    assert(total<=sizeof rx->bytes && at+n-6<=total);
    if(!at) { rx->used=0; rx->tx=tx; rx->total=total; }
    assert(rx->tx==tx && rx->total==total && rx->used==at);
    memcpy(rx->bytes+at,p+6,n-6); rx->used+=(uint16_t)(n-6);
    if(rx->used==rx->total) ++rx->complete;
    if(is_progress) ++progress_packets; else ++result_packets;
    return true;
}
static void pump(void)
{ assert(writer_task && !lock_depth); pumping=true; if(!setjmp(pump_exit)) writer_task(NULL); pumping=false; assert(!lock_depth); }
static void reset(bool erase)
{
    free(store); free(jobs); store=NULL; jobs=NULL; partition=NULL;
    policy=(vr_local_capture_t){0}; remote_state=(vr_state_t){0};
    ready=opening=writing=finishing=result_sub=progress_sub=pending_request=false;
    local_error=retained=false; announced_status=0; flash_max_us=0; queue_high=0;
    record_epoch=connection_epoch=boot_id=waiting=0; free_bytes=total_bytes=latest_id=0;
    latest_offset=0; clock_offset=0; clock_valid=false; request_fragments=(vr_fragments_t){0};
    response_tx=response_n=response_at=progress_seq=progress_at=0; progress_dirty=true;
    result_rx=(received_t){0}; progress_rx=(received_t){0}; result_packets=progress_packets=io_calls=0;
    fake_ms=1000; mtu=23; send_ok=write_ok=true; write_hook=NULL; board.capabilities=128;
    if(erase) { memset(flash,255,sizeof flash); storage_hold=0; nvs_ok=true; }
    ui_updates=0; offline_init(); assert(ready && store && jobs); offline_owner(true);
}
static void control(uint8_t event,uint8_t value)
{ offline_control(event,value); vr_control(&remote_state,event,value,(uint32_t)fake_ms); }
static void connect_phone(void)
{
    remote_state.secure=remote_state.info_read=remote_state.input_sub=remote_state.audio_sub=true;
    remote_state.snapshot_sent=remote_state.has_phone=true; offline_subscriptions(true,true);
}
static void start_local(void)
{ control(VR_CAPTURE,VR_REC); offline_poll(); assert(opening && !writing); pump(); assert(offline_local_active()); }
static void end_local(void)
{ control(VR_CAPTURE,VR_PTT); pump(); offline_poll(); assert(!writing && !opening && !finishing); }
static int request(const uint8_t *p,size_t n,uint16_t tx)
{
    uint8_t bytes[27]; size_t at=0; int rc=0;
    while(at<n) { size_t count=n-at; if(count>7) count=7; vr_put16(bytes,tx); vr_put16(bytes+2,n); vr_put16(bytes+4,at); memcpy(bytes+6,p+at,count); rc=offline_request(bytes,count+6); at+=count; assert(rc==(at==n?1:0)); }
    return rc;
}
static void reply(void)
{ pump(); for(unsigned i=0;i<100 && pending_request;++i) offline_poll(); assert(!pending_request && !response_n && result_rx.used==result_rx.total); }
static void assert_bytes(const received_t *rx,const uint8_t *expected,size_t n)
{ assert(rx->total==n && rx->used==n && !memcmp(rx->bytes,expected,n)); }

static void pending_begin_off(void)
{
    reset(true); control(VR_CAPTURE,VR_REC); offline_poll(); assert(opening && jobs->count==1);
    unsigned before=io_calls; control(VR_CAPTURE,VR_OFF); assert(!offline_local_wanted()); pump(); offline_poll();
    assert(io_calls==before && store->allocated_id==0 && vr_store_count(store)==0);
    assert(!opening && !writing && !finishing && !remote_state.input.full && offline_live_allowed());
}
static void switch_off_during_write(void)
{ remote_lock(); control(VR_CAPTURE,VR_OFF); remote_unlock(); }
static void inflight_begin_off(void)
{
    reset(true); control(VR_CAPTURE,VR_REC); offline_poll(); assert(opening);
    write_hook=switch_off_during_write; pump(); offline_poll();
    assert(!opening && !writing && !finishing && !remote_state.input.full && offline_live_allowed());
    assert(store->allocated_id==1 && !vr_store_count(store));
}
static void off_discards_volatile(void)
{
    static const uint8_t packet[]={0,1,2}; reset(true); start_local();
    assert(offline_packet(packet,sizeof packet)); pump();
    for(unsigned i=0;i<5;++i) assert(offline_packet(packet,sizeof packet));
    control(VR_CAPTURE,VR_OFF); assert(jobs->count==1 && !offline_local_active()); pump();
    vr_store_meta_t m; assert(vr_store_next(store,0,&m)==0 && m.frames==1 && m.bytes==5);
    connect_phone(); uint8_t fetch[15]={3}; put64(fetch+1,m.id); vr_put16(fetch+13,5);
    request(fetch,sizeof fetch,1); reply(); const uint8_t busy[]={3,3}; assert_bytes(&result_rx,busy,sizeof busy);
}
static void queue_overflow_stops(void)
{
    static const uint8_t packet[]={0,1,2}; reset(true); start_local();
    assert(offline_packet(packet,sizeof packet)); pump();
    for(unsigned i=0;i<16;++i) assert(offline_packet(packet,sizeof packet));
    assert(jobs->count==16 && !offline_packet(packet,sizeof packet));
    assert(jobs->count==1 && !offline_local_wanted() && remote_state.input.full); pump();
    vr_store_meta_t m; assert(!vr_store_next(store,0,&m) && m.frames==1 && (m.flags&2));
    assert(remote_state.input.full);
    offline_poll(); assert(!offline_local_wanted() && !writing); /* no automatic restart */
}
static void storage_full_stops(void)
{
    uint8_t packet[VR_MAX_PACKET]={0}; reset(true); start_local();
    unsigned frames=0;
    while(offline_local_wanted() && frames<200) { assert(offline_packet(packet,sizeof packet)); pump(); ++frames; }
    assert(frames<200 && remote_state.input.full && !writing && !finishing);
    vr_store_meta_t m; assert(!vr_store_next(store,0,&m) && m.frames>0 && m.frames<frames && (m.flags&2));
    unsigned before=io_calls; offline_poll(); pump(); assert(before==io_calls && !offline_local_wanted());
}
static void write_failure_stops(void)
{
    static const uint8_t packet[]={0,1,2}; reset(true); start_local();
    assert(offline_packet(packet,sizeof packet)); pump();
    write_ok=false; assert(offline_packet(packet,sizeof packet)); pump();
    assert(!offline_local_wanted() && !writing && remote_state.input.full);
    reset(false); vr_store_meta_t m; assert(!vr_store_next(store,0,&m) && m.frames==1 && (m.flags&2));
}
static void sync_vectors_and_resume(void)
{
    static const uint8_t packet[]={0,1,2};
    static const uint8_t c2[]={2,0,0,0,0,0,0,0,0};
    static const uint8_t c3[]={3,1,0,0,0,0,0,0,0,0,0,0,0,5,0};
    static const uint8_t c4[]={4,1,0,0,0,0,0,0,0,5,0,0,0,0xa0,0xdd,0x97,0x76};
    static const uint8_t r2[]={2,0,1,0,0,0,0,0,0,0,7,0,0,0,0xe8,3,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,5,0,0,0,1,0,0,0,0xa0,0xdd,0x97,0x76};
    static const uint8_t r3[]={3,0,1,0,0,0,0,0,0,0,0,0,0,0,5,0,3,0,0,1,2};
    static const uint8_t r4[]={4,0}, end[]={2,1};
    reset(true); for(unsigned i=1;i<7;++i) reset(false); assert(boot_id==7 && offline_enrollment_allowed());
    start_local(); assert(!offline_enrollment_allowed());
    assert(offline_packet(packet,sizeof packet)); pump(); end_local(); assert(!offline_enrollment_allowed()); connect_phone();
    request(c2,sizeof c2,9); reply(); assert(result_rx.tx==9); assert_bytes(&result_rx,r2,sizeof r2);
    request(c3,sizeof c3,10); reply(); assert_bytes(&result_rx,r3,sizeof r3); assert(latest_id==1 && latest_offset==5);
    uint8_t resume[sizeof c3]; memcpy(resume,c3,sizeof resume); vr_put32(resume+9,2); vr_put16(resume+13,2);
    request(resume,sizeof resume,11); reply(); assert(result_rx.total==18 && !memcmp(result_rx.bytes+16,packet,2) && latest_offset==4);
    offline_connection_reset(); connect_phone(); request(c3,sizeof c3,12); reply(); assert_bytes(&result_rx,r3,sizeof r3);
    request(c4,sizeof c4,13); reply(); assert_bytes(&result_rx,r4,sizeof r4); assert(vr_store_count(store)==0 && offline_enrollment_allowed());
    reset(false); assert(boot_id==8 && store->allocated_id==1); connect_phone();
    request(c4,sizeof c4,14); reply(); assert_bytes(&result_rx,r4,sizeof r4);
    request(c2,sizeof c2,15); reply(); assert_bytes(&result_rx,end,sizeof end);
    remote_state.secure=false; remote_state.has_phone=false; start_local(); assert(store->allocated_id==2); end_local();
}
static void clock_and_progress(void)
{
    static const uint8_t c1[]={1,7,0,0,0,0xe8,3,0,0,0,0,0,0,0,0x68,0xe5,0xcf,0x8b,1,0,0};
    static const uint8_t r1[]={1,0}, invalid[]={1,4};
    reset(true); for(unsigned i=1;i<7;++i) reset(false); connect_phone();
    request(c1,sizeof c1,20); reply(); assert_bytes(&result_rx,r1,sizeof r1);
    assert(clock_valid && clock_offset==INT64_C(1700000000000)-1000);
    fake_ms=11001; request(c1,sizeof c1,21); reply(); assert_bytes(&result_rx,invalid,sizeof invalid);
    fake_ms=2000; uint8_t bad[21]; memcpy(bad,c1,sizeof bad); vr_put32(bad+1,6);
    request(bad,sizeof bad,22); reply(); assert_bytes(&result_rx,invalid,sizeof invalid);
    for(unsigned i=0;i<10;++i) offline_poll();
    assert(progress_rx.complete && progress_rx.total==46);
    assert(vr_get32(progress_rx.bytes+34)==7 && get64(progress_rx.bytes+38)==2000);
    assert(get64(progress_rx.bytes+6)<=get64(progress_rx.bytes+14));
    remote_state.secure=false; remote_state.has_phone=false; start_local();
    assert(store->records[store->active].meta.utc==UINT64_C(1700000001000));
    connect_phone(); uint8_t refresh[sizeof c1]; memcpy(refresh,c1,sizeof refresh);
    put64(refresh+5,2000); put64(refresh+13,UINT64_C(1800000000000));
    request(refresh,sizeof refresh,23); reply(); assert_bytes(&result_rx,r1,sizeof r1);
    assert(store->records[store->active].meta.utc==UINT64_C(1700000001000)); /* capture-start time immutable */
    end_local();
}
static void live_preempts_sync(void)
{
    static const uint8_t c2[]={2,0,0,0,0,0,0,0,0}; reset(true); connect_phone();
    request(c2,sizeof c2,30); assert(pending_request && jobs->count==1);
    remote_state.input.streaming=1; unsigned before=io_calls; pump(); offline_poll();
    assert(io_calls==before); /* no flash transfer competes with capture */
    unsigned sent=result_packets; offline_cancel_sync(); offline_poll(); assert(result_packets==sent && !pending_request);
    remote_state.input.streaming=0; request(c2,sizeof c2,31); pump(); assert(response_n==2);
    remote_state.input.streaming=1; offline_poll(); assert(!response_n && !pending_request && result_packets==sent);
    remote_state.input.streaming=0; request(c2,sizeof c2,32); pump(); send_ok=false; offline_poll(); assert(response_n);
    remote_state.input.streaming=1; send_ok=true; offline_poll(); assert(!response_n && result_packets==sent);
    /* Partial progress must finish during capture, including MTU 23. */
    remote_state.input.streaming=0; offline_poll(); assert(progress_at);
    remote_state.input.streaming=1; before=progress_rx.complete;
    for(unsigned i=0;i<8;++i) offline_poll();
    assert(!progress_at && progress_rx.complete==before+1);
    before=progress_rx.complete; offline_progress_refresh();
    for(unsigned i=0;i<8;++i) offline_poll();
    assert(progress_rx.complete==before+1);
}
static void recovered_error_visible(void)
{
    static const uint8_t packet[]={0,1,2}; reset(true); start_local();
    assert(offline_packet(packet,sizeof packet)); pump(); end_local();
    flash[2*VR_STORE_SECTOR+64+8]^=1; reset(false);
    assert(store->error && remote_state.input.full && ui_updates);
}
static void broken_mount(void)
{
    reset(true); free(jobs); jobs=NULL; ready=false;
    /* A recognizable damaged journal must fail without wiping retained data. */
    flash[40]^=1; free(store); store=NULL; ui_updates=0; offline_init();
    assert(!ready && !jobs && remote_state.input.full && ui_updates);
    assert(offline_enrollment_allowed() && offline_live_allowed());
    control(VR_CAPTURE,VR_REC); control(VR_CAPTURE,VR_OFF);
    assert(!finishing && offline_live_allowed());
    control(VR_CAPTURE,VR_REC); control(VR_MODE,1);
    assert(!finishing && offline_live_allowed());
}
static void re_enrollment_quarantine(void)
{
    recovered_error_visible();
    assert(offline_enrollment_allowed());
    nvs_ok=false; assert(!offline_prepare_enrollment()); nvs_ok=true;
    assert(offline_prepare_enrollment() && storage_hold==1 && !ready && offline_live_allowed());
    /* Repairing the old store after the new bond must not release old audio. */
    flash[2*VR_STORE_SECTOR+64+8]^=1;
    free(store); free(jobs); store=NULL; jobs=NULL; offline_init();
    assert(!ready && !store && !jobs && remote_state.input.full);
    connect_phone(); const uint8_t list[]={0,0,9,0,0,0,2,0,0,0,0,0,0,0,0};
    assert(offline_request(list,sizeof list)==-1 && offline_live_allowed());
    reset(true); /* Explicit local maintenance: erase old data and clear hold. */
}
static void unsupported_board(void)
{
    free(store); free(jobs); store=NULL; jobs=NULL; ready=false; io_calls=0;
    remote_state=(vr_state_t){0}; board.capabilities=0; offline_init();
    assert(!ready && !store && !jobs && !io_calls && !remote_state.input.full && offline_enrollment_allowed());
}
int main(int argc,char **argv)
{
    if(argc>1 && !strcmp(argv[1],"mount")) { broken_mount(); return 0; }
    pending_begin_off(); inflight_begin_off(); off_discards_volatile(); queue_overflow_stops(); storage_full_stops(); write_failure_stops();
    sync_vectors_and_resume(); clock_and_progress(); live_preempts_sync(); recovered_error_visible(); broken_mount(); re_enrollment_quarantine(); unsupported_board();
    free(store); free(jobs);
    puts("offline runtime: production writer/queue, OFF, overflow, clock/progress, sync/resume/delete and live priority pass");
}
