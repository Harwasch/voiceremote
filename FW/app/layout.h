#pragma once
#include <stdbool.h>
#include <stdint.h>
typedef struct { int x,y,width,height,row; } vr_layout_t;
static inline vr_layout_t vr_layout(uint16_t width,uint16_t height,bool round)
{
    int w=round?width*68/100:width-16;
    int h=round?height*68/100:height-16;
    return (vr_layout_t){(width-w)/2,(height-h)/2,w,h,h/9};
}
