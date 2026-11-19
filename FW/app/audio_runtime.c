#include "audio.h"
#include "offline.h"
#include "timing.h"
#include "runtime.h"
#include "board.h"
#include "opus.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_heap_caps.h"
#include "esp_clk_tree.h"
#include "freertos/task.h"
#include "scheduling.h"
#include <string.h>
#include <stdlib.h>

static vr_stream_t stream;
static OpusEncoder *encoder;
static TaskHandle_t worker;
static uint32_t generation, worker_generation, closing_at;
static uint64_t encode_us;
static unsigned encoded, max_us, notify_failures;
static int source_error;
static size_t internal_before, external_before;
static bool closing, reported, local_running;
static bool local_stop_snapshot;
static void stop_local(void)
{
    if(!local_running) return;
    board_mic_stop(); generation++;
    if(worker && xTaskGetCurrentTaskHandle()!=worker) vTaskSuspend(worker);
    local_running=false; remote_state.input.offline=0;
    /* Sent from audio_poll, so a control edge that caused this stop is reported first. */
    local_stop_snapshot=true; ui_refresh();
}
static void lock(void) { xSemaphoreTakeRecursive(remote_mutex,portMAX_DELAY); }
static void unlock(void) { xSemaphoreGiveRecursive(remote_mutex); }
static void stats(void)
{
    if(reported || !stream.segment) return;
    reported=true;
    uint32_t hz=0; esp_clk_tree_src_get_freq_hz(SOC_MOD_CLK_CPU,ESP_CLK_TREE_SRC_FREQ_PRECISION_CACHED,&hz);
    size_t internal=heap_caps_get_free_size(MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT);
    size_t external=heap_caps_get_free_size(MALLOC_CAP_SPIRAM|MALLOC_CAP_8BIT);
    ESP_LOGI("audio","segment=%lu frames=%u encode_us_mean=%llu max=%u queue_high=%u dropped=%u notify_failures=%u source_error=%d internal_free=%u delta=%d psram_free=%u delta=%d cpu_hz=%lu stack_free=%u",
        (unsigned long)stream.segment,encoded,(unsigned long long)(encoded?encode_us/encoded:0),max_us,
        stream.high_water,stream.dropped,notify_failures,source_error,(unsigned)internal,(int)(internal-internal_before),
        (unsigned)external,(int)(external-external_before),(unsigned long)hz,
        (unsigned)uxTaskGetStackHighWaterMark(worker));
}
static void stopped_snapshot(void)
{
    closing=false; remote_state.input.streaming=0;
    ble_emit(VR_SNAPSHOT,remote_now()); ui_refresh(); stats();
}
static void try_end(void)
{
    if(!stream.ending) return;
    uint8_t value[12]; size_t n=vr_stream_peek(&stream,ble_audio_mtu(),value,sizeof value);
    if(n && ble_audio_end(value,n)) vr_stream_sent(&stream);
    else notify_failures++;
}
bool audio_input_allowed(void) { return !closing || !stream.ending; }
void audio_notify_failed(void) { notify_failures++; audio_fault(); }
static void stop(void)
{
    if(!stream.running) return;
    board_mic_stop(); generation++;
    /* Opus init/encode has no heap operations (caller state + alloca scratch).
       Suspend a computation in flight on OFF; it resumes only for a new segment,
       and its generation is discarded before it can enter the output queue. */
    if(worker && xTaskGetCurrentTaskHandle()!=worker) vTaskSuspend(worker);
    vr_stream_stop(&stream); remote_state.input.streaming=0;
    closing=true; closing_at=remote_now(); ui_refresh();
    try_end();
}
void audio_fault(void)
{
    if(local_running) { offline_capture_error(); stop_local(); return; }
    remote_state.audio_fault=true; remote_state.recovery_release=!remote_state.input.ptt;
    remote_state.armed=false; remote_state.snapshot_sent=false;
    stop();
}
void audio_reset(void)
{
    /* A BLE session reset never restarts a locally owned encoder. Its record
     * keeps one codec history through reconnect, until a local boundary. */
    if(local_running) { memset(&stream,0,sizeof stream); closing=false; remote_state.input.streaming=0; return; }
    stop(); stats(); memset(&stream,0,sizeof stream); closing=false;
    generation++; remote_state.input.streaming=0;
}
static int setup_encoder(void)
{
    int e=opus_encoder_init(encoder,16000,1,OPUS_APPLICATION_VOIP);
    if(e) return e;
    e=opus_encoder_ctl(encoder,OPUS_SET_BITRATE(VR_AUDIO_BITRATE));
    e|=opus_encoder_ctl(encoder,OPUS_SET_COMPLEXITY(0));
    e|=opus_encoder_ctl(encoder,OPUS_SET_VBR(0));
    e|=opus_encoder_ctl(encoder,OPUS_SET_DTX(0));
    e|=opus_encoder_ctl(encoder,OPUS_SET_INBAND_FEC(0));
    e|=opus_encoder_ctl(encoder,OPUS_SET_MAX_BANDWIDTH(OPUS_BANDWIDTH_WIDEBAND));
    return e;
}
static void encode_task(void *arg)
{
    (void)arg; int16_t pcm[VR_AUDIO_SAMPLES]; uint8_t packet[VR_MAX_PACKET];
    for(;;) {
        lock();
        if((!stream.running && !local_running) || (!local_running && stream.next_frame==UINT16_MAX)) { unlock(); vTaskDelay(pdMS_TO_TICKS(2)); continue; }
        uint32_t g=generation;
        bool reset=worker_generation!=g;
        esp_err_t read=board_mic_read(pcm);
        unlock();
        if(read==ESP_ERR_NOT_FINISHED) { vTaskDelay(pdMS_TO_TICKS(1)); continue; }
        if(read!=ESP_OK) { lock(); if(g==generation) { source_error=read; audio_fault(); } unlock(); continue; }
        /* Nothing below touches board/UI/state until the generation is rechecked. */
        int result=reset?setup_encoder():OPUS_OK;
        int64_t at=esp_timer_get_time();
        if(!result) result=opus_encode(encoder,pcm,VR_AUDIO_SAMPLES,packet,VR_MAX_PACKET);
        unsigned elapsed=(unsigned)(esp_timer_get_time()-at);
        timing_encode(elapsed);
        lock();
        if(g==generation && (stream.running || local_running)) {
            worker_generation=g;
            if(result<=0) { source_error=result; audio_fault(); }
            else {
                encoded++; encode_us+=elapsed; if(elapsed>max_us) max_us=elapsed;
                if(local_running) { if(!offline_packet(packet,result)) stop_local(); }
                else if(!vr_stream_push(&stream,packet,result)) {
                    /* push already discarded the queue; stop still owns board/task. */
                    stream.running=true; audio_fault();
                }
                timing_queue(stream.count);
            }
        }
        unlock();
    }
}
void audio_init(void)
{
    size_t before=heap_caps_get_free_size(MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT);
    size_t psram=heap_caps_get_free_size(MALLOC_CAP_SPIRAM|MALLOC_CAP_8BIT);
    encoder=board_audio_alloc(opus_encoder_get_size(1));
    if(!encoder || xTaskCreate(encode_task,"opus",VR_AUDIO_STACK,NULL,VR_AUDIO_PRIORITY,&worker)!=pdPASS) {
        ESP_LOGE("audio","encoder allocation failed; capture disabled"); free(encoder); encoder=NULL; return;
    }
    ESP_LOGI("audio","allocation internal_delta=%d psram_delta=%d encoder_bytes=%d stack_bytes=%u",
        (int)(heap_caps_get_free_size(MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT)-before),
        (int)(heap_caps_get_free_size(MALLOC_CAP_SPIRAM|MALLOC_CAP_8BIT)-psram),opus_encoder_get_size(1),VR_AUDIO_STACK);
}
void audio_sync(void)
{
    if(local_running && !offline_local_active()) stop_local();
    if(stream.running && (!vr_capture_gate(&remote_state) || !offline_live_allowed())) stop();
}
/* Send failures clear streaming just before the disconnect event arrives, so link loss
 * asks whether audio flowed very recently rather than whether it's flowing right now. */
