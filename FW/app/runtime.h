#pragma once
#include "state.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
extern vr_state_t remote_state;
extern SemaphoreHandle_t remote_mutex;
uint32_t remote_now(void);
/* All UI, state and board operations run under remote_mutex. */
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
