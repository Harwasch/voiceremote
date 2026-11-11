/* Purpose: compile the production priority guard with each board policy.
 * Inputs: synthetic FreeRTOS priority API. Verified by host, not RTOS timing. */
#include <assert.h>
#include "render_barrier.h"
static unsigned priority, sets;
static int renderer;
UBaseType_t uxTaskPriorityGet(TaskHandle_t task)
{ assert(task==&renderer); return priority; }
void vTaskPrioritySet(TaskHandle_t task,UBaseType_t value)
{ assert(task==&renderer); priority=value; sets++; }
int main(void)
{
#if defined(CONFIG_FREERTOS_UNICORE) && CONFIG_FREERTOS_UNICORE
    assert(VR_RENDER_BARRIER_PRIORITY==20 && VR_AUDIO_PRIORITY==22);
#else
    assert(VR_RENDER_BARRIER_PRIORITY==3 && VR_AUDIO_PRIORITY==4);
#endif
    assert(VR_RENDER_BARRIER_PRIORITY<VR_AUDIO_PRIORITY);
    priority=1;
    unsigned saved=vr_render_boost(&renderer);
    assert(saved==1 && priority==VR_RENDER_BARRIER_PRIORITY && sets==1);
    vr_render_restore(&renderer,saved); assert(priority==1 && sets==2);
    priority=VR_AUDIO_PRIORITY; /* Never lower an already higher priority. */
    saved=vr_render_boost(&renderer); assert(priority==VR_AUDIO_PRIORITY && sets==2);
    vr_render_restore(&renderer,saved); assert(priority==VR_AUDIO_PRIORITY);
}
