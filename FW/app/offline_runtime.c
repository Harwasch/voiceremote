#include "offline.h"
#include "offline_capture.h"
#include "offline_store.h"
#include "runtime.h"
#include "board.h"
#include "esp_partition.h"
#include "esp_timer.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "nvs.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "scheduling.h"
#include <string.h>
#include <limits.h>
/* Only this task performs storage IO; the app mutex is NEVER held across flash.
 * Queue holds 16 frames (320 ms nominal), with two reserved control slots.
 * Ordinary SPI1 cache stalls still stop flash-resident code on both CPUs. */
enum { JOB_BEGIN=1, JOB_FRAME, JOB_END, JOB_REQUEST };
typedef struct { uint32_t epoch, connection; uint16_t n, tx; uint8_t kind, mode; bool interrupted; uint64_t tick, utc; uint8_t data[VR_MAX_PACKET]; } job_t;
static vr_store_t *store;
static const esp_partition_t *partition;
static QueueHandle_t jobs;
static vr_local_capture_t policy;
static bool ready, opening, writing, finishing, result_sub, progress_sub, pending_request;
static bool local_error, retained;
static uint8_t announced_status;
static uint32_t flash_max_us;
static unsigned queue_high;
static uint32_t record_epoch, connection_epoch, boot_id, waiting;
static uint64_t free_bytes, total_bytes, latest_id;
static uint32_t latest_offset;
static int64_t clock_offset;
static bool clock_valid;
static vr_fragments_t request_fragments;
static uint16_t response_tx, response_n, response_at, progress_seq, progress_at;
static uint8_t response[512], progress[46];
static bool progress_dirty=true;
static uint64_t now64(void) { return (uint64_t)(esp_timer_get_time()/1000); }
static uint64_t get64(const uint8_t *p) { return vr_get32(p)|(uint64_t)vr_get32(p+4)<<32; }
static void put64(uint8_t *p,uint64_t v) { vr_put32(p,v); vr_put32(p+4,v>>32); }
static bool rd(void *ctx,uint32_t at,void *p,size_t n) { return esp_partition_read(ctx,at,p,n)==ESP_OK; }
static bool wr(void *ctx,uint32_t at,const void *p,size_t n)
{
    int64_t started=esp_timer_get_time(); bool ok=esp_partition_write(ctx,at,p,n)==ESP_OK;
    uint32_t elapsed=(uint32_t)(esp_timer_get_time()-started); if(elapsed>flash_max_us) flash_max_us=elapsed;
    return ok;
}
static bool er(void *ctx,uint32_t at,size_t n) { return esp_partition_erase_range(ctx,at,n)==ESP_OK; }
static bool capturing(void) { return policy.wanted || writing || opening || remote_state.input.streaming || vr_capture_gate(&remote_state); }
static void changed(void)
{
    progress_dirty=true;
    uint8_t bytes[14];
    if(vr_input_encode(&remote_state.input,bytes) && bytes[12]!=announced_status) {
        announced_status=bytes[12]; ui_refresh(); ble_emit(VR_SNAPSHOT,remote_now());
    }
}
static void snapshot_store(void)
{
    waiting=vr_store_count(store); free_bytes=vr_store_free(store); total_bytes=vr_store_total(store);
    remote_state.input.waiting=waiting!=0;
    remote_state.input.full=local_error || store->error || store->full;
    retained=false;
    for(unsigned i=0;i<VR_STORE_MAX_RECORDS;i++) retained|=store->records[i].used;
    retained|=store->error;
    boot_id=store->boot_id;
    progress_dirty=true;
}
void offline_cancel_sync(void)
{
    bool active=remote_state.input.syncing;
    response_n=response_at=progress_at=0; pending_request=false;
    request_fragments.active=false; remote_state.input.syncing=0;
    if(active) changed();
}
static size_t execute(const job_t *j,uint8_t *out)
{
    const uint8_t *p=j->data; out[0]=p[0]; out[1]=0;
    uint64_t id=get64(p+1); int rc=VR_STORE_INVALID; size_t n=2;
    if(p[0]==2) {
        vr_store_meta_t m; rc=vr_store_next(store,id,&m);
        if(!rc) { vr_store_meta_encode(&m,out+2); n=44; }
    } else if(p[0]==3) {
        size_t count=0; uint32_t offset=vr_get32(p+9);
        rc=vr_store_fetch(store,id,offset,out+16,vr_get16(p+13),&count);
        if(!rc) { put64(out+2,id); vr_put32(out+10,offset); vr_put16(out+14,count); n=16+count; }
    } else if(p[0]==4) rc=vr_store_confirm(store,id,vr_get32(p+9),vr_get32(p+13));
    out[1]=rc; return rc?2:n;
}
static void writer(void *arg)
{
    (void)arg; job_t j;
    for(;;) {
        if(xQueueReceive(jobs,&j,portMAX_DELAY)!=pdTRUE) continue;
        remote_lock();
        bool stale=j.kind==JOB_REQUEST ? j.connection!=connection_epoch || !pending_request || j.tx!=response_tx : j.epoch!=record_epoch;
        bool busy=j.kind==JOB_REQUEST && capturing();
        remote_unlock();
        if(stale) continue;
        int rc=0; uint64_t id=0; uint8_t out[512]; size_t n=0;
        if(j.kind==JOB_BEGIN) rc=vr_store_begin(store,j.mode,j.tick,j.utc,&id);
        if(j.kind==JOB_FRAME) rc=vr_store_append(store,j.data,j.n);
        if(j.kind==JOB_END && store->active>=0) rc=vr_store_finish(store,j.interrupted);
        if(j.kind==JOB_REQUEST) { if(busy) { out[0]=j.data[0]; out[1]=3; n=2; } else n=execute(&j,out); }
        remote_lock();
        if(j.kind==JOB_BEGIN) {
            opening=false;
            if(!rc && policy.wanted && j.epoch==record_epoch) writing=true;
            else if(!rc && !finishing) { job_t end={.kind=JOB_END,.epoch=record_epoch,.interrupted=true}; xQueueSend(jobs,&end,0); finishing=true; }
        }
        if(j.kind==JOB_END) { writing=false; opening=false; finishing=false; }
        if(rc) {
            ESP_LOGE("offline","storage status=%d; capture stopped",rc);
            vr_local_failed(&policy); writing=false; opening=false; local_error|=rc!=VR_STORE_END;
            xQueueReset(jobs);
            /* Preserve a verified prefix after append failure, using reserved finish space. */
            if(store->active>=0 && j.kind!=JOB_END) { job_t end={.kind=JOB_END,.epoch=record_epoch,.interrupted=true}; xQueueSend(jobs,&end,0); finishing=true; }
        }
        snapshot_store();
        if(j.kind==JOB_END) ESP_LOGI("offline","finalized waiting=%lu free=%llu queue_high=%u flash_write_max_us=%lu",
            (unsigned long)waiting,(unsigned long long)free_bytes,queue_high,(unsigned long)flash_max_us);
        if(j.kind==JOB_REQUEST && j.connection==connection_epoch && j.tx==response_tx && pending_request && !capturing()) {
            memcpy(response,out,n); response_n=n; response_at=0; response_tx=j.tx;
            if(j.data[0]==3 && out[1]==0) { latest_id=get64(out+2); latest_offset=vr_get32(out+10); remote_state.input.syncing=1; }
        }
        changed(); remote_unlock();
    }
}
void offline_init(void)
{
    if(!(board_info()->capabilities&128)) return;
    nvs_handle_t h; uint32_t hold=0;
    esp_err_t status=nvs_open("remote",NVS_READONLY,&h);
    if(status==ESP_OK) { status=nvs_get_u32(h,"offline_hold",&hold); nvs_close(h); }
    if(hold || (status!=ESP_OK && status!=ESP_ERR_NVS_NOT_FOUND)) {
        remote_state.input.full=1; ui_refresh();
        ESP_LOGE("offline","storage held; local erase and hold reset required"); return;
    }
    partition=esp_partition_find_first(ESP_PARTITION_TYPE_DATA,0x40,"offline");
    /* Board policy may prefer PSRAM, but this core works with internal memory.
     * Flash write buffers/queue/writer stack remain internal. */
    store=board_audio_alloc(sizeof *store);
    int mounted=(!partition || !store)?VR_STORE_ERROR:
        vr_store_init(store,(vr_store_flash_t){(void*)partition,rd,wr,er},partition->size);
    if(!mounted) {
        mounted=vr_store_mount(store);
        if(store->formatted_sectors) ESP_LOGW("offline","factory format ran: erased %lu sectors",(unsigned long)store->formatted_sectors);
    }
    if(mounted) {
        remote_state.input.full=1; ui_refresh(); ESP_LOGE("offline","mount failed; offline disabled, records retained"); return;
    }
    jobs=xQueueCreate(18,sizeof(job_t));
    if(!jobs || xTaskCreate(writer,"flash_writer",6144,NULL,VR_WRITER_PRIORITY,NULL)!=pdPASS) { remote_state.input.full=1; ui_refresh(); return; }
    ready=true; snapshot_store(); ui_refresh();
    ESP_LOGI("offline","ready boot=%lu waiting=%lu free=%llu total=%llu queue_frames=16 store_ram=%u",
        (unsigned long)boot_id,(unsigned long)waiting,(unsigned long long)free_bytes,(unsigned long long)total_bytes,(unsigned)sizeof *store);
}
bool offline_prepare_enrollment(void)
{
    if(!(board_info()->capabilities&128) || (ready && !store->error)) return true;
    /* Re-enrollment around a broken store cannot transfer the old owner's
     * recordings if a subsequent boot recovers it. Maintenance clears the hold
     * only after erasing the old partition. Never silently erase retained data. */
    nvs_handle_t h;
    if(nvs_open("remote",NVS_READWRITE,&h)!=ESP_OK) return false;
    bool saved=nvs_set_u32(h,"offline_hold",1)==ESP_OK && nvs_commit(h)==ESP_OK;
    nvs_close(h);
    if(saved) {
        ready=false; vr_local_owner(&policy,false); offline_cancel_sync();
        if(jobs) xQueueReset(jobs);
        remote_state.input.full=1; ui_refresh();
    }
    return saved;
}
bool offline_enrollment_allowed(void) { return !(board_info()->capabilities&128) || (!ready || ((!retained || store->error) && !opening && !writing && !finishing)); }
/* A bonded reconnect can send progress before the phone is listening, as with Input snapshots. */
void offline_progress_refresh(void) { progress_dirty=true; }
void offline_owner(bool enrolled) { vr_local_owner(&policy,enrolled); }
void offline_disconnect(bool was_live) { ESP_LOGI("offline","link lost was_live=%d capture=%u ptt=%u owner=%d wanted=%d streaming=%d armed=%d",was_live,policy.capture,policy.ptt,policy.owner,policy.wanted,remote_state.input.streaming,remote_state.armed); if(ready) vr_local_disconnect(&policy,was_live); offline_connection_reset(); }
void offline_control(uint8_t event,uint8_t value)
{
    bool was=policy.wanted; uint32_t epoch=policy.epoch;
    vr_local_session(&policy,remote_state.secure && remote_state.info_read && remote_state.input_sub && remote_state.audio_sub && remote_state.snapshot_sent && remote_state.has_phone);
    vr_local_control(&policy,event,value);
    if(event==VR_CAPTURE && value==VR_OFF) {
        offline_cancel_sync();
        if(jobs) xQueueReset(jobs); /* OFF discards volatile frames, never flushes them. */
        if(jobs && (was || writing || opening)) { job_t j={.kind=JOB_END,.epoch=record_epoch}; xQueueSend(jobs,&j,0); finishing=true; }
    } else if(jobs && was && epoch!=policy.epoch && (writing || opening)) {
        job_t j={.kind=JOB_END,.epoch=record_epoch}; xQueueSend(jobs,&j,0); finishing=true;
    }
    if(policy.wanted) { if(!was) local_error=false; offline_cancel_sync(); }
}
bool offline_local_wanted(void) { return ready && policy.wanted; }
bool offline_local_active(void) { return ready && policy.wanted && writing && !finishing; }
bool offline_live_allowed(void) { return !ready || (!policy.block_live && !policy.wanted && !writing && !opening && !finishing); }
void offline_capture_error(void)
{
    vr_local_failed(&policy);
    if(jobs && (writing || opening) && !finishing) {
        xQueueReset(jobs); job_t j={.kind=JOB_END,.epoch=record_epoch,.interrupted=true}; xQueueSend(jobs,&j,0); finishing=true;
    }
    local_error=true; remote_state.input.full=1; changed();
}
bool offline_packet(const uint8_t *p,size_t n)
{
    if(!offline_local_active() || !n || n>VR_MAX_PACKET || uxQueueMessagesWaiting(jobs)>=16) { offline_capture_error(); return false; }
    unsigned depth=uxQueueMessagesWaiting(jobs)+1; if(depth>queue_high) queue_high=depth;
    job_t j={.kind=JOB_FRAME,.epoch=record_epoch,.n=n}; memcpy(j.data,p,n);
    if(xQueueSend(jobs,&j,0)!=pdTRUE) { offline_capture_error(); return false; }
    return true;
}
void offline_connection_reset(void)
{
    connection_epoch++; result_sub=progress_sub=false; progress_seq=0;
    latest_id=latest_offset=0; offline_cancel_sync(); progress_dirty=true;
}
void offline_subscriptions(bool result,bool progress_on)
{
    result_sub=result; progress_sub=progress_on;
    if(!result || !progress_on) offline_cancel_sync();
    progress_dirty=true;
}
int offline_request(const uint8_t *p,size_t n)
{
    if(!ready || !result_sub || !progress_sub || !remote_state.secure || !remote_state.info_read || n<7) goto bad;
    uint16_t tx=vr_get16(p), total=vr_get16(p+2), offset=vr_get16(p+4);
    if(!total || total>21 || offset>=total || n-6>(size_t)(total-offset) || pending_request) goto bad;
    vr_fragments_t *f=&request_fragments;
    if(!offset) { f->id=tx; f->total=total; f->used=0; f->active=true; }
    if(!f->active || f->id!=tx || f->total!=total || f->used!=offset) goto bad;
    memcpy(f->bytes+offset,p+6,n-6); f->used+=n-6;
    if(f->used!=total) return 0;
    f->active=false;
    static const uint8_t sizes[]={0,21,9,15,17}; uint8_t op=f->bytes[0];
    if(op<1 || op>4 || total!=sizes[op]) goto bad;
    bool invalid=(op==3 && (!get64(f->bytes+1) || !vr_get16(f->bytes+13) || vr_get16(f->bytes+13)>496)) ||
        (op==4 && !get64(f->bytes+1));
    pending_request=true; response_tx=tx;
    if(invalid) { response[0]=op; response[1]=4; response_n=2; response_at=0; }
    else if(op==1) {
        uint64_t tick=get64(f->bytes+5), utc=get64(f->bytes+13), now=now64();
        /* Unix range 0001..9999 cannot fit unsigned lower dates; accept epoch..9999. */
        bool valid=vr_get32(f->bytes+1)==boot_id && tick<=now && now-tick<=10000 && utc && utc<=UINT64_C(253402300799999) && tick<=INT64_MAX;
        response[0]=1; response[1]=valid?0:4; response_n=2; response_at=0;
        if(valid) { clock_offset=(int64_t)utc-(int64_t)tick; clock_valid=true; }
    } else if(capturing() || (op==3 && remote_state.input.capture==VR_OFF)) {
        response[0]=op; response[1]=3; response_n=2; response_at=0;
    } else {
        job_t j={.kind=JOB_REQUEST,.connection=connection_epoch,.tx=tx,.n=total}; memcpy(j.data,f->bytes,total);
        if(xQueueSend(jobs,&j,0)!=pdTRUE) { pending_request=false; goto bad; }
    }
    return 1;
bad:
    request_fragments.active=false; return -1;
}
static bool fragment_send(bool is_progress,uint16_t tx,const uint8_t *p,uint16_t n,uint16_t *at)
{
    uint16_t budget=ble_audio_mtu()-3; if(budget<=6) return false;
    uint16_t count=n-*at; if(count>budget-6) count=budget-6;
    uint8_t bytes[518]; vr_put16(bytes,tx); vr_put16(bytes+2,n); vr_put16(bytes+4,*at); memcpy(bytes+6,p+*at,count);
    if(!ble_offline_send(is_progress,bytes,count+6)) return false;
    *at+=count; return true;
}
static void send_progress(void)
{
    if(!progress_at && progress_dirty) {
        memset(progress,0,sizeof progress); uint8_t input[14]; vr_input_encode(&remote_state.input,input); progress[0]=input[12];
        vr_put32(progress+2,waiting); put64(progress+6,free_bytes); put64(progress+14,total_bytes); put64(progress+22,latest_id);
        vr_put32(progress+30,latest_offset); vr_put32(progress+34,boot_id); put64(progress+38,now64()); progress_dirty=false;
    } else if(!progress_at) return;
    if(fragment_send(true,progress_seq,progress,46,&progress_at) && progress_at==46) { progress_at=0; progress_seq++; }
}
void offline_poll(void)
{
    if(!ready) return;
    vr_local_session(&policy,remote_state.secure && remote_state.info_read && remote_state.input_sub && remote_state.audio_sub && remote_state.snapshot_sent && remote_state.has_phone);
    if(policy.wanted && !writing && !opening && !finishing) {
        offline_cancel_sync(); record_epoch++;
        uint64_t tick=now64(), utc=0;
        if(clock_valid && tick<=INT64_MAX) { int64_t value=(int64_t)tick+clock_offset; if(value>0 && value<=INT64_C(253402300799999)) utc=value; }
        job_t j={.kind=JOB_BEGIN,.epoch=record_epoch,.mode=policy.mode,.tick=tick,.utc=utc};
        opening=xQueueSend(jobs,&j,0)==pdTRUE;
        if(!opening) offline_capture_error();
    }
    if((writing || opening) && !policy.wanted && !finishing) {
        job_t j={.kind=JOB_END,.epoch=record_epoch}; finishing=xQueueSend(jobs,&j,0)==pdTRUE;
    }
    if(capturing() && !(response_n==2 && (response[0]==1 || response[1]==3))) {
        if(response_n || remote_state.input.syncing) offline_cancel_sync();
        /* One small status message tells a reconnecting phone where things stand; audio bytes stay paused. */
        if(remote_state.secure && remote_state.info_read && result_sub && progress_sub) send_progress();
        return;
    }
    if(!remote_state.secure || !remote_state.info_read || !result_sub || !progress_sub) return;
    if(response_n) {
        if(fragment_send(false,response_tx,response,response_n,&response_at)) {
            if(response[0]==3 && !response[1]) { uint16_t emitted=response_at>16?response_at-16:0; latest_offset=vr_get32(response+10)+emitted; progress_dirty=true; }
            if(response_at==response_n) { response_n=response_at=0; pending_request=false; remote_state.input.syncing=0; changed(); }
        }
        return;
    }
    if(capturing()) return;
    send_progress();
}
