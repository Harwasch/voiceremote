#pragma once
#include <stdbool.h>
#include <stdint.h>
#ifndef VR_TIMING
#define VR_TIMING 0
#endif
#if VR_TIMING
uint64_t timing_now_us(void);
void timing_loop(uint64_t start);
void timing_touch_poll(uint64_t start);
void timing_flush(uint64_t start);
void timing_redraw(uint64_t start,bool flushed,bool ok,uint32_t touch_id,uint32_t touch_at);
void timing_queue(unsigned count);
void timing_encode(unsigned us);
void timing_barrier(uint32_t started,bool ok);
void timing_report(void); /* renderer only, outside remote_mutex; every 5 s */
#else
static inline uint64_t timing_now_us(void) { return 0; }
static inline void timing_loop(uint64_t start) { (void)start; }
static inline void timing_touch_poll(uint64_t start) { (void)start; }
static inline void timing_flush(uint64_t start) { (void)start; }
static inline void timing_redraw(uint64_t start,bool flushed,bool ok,uint32_t id,uint32_t at)
{ (void)start; (void)flushed; (void)ok; (void)id; (void)at; }
static inline void timing_queue(unsigned count) { (void)count; }
static inline void timing_encode(unsigned us) { (void)us; }
static inline void timing_barrier(uint32_t started,bool ok) { (void)started; (void)ok; }
static inline void timing_report(void) {}
#endif
