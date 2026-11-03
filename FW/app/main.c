#include "runtime.h"
#include "offline.h"
#include "board.h"
#include "timing.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "nvs_flash.h"
#include "freertos/task.h"
#ifdef REMOTE_TEST_HOOK
#include "test_hook.h"
#include "driver/usb_serial_jtag.h"
#include "esp_system.h"
static vr_test_input_t test_input;
void ui_test_control(unsigned actions,uint8_t capture);
static void test_poll(void)
{
    char command;
    if(usb_serial_jtag_read_bytes(&command,1,0)!=1) return;
    unsigned effect=vr_test_command(&test_input,command);
    ESP_LOGW("test_hook","TEST BUILD command=%c",command);
    if(effect&(VR_TEST_SELECT|VR_TEST_MODE)) ui_test_control(effect,test_input.capture);
    if(effect&VR_TEST_HAPTIC) board_haptic(remote_now());
    if(effect&VR_TEST_REBOOT) esp_restart();
}
#endif
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
#ifdef REMOTE_TEST_HOOK
    ESP_LOGW("test_hook","TEST BUILD: USB local-input hook ENABLED (o/p/r d/u h t x)");
    usb_serial_jtag_driver_config_t hook_config=USB_SERIAL_JTAG_DRIVER_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(usb_serial_jtag_driver_install(&hook_config));
#endif
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
#ifdef REMOTE_TEST_HOOK
        test_poll();
#endif
        for(unsigned b=0;b<2;b++) {
            uint32_t sampled;
            if(vr_debounce(&remote_state.buttons[b],(board_button(b)
#ifdef REMOTE_TEST_HOOK
                || (!b && test_input.ptt)
#endif
                ),now,&sampled)) {
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
