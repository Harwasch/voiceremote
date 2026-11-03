#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

typedef struct {
    uint16_t id, width, height, capabilities;
    bool round, operational;
} board_info_t;
const board_info_t *board_info(void);
esp_err_t board_init(void);
/* Inclusive coordinates; RGB565 in panel byte order. Synchronous DMA completion. */
esp_err_t board_flush(int x1, int y1, int x2, int y2, const void *pixels);
bool board_touch(uint16_t *x, uint16_t *y);
/* Physical levels only; shared app debounces. */
bool board_button(unsigned button);
void board_haptic(uint32_t now_ms);
void board_poll(uint32_t now_ms);
