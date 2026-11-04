#pragma once
/* Purpose: synthetic persistent storage hold for failed-store re-enrollment.
 * Inputs: NVS u32 API; host harness verifies hold across simulated reboot. */
#include <stdint.h>
#include "esp_err.h"
#define NVS_READWRITE 1
#define NVS_READONLY 0
#define ESP_ERR_NVS_NOT_FOUND -3
typedef unsigned nvs_handle_t;
esp_err_t nvs_open(const char *,int,nvs_handle_t *);
esp_err_t nvs_get_u32(nvs_handle_t,const char *,uint32_t *);
esp_err_t nvs_set_u32(nvs_handle_t,const char *,uint32_t);
esp_err_t nvs_commit(nvs_handle_t);
void nvs_close(nvs_handle_t);
