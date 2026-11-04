#pragma once
#include "esp_err.h"
#include <stddef.h>
#include <stdint.h>
#define ESP_PARTITION_TYPE_DATA 1
typedef struct { uint32_t size; } esp_partition_t;
const esp_partition_t *esp_partition_find_first(int type,int subtype,const char *label);
esp_err_t esp_partition_read(const esp_partition_t *,uint32_t,void *,size_t);
esp_err_t esp_partition_write(const esp_partition_t *,uint32_t,const void *,size_t);
esp_err_t esp_partition_erase_range(const esp_partition_t *,uint32_t,size_t);
