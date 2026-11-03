/*
 * SPDX-FileCopyrightText: 2025 M5Stack Technology CO LTD
 * SPDX-FileCopyrightText: 2026 M5Stack Technology CO LTD
 * SPDX-License-Identifier: MIT
 * Board sequences adapted from M5StopWatch-UserDemo hal_display/hal_ioe and
 * M5StopWatch-PowerDemo m5sw_display. Register definitions from M5IOE1/M5PM1.
 * See DOCS/licences/ and this board's README for sources and obligations.
 */
#include "board.h"
#include "driver/gpio.h"
#include "driver/i2c_master.h"
#include "driver/spi_master.h"
#include "esp_lcd_co5300.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_panel_io.h"
#include "esp_log.h"
#include "esp_attr.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

/* Swap only this constant if the physical colours are reversed. */
static const gpio_num_t BUTTON_GPIOS[2]={GPIO_NUM_2,GPIO_NUM_1}; /* yellow PTT, blue cycle */
static const board_info_t info={1,466,466,0xbf,true,true,true};
static i2c_master_dev_handle_t ioe, pm, touch, codec;
static i2c_master_bus_handle_t bus;
static esp_lcd_panel_handle_t panel;
static SemaphoreHandle_t dma_done;
static uint32_t motor_started;
static bool motor_on;
const board_info_t *board_info(void) { return &info; }
static esp_err_t read_reg(i2c_master_dev_handle_t d, uint8_t reg, uint8_t *p, size_t n)
{ return i2c_master_transmit_receive(d,&reg,1,p,n,50); }
static esp_err_t write_reg(i2c_master_dev_handle_t d, uint8_t reg, uint8_t v)
{ uint8_t b[]={reg,v}; return i2c_master_transmit(d,b,2,50); }
static esp_err_t update_once(i2c_master_dev_handle_t d, uint8_t reg, uint8_t mask, uint8_t value)
{
    uint8_t old, check;
    esp_err_t e=read_reg(d,reg,&old,1); if(e) return e;
    e=write_reg(d,reg,(old&~mask)|(value&mask)); if(e) return e;
    e=read_reg(d,reg,&check,1); if(e) return e;
    return (check&mask)==(value&mask) ? ESP_OK : ESP_ERR_INVALID_RESPONSE;
}
/* Touch controller resets can disturb the shared I2C bus, seen as intermittent boot failures. */
static esp_err_t update(i2c_master_dev_handle_t d, uint8_t reg, uint8_t mask, uint8_t value)
{
    esp_err_t e=ESP_FAIL;
    for(int attempt=0;attempt<5;attempt++) {
        e=update_once(d,reg,mask,value); if(!e) return ESP_OK;
        i2c_master_bus_reset(bus); vTaskDelay(pdMS_TO_TICKS(10));
    }
    return e;
}
/* IOE pin numbers are one-based here; vendor register bits are zero-based. */
static esp_err_t ioe_output(unsigned pin, bool high)
{
    uint8_t bit=1u<<((pin-1)%8), bank=(pin-1)/8;
    esp_err_t e=update(ioe,0x05+bank,bit,high?bit:0); if(e) return e;
    e=update(ioe,0x09+bank,bit,0); if(e) return e; /* no pull-up */
    e=update(ioe,0x0b+bank,bit,0); if(e) return e; /* no pull-down */
    e=update(ioe,0x13+bank,bit,0); if(e) return e; /* push-pull */
    return update(ioe,0x03+bank,bit,bit);
}
static bool transfer_done(esp_lcd_panel_io_handle_t io, esp_lcd_panel_io_event_data_t *e, void *ctx)
{
    (void)io; (void)e; BaseType_t wake=pdFALSE;
    xSemaphoreGiveFromISR((SemaphoreHandle_t)ctx,&wake); return wake==pdTRUE;
}
static const co5300_lcd_init_cmd_t init_commands[]={
    {0x11,NULL,0,150}, {0xc4,(uint8_t[]){0x80},1,0},
    {0x35,(uint8_t[]){0x80},1,0}, {0x44,(uint8_t[]){0x01,0xd2},2,0},
    {0x53,(uint8_t[]){0x20},1,0}, {0x20,NULL,0,0},
    {0x36,(uint8_t[]){0},1,0}, {0x51,(uint8_t[]){0xa0},1,0}, {0x29,NULL,0,0},
};
esp_err_t board_init(void)
{
    i2c_master_bus_config_t bc={.i2c_port=I2C_NUM_0,.sda_io_num=47,.scl_io_num=48,
        .clk_source=I2C_CLK_SRC_DEFAULT,.glitch_ignore_cnt=7,.flags.enable_internal_pullup=true};
    ESP_ERROR_CHECK(i2c_new_master_bus(&bc,&bus));
    i2c_device_config_t dc={.dev_addr_length=I2C_ADDR_BIT_LEN_7,.device_address=0x4f,.scl_speed_hz=100000};
    ESP_ERROR_CHECK(i2c_master_bus_add_device(bus,&dc,&ioe));
    dc.device_address=0x6e; ESP_ERROR_CHECK(i2c_master_bus_add_device(bus,&dc,&pm));
    dc.device_address=0x15; ESP_ERROR_CHECK(i2c_master_bus_add_device(bus,&dc,&touch));
    dc.device_address=0x18; ESP_ERROR_CHECK(i2c_master_bus_add_device(bus,&dc,&codec));
    /* Keep awake at 100 kHz. Preserve all unrelated PM and IOE state, including AU_EN. */
    ESP_ERROR_CHECK(update(pm,0x09,0x1f,0));
    ESP_ERROR_CHECK(update(pm,0x06,0x16,0x06)); /* DCDC/LDO on, redundant LED off */
    ESP_ERROR_CHECK(update(ioe,0x23,0x7f,0x20));
    ESP_ERROR_CHECK(write_reg(ioe,0x1c,0)); /* motor PWM disabled */
    ESP_ERROR_CHECK(write_reg(ioe,0x1e,0)); /* rail-enable pin must not retain PWM */
    ESP_ERROR_CHECK(ioe_output(9,false));
    /* Hold the speaker amp off on both vendor enable lines; undriven, it can whine. */
    ESP_ERROR_CHECK(ioe_output(10,false));
    gpio_config_t amp={.pin_bit_mask=1ULL<<14,.mode=GPIO_MODE_OUTPUT};
    ESP_ERROR_CHECK(gpio_config(&amp)); ESP_ERROR_CHECK(gpio_set_level(14,0));
    ESP_ERROR_CHECK(write_reg(ioe,0x25,0x88)); /* PWM 5000 Hz */
    ESP_ERROR_CHECK(write_reg(ioe,0x26,0x13));
    gpio_config_t cs={.pin_bit_mask=1ULL<<39,.mode=GPIO_MODE_OUTPUT};
    ESP_ERROR_CHECK(gpio_config(&cs)); ESP_ERROR_CHECK(gpio_set_level(39,1));
    ESP_ERROR_CHECK(ioe_output(5,true)); ESP_ERROR_CHECK(ioe_output(8,true));
    vTaskDelay(pdMS_TO_TICKS(10)); ESP_ERROR_CHECK(ioe_output(5,false));
    vTaskDelay(pdMS_TO_TICKS(8)); ESP_ERROR_CHECK(ioe_output(5,true)); vTaskDelay(pdMS_TO_TICKS(2));
    ESP_ERROR_CHECK(ioe_output(4,false)); vTaskDelay(pdMS_TO_TICKS(10));
    ESP_ERROR_CHECK(ioe_output(4,true)); vTaskDelay(pdMS_TO_TICKS(50));
    uint8_t id;
    ESP_ERROR_CHECK(read_reg(touch,0xa7,&id,1));
    if(!id) return ESP_ERR_INVALID_RESPONSE;
    ESP_ERROR_CHECK(ioe_output(3,true));
    gpio_config_t inputs={.pin_bit_mask=(1ULL<<BUTTON_GPIOS[0])|(1ULL<<BUTTON_GPIOS[1])|(1ULL<<13)|(1ULL<<38),
        .mode=GPIO_MODE_INPUT,.pull_up_en=GPIO_PULLUP_ENABLE};
    ESP_ERROR_CHECK(gpio_config(&inputs));
    dma_done=xSemaphoreCreateBinary(); if(!dma_done) return ESP_ERR_NO_MEM;
    spi_bus_config_t sc=CO5300_PANEL_BUS_QSPI_CONFIG(40,41,42,46,45,466*32*2);
    ESP_ERROR_CHECK(spi_bus_initialize(SPI2_HOST,&sc,SPI_DMA_CH_AUTO));
    esp_lcd_panel_io_spi_config_t ic=CO5300_PANEL_IO_QSPI_CONFIG(39,transfer_done,dma_done);
    /* Same panel/pins as vendor UserDemo main/hal/hal_display.cpp:83. */
    ic.pclk_hz=80000000;
    esp_lcd_panel_io_handle_t io;
    ESP_ERROR_CHECK(esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)SPI2_HOST,&ic,&io));
    co5300_vendor_config_t vc={.init_cmds=init_commands,.init_cmds_size=sizeof init_commands/sizeof init_commands[0],
        .flags.use_qspi_interface=1};
    esp_lcd_panel_dev_config_t pc={.reset_gpio_num=-1,.rgb_ele_order=LCD_RGB_ELEMENT_ORDER_RGB,
        .bits_per_pixel=16,.vendor_config=&vc};
    ESP_ERROR_CHECK(esp_lcd_new_panel_co5300(io,&pc,&panel));
    ESP_ERROR_CHECK(esp_lcd_panel_init(panel));
    /* Vendor exposes 468 columns starting at 6; restrict logical width to specified 466. */
    ESP_ERROR_CHECK(esp_lcd_panel_set_gap(panel,6,0));
    ESP_ERROR_CHECK(esp_lcd_panel_co5300_set_brightness(panel,50));
    ESP_LOGI("board","StopWatch ready; PTT GPIO %d, cycle GPIO %d",BUTTON_GPIOS[0],BUTTON_GPIOS[1]);
    return ESP_OK;
}
esp_err_t board_flush(int x1, int y1, int x2, int y2, const void *p)
{
    esp_err_t e=esp_lcd_panel_draw_bitmap(panel,x1,y1,x2+1,y2+1,p);
    if(e) return e;
    return xSemaphoreTake(dma_done,pdMS_TO_TICKS(1000))==pdTRUE ? ESP_OK : ESP_ERR_TIMEOUT;
}
board_touch_t board_touch(uint16_t *x, uint16_t *y)
{
    uint8_t b[7];
    if(read_reg(touch,0,b,sizeof b)!=ESP_OK) return BOARD_TOUCH_ERROR;
    if(b[2]!=1 || ((b[3]>>6)!=0 && (b[3]>>6)!=2)) return BOARD_TOUCH_UP;
    *x=((b[3]&15)<<8)|b[4]; *y=((b[5]&15)<<8)|b[6];
    return *x<info.width && *y<info.height ? BOARD_TOUCH_DOWN : BOARD_TOUCH_UP;
}
bool board_button(unsigned button)
{
    static bool previous[2];
    if(button>=2) return false;
    bool down=!gpio_get_level(BUTTON_GPIOS[button]);
    if(down!=previous[button]) {
        ESP_LOGI("board","GPIO %d %s",BUTTON_GPIOS[button],down?"down":"up");
        previous[button]=down;
    }
    return down;
}
void board_haptic(uint32_t now)
{
    /* 20% PWM for 25 ms; subjective strength remains unverified. */
    if(write_reg(ioe,0x1b,0x33)!=ESP_OK) ESP_LOGE("board","haptic PWM write failed");
    if(write_reg(ioe,0x1c,0x83)!=ESP_OK) ESP_LOGE("board","haptic start write failed");
    motor_started=now; motor_on=true;
}
void board_poll(uint32_t now)
{
    if(motor_on && (uint32_t)(now-motor_started)>=25) {
        if(write_reg(ioe,0x1c,0)!=ESP_OK) { ESP_LOGE("board","haptic stop write failed"); motor_started=now; return; }
        motor_on=false;
    }
}

