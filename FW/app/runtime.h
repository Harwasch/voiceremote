#pragma once
#include "state.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
extern vr_state_t remote_state;
extern SemaphoreHandle_t remote_mutex;
uint32_t remote_now(void);
/* State, UI mailbox and board I2C/mic operations use remote_mutex. LVGL and
 * panel SPI belong to the renderer and never hold it. ui_phone is the sole
 * exception: entered at depth one, it releases/reacquires the lock while waiting. */
void remote_lock(void);
void remote_unlock(void);
void remote_event(uint8_t event, uint8_t value, uint32_t sampled);
void ble_start(void);
void ble_emit(uint8_t event, uint32_t sampled);
void ble_pair_start(void);
void ble_pair_answer(bool accept);
void ble_revoke(void);
void ble_poll(uint32_t now);
void ui_init(void);
bool ui_phone(const vr_phone_t *phone);
void ui_refresh(void);
void ui_pair_number(uint32_t number);
void ui_pair_hide(void);
void ui_link(const char *text);
void ui_tick(void);
void ui_poll(void);

void audio_init(void);
void audio_sync(void);
bool audio_recently_live(void);
void audio_poll(void);
void audio_reset(void);
void audio_fault(void);
bool ble_audio_ready(void);
bool ble_audio_send(const uint8_t *value, size_t size);
uint16_t ble_audio_mtu(void);
void ble_audio_disconnect(void);
bool audio_input_allowed(void);
void audio_notify_failed(void);
bool ble_audio_end(const uint8_t *value, size_t size);
