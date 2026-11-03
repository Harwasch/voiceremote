#include "timing.h"
#if VR_TIMING
#ifdef UI_PREVIEW
#include <stdio.h>
#include <time.h>
/* Native timing uses the production aggregates; synthetic UI ticks cannot
 * measure physical input latency or barrier wall time. */
static uint64_t esp_timer_get_time(void)
{
    struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);
    return (uint64_t)t.tv_sec*1000000+t.tv_nsec/1000;
}
#define portMUX_TYPE int
#define portMUX_INITIALIZER_UNLOCKED 0
#define portENTER_CRITICAL(p) ((void)(p))
#define portEXIT_CRITICAL(p) ((void)(p))
#define ESP_LOGI(tag,...) do { printf("%s host: ",tag); printf(__VA_ARGS__); puts(""); } while(0)
#else
#include "esp_timer.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#endif
#include <string.h>

typedef struct { uint64_t sum; uint32_t count, max; } metric_t;
static struct {
    metric_t redraw, touch, loop, period, poll, dma, barrier;
    unsigned queue_high, flush_errors, barrier_rejects;
} stats;
static portMUX_TYPE stats_lock=portMUX_INITIALIZER_UNLOCKED;
static uint64_t previous_loop, report_at;
static uint32_t reported_touch;
uint64_t timing_now_us(void) { return esp_timer_get_time(); }
static void sample(metric_t *m,uint64_t us)
{
    m->sum+=us; m->count++;
    if(us>m->max) m->max=us>UINT32_MAX?UINT32_MAX:(uint32_t)us;
}
void timing_loop(uint64_t start)
{
    uint64_t elapsed=timing_now_us()-start;
    portENTER_CRITICAL(&stats_lock);
    sample(&stats.loop,elapsed);
    if(previous_loop) sample(&stats.period,start-previous_loop);
    previous_loop=start;
    portEXIT_CRITICAL(&stats_lock);
}
void timing_touch_poll(uint64_t start)
{
    uint64_t elapsed=timing_now_us()-start;
    portENTER_CRITICAL(&stats_lock); sample(&stats.poll,elapsed); portEXIT_CRITICAL(&stats_lock);
}
void timing_flush(uint64_t start)
{
    uint64_t elapsed=timing_now_us()-start;
    portENTER_CRITICAL(&stats_lock); sample(&stats.dma,elapsed); portEXIT_CRITICAL(&stats_lock);
}
void timing_redraw(uint64_t start,bool flushed,bool ok,uint32_t id,uint32_t at)
{
    if(!flushed) return;
    uint64_t end=timing_now_us();
    portENTER_CRITICAL(&stats_lock);
    sample(&stats.redraw,end-start);
    if(!ok) stats.flush_errors++;
    /* Sample time is millisecond resolution. End is last synchronous DMA, not
     * panel scanout; render preemption/queueing is deliberately included. */
    if(ok && id && id!=reported_touch) {
        reported_touch=id;
        #ifdef UI_PREVIEW
        (void)at; /* synthetic ticks, no host press-to-pixel claim */
#else
        sample(&stats.touch,(uint64_t)((uint32_t)(end/1000)-at)*1000);
#endif
    }
    portEXIT_CRITICAL(&stats_lock);
}
void timing_queue(unsigned count)
{
    portENTER_CRITICAL(&stats_lock);
    if(count>stats.queue_high) stats.queue_high=count;
    portEXIT_CRITICAL(&stats_lock);
}
void timing_barrier(uint32_t started,bool ok)
{
    #ifdef UI_PREVIEW
    uint32_t elapsed=0; (void)started;
#else
    uint32_t elapsed=(uint32_t)(timing_now_us()/1000)-started;
#endif
    portENTER_CRITICAL(&stats_lock);
    sample(&stats.barrier,(uint64_t)elapsed*1000);
    if(!ok) stats.barrier_rejects++;
    portEXIT_CRITICAL(&stats_lock);
}
static unsigned long mean(metric_t m) { return m.count?(unsigned long)(m.sum/m.count):0; }
void timing_report(void)
{
    uint64_t now=timing_now_us();
#ifndef UI_PREVIEW
    if(now-report_at<5000000) return;
#endif
    report_at=now; (void)report_at;
    portENTER_CRITICAL(&stats_lock);
    __typeof__(stats) s=stats; memset(&stats,0,sizeof stats);
    portEXIT_CRITICAL(&stats_lock);
    ESP_LOGI("timing","us mean/max redraw=%lu/%lu n=%lu touch_to_dma_est=%lu/%lu n=%lu loop=%lu/%lu period=%lu/%lu touch_poll=%lu/%lu dma_strip=%lu/%lu n=%lu queue_high=%u/4 flush_errors=%u barrier=%lu/%lu rejects=%u",
        mean(s.redraw),(unsigned long)s.redraw.max,(unsigned long)s.redraw.count,
        mean(s.touch),(unsigned long)s.touch.max,(unsigned long)s.touch.count,
        mean(s.loop),(unsigned long)s.loop.max,mean(s.period),(unsigned long)s.period.max,
        mean(s.poll),(unsigned long)s.poll.max,mean(s.dma),(unsigned long)s.dma.max,(unsigned long)s.dma.count,
        s.queue_high,s.flush_errors,mean(s.barrier),(unsigned long)s.barrier.max,s.barrier_rejects);
}
#endif
