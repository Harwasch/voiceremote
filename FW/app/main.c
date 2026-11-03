#include "runtime.h"
#include "offline.h"
#include "board.h"
#include "timing.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "nvs_flash.h"
#include "freertos/task.h"
vr_state_t remote_state;
SemaphoreHandle_t remote_mutex;
uint32_t remote_now(void) { return (uint32_t)(esp_timer_get_time()/1000); }
void remote_event(uint8_t event, uint8_t value, uint32_t sampled)
{
    offline_control(event,value);
    vr_control(&remote_state,event,value,sampled);
    audio_sync();
    ble_emit(event,sampled);
    ui_refresh();
}
void remote_lock(void) { xSemaphoreTakeRecursive(remote_mutex,portMAX_DELAY); }
void remote_unlock(void) { xSemaphoreGiveRecursive(remote_mutex); }
static void render_task(void *arg)
{
    (void)arg;
    for(;;) {
        ui_tick(); timing_report();
        vTaskDelay(pdMS_TO_TICKS(5));
    }
}
void app_main(void)
{
    /* Fail visibly rather than silently erasing bonds on NVS corruption. */
    ESP_ERROR_CHECK(nvs_flash_init());
    remote_mutex=xSemaphoreCreateRecursiveMutex(); configASSERT(remote_mutex);
    ESP_ERROR_CHECK(board_init());
    ui_init();
    offline_init();
    audio_init();
    ble_start();
    /* Preemption also protects audio on single-core C6: input/transport > Opus >
     * LVGL. No core affinity and no renderer/state lock around software drawing. */
    vTaskPrioritySet(NULL,5);
    if(board_info()->operational)
        ESP_ERROR_CHECK(xTaskCreate(render_task,"render",8192,NULL,1,NULL)==pdPASS?ESP_OK:ESP_ERR_NO_MEM);
    for(;;) {
        uint64_t loop_start=timing_now_us();
        remote_lock();
        uint32_t now=remote_now();
        board_poll(now); ble_poll(now);
        for(unsigned b=0;b<2;b++) {
            uint32_t sampled;
            if(vr_debounce(&remote_state.buttons[b],board_button(b),now,&sampled)) {
                bool down=remote_state.buttons[b].stable;
                ESP_LOGI("input","button %u %s (GPIO mapping in board driver)",b,down?"down":"up");
                if(down) board_haptic(now);
                if(!b) remote_event(down?VR_DOWN:VR_UP,down,sampled);
                else if(down) remote_event(VR_CYCLE,0,sampled);
            }
        }
        ui_poll();
        offline_poll();
        audio_poll();
        remote_unlock();
        timing_loop(loop_start);
        vTaskDelay(pdMS_TO_TICKS(5));
    }
}
