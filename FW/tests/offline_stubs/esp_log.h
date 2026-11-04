#pragma once
/* Evaluate synthetic log arguments so production warning checks remain useful. */
static inline void test_esp_log(const char *tag,const char *format,...)
{ (void)tag; (void)format; }
#define ESP_LOGI(...) test_esp_log(__VA_ARGS__)
#define ESP_LOGE(...) test_esp_log(__VA_ARGS__)

#define ESP_LOGW(...) test_esp_log(__VA_ARGS__)