static uint32_t live_at;
bool audio_recently_live(void) { return live_at && (uint32_t)(remote_now()-live_at)<1000; }
void audio_poll(void)
{
    audio_sync();
    if(stream.running) live_at=remote_now();
    if(local_stop_snapshot) { local_stop_snapshot=false; ble_emit(VR_SNAPSHOT,remote_now()); }
    timing_queue(stream.count);
    if(closing) {
        if(stream.ending && ble_audio_ready()) try_end();
        if(!stream.ending && ble_audio_ready()) stopped_snapshot();
        /* A failed END must never be overtaken by the stopped Input snapshot. */
        if(closing && (uint32_t)(remote_now()-closing_at)>=1000) {
            stats(); ble_audio_disconnect();
        }
        return;
    }
    if(!local_running && !stream.running && offline_local_active() && encoder) {
        offline_cancel_sync(); generation++;
        esp_err_t mic=board_mic_start();
        if(mic!=ESP_OK) { offline_capture_error(); return; }
        local_running=true; remote_state.input.offline=1; remote_state.input.streaming=0;
        vTaskResume(worker); ble_emit(VR_SNAPSHOT,remote_now()); ui_refresh();
        ESP_LOGI("offline","capture started mode=%u",remote_state.input.mode);
    }
    if(local_running) return;
    if(!stream.running && offline_live_allowed() && vr_capture_gate(&remote_state) && encoder) {
        if(!vr_stream_begin(&stream)) { audio_fault(); ble_audio_disconnect(); return; }
        offline_cancel_sync(); generation++; encode_us=0; encoded=max_us=notify_failures=0; source_error=0; reported=false;
        internal_before=heap_caps_get_free_size(MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT);
        external_before=heap_caps_get_free_size(MALLOC_CAP_SPIRAM|MALLOC_CAP_8BIT);
        esp_err_t mic=board_mic_start();
        if(mic!=ESP_OK) { source_error=mic; audio_fault(); return; }
        vTaskResume(worker);
    }
    if(!stream.running || !stream.count || !ble_audio_ready()) return;
    uint8_t value[VR_MAX_PACKET+VR_AUDIO_HEADER];
    size_t n=vr_stream_peek(&stream,ble_audio_mtu(),value,sizeof value);
    if(!n || !ble_audio_send(value,n)) { notify_failures++; audio_fault(); return; }
    bool first=!stream.started;
    vr_stream_sent(&stream);
    if(first) { remote_state.input.streaming=1; ble_emit(VR_SNAPSHOT,remote_now()); ui_refresh(); }
    if(!stream.running) { stream.running=true; audio_fault(); } /* sequence limit */
}
