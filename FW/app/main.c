#include "runtime.h"
#include "board.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "nvs_flash.h"
#include "freertos/task.h"
vr_state_t remote_state;
SemaphoreHandle_t remote_mutex;
uint32_t remote_now(void) { return (uint32_t)(esp_timer_get_time()/1000); }
void remote_event(uint8_t event, uint8_t value, uint32_t sampled)
{
    vr_control(&remote_state,event,value,sampled);
    ble_emit(event,sampled);
    ui_refresh();
}
void app_main(void)
{
    /* Fail visibly rather than silently erasing bonds on NVS corruption. */
    ESP_ERROR_CHECK(nvs_flash_init());
    remote_mutex=xSemaphoreCreateRecursiveMutex(); configASSERT(remote_mutex);
    ESP_ERROR_CHECK(board_init());
    ui_init();
    ble_start();
    for(;;) {
        xSemaphoreTakeRecursive(remote_mutex,portMAX_DELAY);
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
        ui_tick();
        xSemaphoreGiveRecursive(remote_mutex);
        vTaskDelay(pdMS_TO_TICKS(5));
    }
}
