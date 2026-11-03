#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"

typedef struct {
    uint16_t id, width, height, capabilities;
    bool round, operational;
    bool virtual_sliders; /* false: board owns physical capture/mode sliders */
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

/* Mic calls serialized by remote_mutex. Reads never wait for samples; OFF disables
 * DMA immediately. No storage/logging. Allocation policy belongs to each board. */
esp_err_t board_mic_start(void);
void board_mic_stop(void);
esp_err_t board_mic_read(int16_t pcm[320]); /* ESP_ERR_NOT_FINISHED if incomplete */
void *board_audio_alloc(size_t bytes);
