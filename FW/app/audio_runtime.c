#include "audio.h"
#include "runtime.h"
#include "board.h"
#include "opus.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_heap_caps.h"
#include "esp_clk_tree.h"
#include "freertos/task.h"
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
static bool closing, reported;
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
    remote_state.audio_fault=true; remote_state.recovery_release=!remote_state.input.ptt;
    remote_state.armed=false; remote_state.snapshot_sent=false;
    stop();
}
void audio_reset(void)
{
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
        if(!stream.running || stream.next_frame==UINT16_MAX) { unlock(); vTaskDelay(pdMS_TO_TICKS(2)); continue; }
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
        lock();
        if(g==generation && stream.running) {
            worker_generation=g;
            if(result<=0) { source_error=result; audio_fault(); }
            else {
                encoded++; encode_us+=elapsed; if(elapsed>max_us) max_us=elapsed;
                if(!vr_stream_push(&stream,packet,result)) {
                    /* push already discarded the queue; stop still owns board/task. */
                    stream.running=true; audio_fault();
                }
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
    if(!encoder || xTaskCreate(encode_task,"opus",48*1024,NULL,4,&worker)!=pdPASS) {
        ESP_LOGE("audio","encoder allocation failed; capture disabled"); free(encoder); encoder=NULL; return;
    }
    ESP_LOGI("audio","allocation internal_delta=%d psram_delta=%d encoder_bytes=%d stack_bytes=%u",
        (int)(heap_caps_get_free_size(MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT)-before),
        (int)(heap_caps_get_free_size(MALLOC_CAP_SPIRAM|MALLOC_CAP_8BIT)-psram),opus_encoder_get_size(1),48*1024u);
}
void audio_sync(void)
{
    if(stream.running && !vr_capture_gate(&remote_state)) stop();
}
void audio_poll(void)
{
    audio_sync();
    if(closing) {
        if(stream.ending && ble_audio_ready()) try_end();
        if(!stream.ending && ble_audio_ready()) stopped_snapshot();
        /* A failed END must never be overtaken by the stopped Input snapshot. */
        if(closing && (uint32_t)(remote_now()-closing_at)>=1000) {
            stats(); ble_audio_disconnect();
        }
        return;
    }
    if(!stream.running && vr_capture_gate(&remote_state) && encoder) {
        if(!vr_stream_begin(&stream)) { audio_fault(); ble_audio_disconnect(); return; }
        generation++; encode_us=0; encoded=max_us=notify_failures=0; source_error=0; reported=false;
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
