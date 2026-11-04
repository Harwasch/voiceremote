#ifndef LV_CONF_H
#define LV_CONF_H
/* Purpose: deterministic native software rendering. Inputs: LVGL 9.5.0, RGB565 UI.
 * Verified by the PNG renderer; no window system, network, GPU or board access. */
#define LV_COLOR_DEPTH 16
#define LV_USE_OS LV_OS_NONE
#define LV_USE_STDLIB_MALLOC LV_STDLIB_CLIB
#define LV_USE_STDLIB_STRING LV_STDLIB_CLIB
#define LV_USE_STDLIB_SPRINTF LV_STDLIB_CLIB
#define LV_USE_DRAW_SW 1
#define LV_DRAW_SW_SUPPORT_RGB565 1
#define LV_DRAW_SW_COMPLEX 1
#define LV_USE_LODEPNG 1
#define LV_BUILD_EXAMPLES 0
#define LV_BUILD_DEMOS 0
#endif
