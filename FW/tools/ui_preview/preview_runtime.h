#pragma once
/* Purpose: link the real UI to a deterministic native runtime, without ESP-IDF. */
#include "state.h"
#include "freertos/task.h"
extern TaskHandle_t remote_renderer;
extern vr_state_t remote_state;
uint32_t remote_now(void);
void remote_lock(void);
void remote_unlock(void);
bool preview_render_wait(uint32_t limit_ms);
void remote_event(uint8_t event,uint8_t value,uint32_t sampled);
void ble_pair_start(void);
void ble_pair_answer(bool accept);
void ble_revoke(void);
void ui_init(void);
bool ui_phone(const vr_phone_t *phone);
void ui_refresh(void);
void ui_pair_number(uint32_t number);
void ui_pair_hide(void);
void ui_link(const char *status);
void ui_tick(void);
void ui_poll(void);