/* ES8311 register sequence adapted from Espressif esp_codec_dev es8311.c
 * SPDX-FileCopyrightText: 2023 Espressif Systems (Shanghai) CO LTD
 * SPDX-License-Identifier: Apache-2.0
 * Same slave/analog-mic/MCLK/Philips/16-bit setup as vendor hal_audio; 16 kHz
 * replaces its 44.1 kHz. 4.096 MHz MCLK uses the driver's 16 kHz/256 coefficient.
 * ADC left is mic; right is DAC reference (0x44=0x58), deliberately ignored.
 */
#include "driver/i2s_std.h"
#include "esp_heap_caps.h"
#include <stdatomic.h>
#include <string.h>
static i2s_chan_handle_t mic_rx;
static bool mic_enabled;
static atomic_bool mic_overflow;
static int16_t mic_stereo[640];
static size_t mic_used;
static bool IRAM_ATTR mic_q_overflow(i2s_chan_handle_t h,i2s_event_data_t *e,void *ctx)
{ (void)h; (void)e; (void)ctx; atomic_store(&mic_overflow,true); return false; }
static esp_err_t mic_init(void)
{
    i2s_chan_config_t channel=I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_0,I2S_ROLE_MASTER);
    channel.dma_desc_num=4; channel.dma_frame_num=320;
    esp_err_t err=i2s_new_channel(&channel,NULL,&mic_rx); if(err) return err;
    i2s_std_config_t cfg={
        .clk_cfg=I2S_STD_CLK_DEFAULT_CONFIG(16000),
        .slot_cfg=I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT,I2S_SLOT_MODE_STEREO),
        .gpio_cfg={.mclk=18,.bclk=17,.ws=15,.dout=21,.din=16},
    };
    err=i2s_channel_init_std_mode(mic_rx,&cfg); if(err) goto fail;
    i2s_event_callbacks_t callbacks={.on_recv_q_ovf=mic_q_overflow};
    err=i2s_channel_register_event_callback(mic_rx,&callbacks,NULL); if(err) goto fail;
    err=i2s_channel_enable(mic_rx); if(err) goto fail;
    /* MCLK must be present during codec reset, as in vendor hal_audio. */
    /* open, sample format/clock, then start: values follow vendor's codec driver.
       Gain enum 5 = 30 dB (vendor hal_audio). DAC is muted and amp remains off. */
    static const uint8_t regs[][2]={
        {0x0d,0xfa},{0x44,0x08},{0x44,0x08},{0x01,0x30},{0x02,0x00},
        {0x03,0x10},{0x16,0x24},{0x04,0x10},{0x05,0x00},{0x0b,0x00},
        {0x0c,0x00},{0x10,0x1f},{0x11,0x7f},{0x00,0x80},{0x01,0x3f},
        {0x06,0x00},{0x13,0x10},{0x1b,0x0a},{0x1c,0x6a},{0x44,0x58},
        {0x09,0x0c},{0x0a,0x0c}, /* 16-bit Philips */
        {0x02,0x00},{0x05,0x00},{0x03,0x10},{0x04,0x20},
        {0x07,0x00},{0x08,0xff},{0x06,0x03}, /* 4.096 MHz/16 kHz */
        {0x00,0x80},{0x01,0x3f},{0x09,0x0c},{0x0a,0x0c},
        {0x17,0xbf},{0x0e,0x02},{0x12,0x00},{0x14,0x1a},{0x0d,0x01},
        {0x15,0x40},{0x37,0x08},{0x45,0x00},{0x16,0x05},
        {0x31,0x60},{0x32,0x00}, /* mute DAC; no speaker data */
    };
    for(unsigned i=0;i<sizeof regs/sizeof regs[0];i++) {
        err=write_reg(codec,regs[i][0],regs[i][1]); if(err) goto fail;
    }
    uint8_t format;
    err=read_reg(codec,0x0a,&format,1);
    if(!err && format!=0x0c) err=ESP_ERR_INVALID_RESPONSE;
    if(!err) { i2s_channel_disable(mic_rx); return ESP_OK; }
