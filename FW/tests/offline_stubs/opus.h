#pragma once
#include <stdint.h>
typedef struct { int unused; } OpusEncoder;
#define OPUS_OK 0
#define OPUS_APPLICATION_VOIP 1
#define OPUS_BANDWIDTH_WIDEBAND 1
#define OPUS_SET_BITRATE(n) (n)
#define OPUS_SET_COMPLEXITY(n) (n)
#define OPUS_SET_VBR(n) (n)
#define OPUS_SET_DTX(n) (n)
#define OPUS_SET_INBAND_FEC(n) (n)
#define OPUS_SET_MAX_BANDWIDTH(n) (n)
int opus_encoder_init(OpusEncoder *,int,int,int);
int opus_encoder_ctl(OpusEncoder *,int);
int opus_encoder_get_size(int);
int opus_encode(OpusEncoder *,const int16_t *,int,uint8_t *,int);
