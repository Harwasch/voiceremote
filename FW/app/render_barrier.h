#pragma once
/* Priority guard shared by production ui_phone and native barrier checks.
 * Inputs: renderer task and board scheduling policy. Hardware timing unverified. */
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "scheduling.h"
enum { PHONE_RENDER_WAIT_MS=400 };
static inline UBaseType_t vr_render_boost(TaskHandle_t renderer)
{
    UBaseType_t saved=uxTaskPriorityGet(renderer);
    if(saved<VR_RENDER_BARRIER_PRIORITY) vTaskPrioritySet(renderer,VR_RENDER_BARRIER_PRIORITY);
    return saved;
}
static inline void vr_render_restore(TaskHandle_t renderer,UBaseType_t saved)
{ vTaskPrioritySet(renderer,saved); }
