#pragma once
#include <stdbool.h>
#include <stdint.h>
/* Subtraction avoids overflow for malformed offsets/sizes. */
static inline bool c6_storage_fits(uint32_t physical,uint32_t offset,uint32_t size)
{ return size && offset<=physical && size<=physical-offset; }
