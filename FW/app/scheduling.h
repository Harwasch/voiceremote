#pragma once
/* Generic single-core policy. Dual-core reference behavior is unchanged.
 * Include after FreeRTOS (sdkconfig); host tests use the reference policy. */
#if defined(CONFIG_FREERTOS_UNICORE) && CONFIG_FREERTOS_UNICORE
#define VR_RENDER_BARRIER_PRIORITY 20 /* below Opus 22 and NimBLE 21 */
#define VR_AUDIO_PRIORITY 22 /* above default NimBLE host 21; radio controller 23 */
#define VR_AUDIO_STACK (32u*1024u)
#define VR_WRITER_PRIORITY 1
#else
#define VR_RENDER_BARRIER_PRIORITY 3 /* below Opus 4 */
#define VR_AUDIO_PRIORITY 4
#define VR_AUDIO_STACK (48u*1024u)
#define VR_WRITER_PRIORITY 2
#endif
