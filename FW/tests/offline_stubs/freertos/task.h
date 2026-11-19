#pragma once
#include "FreeRTOS.h"
typedef void (*TaskFunction_t)(void *);
typedef void *TaskHandle_t;
BaseType_t xTaskCreate(TaskFunction_t,const char *,uint32_t,void *,UBaseType_t,TaskHandle_t *);
TaskHandle_t xTaskGetCurrentTaskHandle(void);
void vTaskSuspend(TaskHandle_t);
void vTaskResume(TaskHandle_t);
void vTaskDelay(TickType_t);
UBaseType_t uxTaskGetStackHighWaterMark(TaskHandle_t);

UBaseType_t uxTaskPriorityGet(TaskHandle_t);
void vTaskPrioritySet(TaskHandle_t,UBaseType_t);
