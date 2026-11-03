#pragma once
#include "FreeRTOS.h"
typedef void *SemaphoreHandle_t;
BaseType_t xSemaphoreTakeRecursive(SemaphoreHandle_t,TickType_t);
BaseType_t xSemaphoreGiveRecursive(SemaphoreHandle_t);
