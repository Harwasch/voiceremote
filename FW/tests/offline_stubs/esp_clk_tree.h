#pragma once
#include <stdint.h>
#include "esp_err.h"
#define SOC_MOD_CLK_CPU 1
#define ESP_CLK_TREE_SRC_FREQ_PRECISION_CACHED 1
esp_err_t esp_clk_tree_src_get_freq_hz(int,int,uint32_t *);