fail:
    /* Disable is harmlessly rejected when initialization never reached RUNNING. */
    i2s_channel_disable(mic_rx);
    i2s_del_channel(mic_rx); mic_rx=NULL; return err;
}
esp_err_t board_mic_start(void)
{
    if(!mic_rx) { esp_err_t e=mic_init(); if(e) return e; }
    mic_used=0; atomic_store(&mic_overflow,false);
    esp_err_t e=i2s_channel_enable(mic_rx); mic_enabled=e==ESP_OK; return e;
}
void board_mic_stop(void)
{
    if(mic_enabled) { i2s_channel_disable(mic_rx); mic_enabled=false; }
    mic_used=0; memset(mic_stereo,0,sizeof mic_stereo);
}
esp_err_t board_mic_read(int16_t pcm[320])
{
    if(!mic_enabled) return ESP_ERR_INVALID_STATE;
    if(atomic_load(&mic_overflow)) return ESP_ERR_INVALID_RESPONSE;
    size_t n=0;
    esp_err_t e=i2s_channel_read(mic_rx,(uint8_t*)mic_stereo+mic_used,sizeof mic_stereo-mic_used,&n,0);
    mic_used+=n;
    if(e!=ESP_OK && e!=ESP_ERR_TIMEOUT) return e;
    if(mic_used!=sizeof mic_stereo) return ESP_ERR_NOT_FINISHED;
    for(unsigned i=0;i<320;i++) pcm[i]=mic_stereo[2*i];
    mic_used=0; return ESP_OK;
}
void *board_audio_alloc(size_t bytes)
{
    void *p=heap_caps_malloc(bytes,MALLOC_CAP_SPIRAM|MALLOC_CAP_8BIT);
    return p?p:heap_caps_malloc(bytes,MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT);
}

void *board_ui_alloc(size_t bytes)
{
    /* Artwork is optional: never consume scarce internal memory on PSRAM failure. */
    return heap_caps_malloc(bytes,MALLOC_CAP_SPIRAM|MALLOC_CAP_8BIT);
}
unsigned board_ui_strip_rows(void) { return 32; }
