#include "board.h"
/* Build-only stub. Never advertises a functional display, buttons or Opus. */
static const board_info_t info={2,240,280,0,false,false,false};
const board_info_t *board_info(void) { return &info; }
esp_err_t board_init(void) { return ESP_OK; }
esp_err_t board_flush(int x1,int y1,int x2,int y2,const void *p)
{ (void)x1; (void)y1; (void)x2; (void)y2; (void)p; return ESP_ERR_NOT_SUPPORTED; }
board_touch_t board_touch(uint16_t *x,uint16_t *y) { (void)x; (void)y; return BOARD_TOUCH_UP; }
bool board_button(unsigned button) { (void)button; return false; }
void board_haptic(uint32_t now) { (void)now; }
void board_poll(uint32_t now) { (void)now; }

#include "esp_heap_caps.h"
esp_err_t board_mic_start(void) { return ESP_ERR_NOT_SUPPORTED; }
void board_mic_stop(void) {}
esp_err_t board_mic_read(int16_t pcm[320]) { (void)pcm; return ESP_ERR_NOT_SUPPORTED; }
void *board_audio_alloc(size_t bytes) { return heap_caps_malloc(bytes,MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT); }
