/* Purpose: production audio lifecycle and offline codec continuity regression.
 * Inputs: synthetic microphone/codec and cooperative task stubs. Verified by host
 * assertions; no audio, board, Bluetooth or physical timing measurements. */
#include <assert.h>
#include <setjmp.h>
#include <stdio.h>
#include "../app/audio_runtime.c"

vr_state_t remote_state;
SemaphoreHandle_t remote_mutex;
static OpusEncoder fake_encoder;
static bool local_active, in_worker, stop_in_encode;
static unsigned mic_starts, mic_stops, suspends, resumes, local_packets, sync_cancels, lock_depth;
static uint32_t fake_now=1000;
static uint8_t event_log[8]; static unsigned event_count;
static jmp_buf worker_exit;
static TaskHandle_t fake_worker=(void *)(uintptr_t)1;

uint32_t remote_now(void) { return fake_now; }
int64_t esp_timer_get_time(void) { return 1000000; }
void ui_refresh(void) {}
void ble_emit(uint8_t event,uint32_t tick) { (void)tick; assert(event_count<sizeof event_log); event_log[event_count++]=event; }
bool offline_local_active(void) { return local_active; }
bool offline_live_allowed(void) { return !local_active; }
void offline_cancel_sync(void) { ++sync_cancels; }
void offline_capture_error(void) { local_active=false; }
bool offline_packet(const uint8_t *p,size_t n) { assert(p && n==3); ++local_packets; return true; }
esp_err_t board_mic_start(void) { ++mic_starts; return ESP_OK; }
void board_mic_stop(void) { ++mic_stops; }
esp_err_t board_mic_read(int16_t pcm[320]) { memset(pcm,0,320*sizeof *pcm); return ESP_OK; }
void *board_audio_alloc(size_t n) { return calloc(1,n); }
size_t heap_caps_get_free_size(unsigned caps) { (void)caps; return 100000; }
esp_err_t esp_clk_tree_src_get_freq_hz(int source,int precision,uint32_t *hz)
{ (void)source; (void)precision; *hz=240000000; return ESP_OK; }
BaseType_t xSemaphoreTakeRecursive(SemaphoreHandle_t mutex,TickType_t timeout)
{ (void)mutex; (void)timeout; assert(!lock_depth); ++lock_depth; return pdTRUE; }
BaseType_t xSemaphoreGiveRecursive(SemaphoreHandle_t mutex)
{ (void)mutex; assert(lock_depth==1); --lock_depth; return pdTRUE; }
BaseType_t xTaskCreate(TaskFunction_t fn,const char *name,uint32_t stack,void *arg,UBaseType_t priority,TaskHandle_t *handle)
{ (void)fn; (void)name; (void)stack; (void)arg; (void)priority; if(handle) *handle=fake_worker; return pdPASS; }
TaskHandle_t xTaskGetCurrentTaskHandle(void) { return in_worker?fake_worker:NULL; }
void vTaskSuspend(TaskHandle_t handle) { assert(handle==fake_worker); ++suspends; }
void vTaskResume(TaskHandle_t handle) { assert(handle==fake_worker); ++resumes; }
void vTaskDelay(TickType_t ticks) { (void)ticks; assert(in_worker && !lock_depth); longjmp(worker_exit,1); }
UBaseType_t uxTaskGetStackHighWaterMark(TaskHandle_t handle) { (void)handle; return 1000; }
bool ble_audio_ready(void) { return true; }
uint16_t ble_audio_mtu(void) { return 23; }
bool ble_audio_send(const uint8_t *p,size_t n) { (void)p; (void)n; return true; }
bool ble_audio_end(const uint8_t *p,size_t n) { (void)p; (void)n; return true; }
void ble_audio_disconnect(void) {}
int opus_encoder_init(OpusEncoder *e,int rate,int channels,int app)
{ assert(e==&fake_encoder && rate==16000 && channels==1 && app==OPUS_APPLICATION_VOIP); return OPUS_OK; }
int opus_encoder_ctl(OpusEncoder *e,int setting) { (void)setting; assert(e==&fake_encoder); return OPUS_OK; }
int opus_encoder_get_size(int channels) { assert(channels==1); return sizeof(OpusEncoder); }
int opus_encode(OpusEncoder *e,const int16_t *pcm,int samples,uint8_t *packet,int max)
{
    assert(e==&fake_encoder && pcm && samples==320 && max==512 && !lock_depth);
    if(stop_in_encode) {
        local_active=false; remote_state.input.capture=VR_OFF; audio_sync();
    }
    memset(packet,0,3); return 3;
}
static void reset(void)
{
    fake_now=1000; event_count=0; local_stop_snapshot=false; live_at=0;
    stream=(vr_stream_t){0}; remote_state=(vr_state_t){0}; encoder=&fake_encoder; worker=fake_worker;
    generation=worker_generation=closing_at=0; encode_us=0; encoded=max_us=notify_failures=0;
    source_error=0; internal_before=external_before=0; closing=reported=local_running=false;
    local_active=in_worker=stop_in_encode=false;
    mic_starts=mic_stops=suspends=resumes=local_packets=sync_cancels=lock_depth=0;
}
static void reconnect_preserves_local_encoder(void)
{
    reset(); local_active=true; audio_poll(); assert(local_running && remote_state.input.offline && mic_starts==1);
    uint32_t before=generation; worker_generation=before;
    audio_reset(); audio_reset(); /* BLE CONNECT and DISCONNECT */
    assert(generation==before && worker_generation==before && local_running && !mic_stops && !suspends);
    audio_poll(); assert(mic_starts==1 && resumes==1 && !remote_state.input.streaming);
}
static void off_stops_local_immediately(void)
{
    reset(); local_active=true; audio_poll(); uint32_t before=generation;
    local_active=false; remote_state.input.capture=VR_OFF; audio_sync();
    assert(!local_running && !remote_state.input.offline && mic_stops==1 && suspends==1 && generation>before);
    audio_poll(); assert(mic_starts==1 && !local_packets);
}
static void off_discards_inflight_encoder(void)
{
    reset(); local_active=true; audio_poll(); stop_in_encode=true; in_worker=true;
    if(!setjmp(worker_exit)) encode_task(NULL);
    in_worker=false;
    assert(!local_running && !remote_state.input.offline && mic_stops==1 && !local_packets && !lock_depth);
}
static void stop_edge_precedes_snapshot(void)
{
    reset(); remote_state.input.capture=VR_REC; local_active=true; audio_poll(); event_count=0;
    /* Same synchronous order as remote_event: control, stop, edge, poll. */
    local_active=false; vr_control(&remote_state,VR_CAPTURE,VR_OFF,fake_now);
    audio_sync(); assert(!event_count && !remote_state.input.offline);
    ble_emit(VR_CAPTURE,fake_now); audio_poll();
    assert(event_count==2 && event_log[0]==VR_CAPTURE && event_log[1]==VR_SNAPSHOT);
    audio_poll(); assert(event_count==2);
}
static void recent_live_expiry(void)
{
    reset(); assert(!audio_recently_live());
    /* Track a valid live stream, then simulate transport failure. */
    assert(vr_stream_begin(&stream));
    remote_state.secure=remote_state.input_sub=remote_state.audio_sub=remote_state.info_read=true;
    remote_state.snapshot_sent=remote_state.has_phone=remote_state.armed=true;
    remote_state.input.capture=VR_REC; remote_state.phone.capture=VR_REC; remote_state.phone.recording=1;
    audio_poll(); assert(audio_recently_live());
    audio_fault(); assert(!remote_state.input.streaming && audio_recently_live());
    fake_now+=999; assert(audio_recently_live()); fake_now++; assert(!audio_recently_live());
    reset(); fake_now=UINT32_MAX-20; assert(vr_stream_begin(&stream));
    /* Set the live handshake again to exercise modulo elapsed-time expiry. */
    remote_state.secure=remote_state.input_sub=remote_state.audio_sub=remote_state.info_read=true;
    remote_state.snapshot_sent=remote_state.has_phone=remote_state.armed=true;
    remote_state.input.capture=VR_REC; remote_state.phone.capture=VR_REC; remote_state.phone.recording=1;
    audio_poll(); audio_fault(); fake_now+=999; assert(audio_recently_live());
    fake_now++; assert(!audio_recently_live());
}
static void live_reset_changes_generation(void)
{
    reset(); assert(vr_stream_begin(&stream)); remote_state.input.streaming=1;
    uint32_t before=generation; audio_reset();
    assert(generation>before && !stream.running && !stream.count && !remote_state.input.streaming && mic_stops==1 && suspends==1);
}
int main(void)
{
    reconnect_preserves_local_encoder(); off_stops_local_immediately();
    off_discards_inflight_encoder(); live_reset_changes_generation(); stop_edge_precedes_snapshot(); recent_live_expiry();
    puts("audio runtime: offline codec survives BLE resets, OFF stops/suspends and discards in-flight encoding, live reset passes");
}
