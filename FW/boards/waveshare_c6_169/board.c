/* SPDX-License-Identifier: Apache-2.0
 * Small board adapter written from schematic nets / vendor configuration values.
 * No Waveshare demo implementation reused. See README for exact pin provenance.
 */
#include "board.h"
#include "controls.h"
#include "storage.h"
#include "driver/gpio.h"
#include "driver/i2c_master.h"
#include "driver/spi_master.h"
#include "esp_lcd_panel_vendor.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_ops.h"
#include "esp_flash.h"
#include "esp_partition.h"
#include "esp_log.h"
#include "esp_attr.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

static board_info_t info={2,240,280,0xbf,false,true,true,false}; /* all v1 controls, offline; no hw cut */
static i2c_master_bus_handle_t bus;
static i2c_master_dev_handle_t touch,codec,ioe;
static esp_lcd_panel_handle_t panel;
static SemaphoreHandle_t dma_done;
static c6_controls_t controls;
static bool ioe_ready;
static board_touch_t touch_state=BOARD_TOUCH_UP;
static uint16_t touch_x,touch_y;
static uint32_t touch_at;
static esp_err_t mic_init(void);
const board_info_t *board_info(void) { return &info; }
static esp_err_t read_reg(i2c_master_dev_handle_t d,uint8_t reg,uint8_t *p,size_t n)
{ return i2c_master_transmit_receive(d,&reg,1,p,n,2); }
static esp_err_t write_reg(i2c_master_dev_handle_t d,uint8_t reg,uint8_t value)
{ uint8_t b[]={reg,value}; return i2c_master_transmit(d,b,2,2); }
static bool transfer_done(esp_lcd_panel_io_handle_t io,esp_lcd_panel_io_event_data_t *e,void *ctx)
{
    (void)io; (void)e; BaseType_t wake=pdFALSE;
    xSemaphoreGiveFromISR(ctx,&wake); return wake==pdTRUE;
}
esp_err_t board_init(void)
{
    /* BAT_EN holds the battery latch, not a microphone power switch. */
    gpio_config_t out={.pin_bit_mask=(1ULL<<15)|(1ULL<<6),.mode=GPIO_MODE_OUTPUT};
    ESP_ERROR_CHECK(gpio_config(&out));
    ESP_ERROR_CHECK(gpio_set_level(15,1)); ESP_ERROR_CHECK(gpio_set_level(6,0));
    gpio_config_t in={.pin_bit_mask=(1ULL<<9)|(1ULL<<18)|(1ULL<<11)|(1ULL<<17),.mode=GPIO_MODE_INPUT};
    ESP_ERROR_CHECK(gpio_config(&in)); /* external pulls; UART never owns 16/17 */
    i2c_master_bus_config_t bc={.i2c_port=I2C_NUM_0,.sda_io_num=8,.scl_io_num=7,
        .clk_source=I2C_CLK_SRC_DEFAULT,.glitch_ignore_cnt=7,.flags.enable_internal_pullup=false};
    ESP_ERROR_CHECK(i2c_new_master_bus(&bc,&bus));
    i2c_device_config_t dc={.dev_addr_length=I2C_ADDR_BIT_LEN_7,.device_address=0x15,.scl_speed_hz=100000};
    ESP_ERROR_CHECK(i2c_master_bus_add_device(bus,&dc,&touch));
    dc.device_address=0x18; ESP_ERROR_CHECK(i2c_master_bus_add_device(bus,&dc,&codec));
    if(i2c_master_probe(bus,0x20,2)==ESP_OK) {
        dc.device_address=0x20; ESP_ERROR_CHECK(i2c_master_bus_add_device(bus,&dc,&ioe));
        /* Present but failed initialization stays physical/fail-closed. */
        info.virtual_sliders=false;
        esp_err_t e=write_reg(ioe,1,0);
        if(!e) e=write_reg(ioe,2,0);
        if(!e) e=write_reg(ioe,3,0x1f);
        uint8_t raw=0;
        if(!e) e=read_reg(ioe,0,&raw,1); /* baseline acknowledges INT before polling */
        ioe_ready=e==ESP_OK;
        c6_controls_sample(&controls,ioe_ready,raw,!gpio_get_level(17),0);
        if(e) ESP_LOGE("board","TCA9554 init failed; controls held OFF");
    }
    dma_done=xSemaphoreCreateBinary(); if(!dma_done) return ESP_ERR_NO_MEM;
    spi_bus_config_t sc={.mosi_io_num=2,.miso_io_num=-1,.sclk_io_num=1,
        .quadwp_io_num=-1,.quadhd_io_num=-1,.max_transfer_sz=240*8*2};
    ESP_ERROR_CHECK(spi_bus_initialize(SPI2_HOST,&sc,SPI_DMA_CH_AUTO));
    esp_lcd_panel_io_spi_config_t ic={.cs_gpio_num=5,.dc_gpio_num=3,.spi_mode=0,
        .pclk_hz=40000000,.trans_queue_depth=1,.lcd_cmd_bits=8,.lcd_param_bits=8,
        .on_color_trans_done=transfer_done,.user_ctx=dma_done};
    esp_lcd_panel_io_handle_t io;
    ESP_ERROR_CHECK(esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)SPI2_HOST,&ic,&io));
    esp_lcd_panel_dev_config_t pc={.reset_gpio_num=4,.rgb_ele_order=LCD_RGB_ELEMENT_ORDER_RGB,.bits_per_pixel=16};
    ESP_ERROR_CHECK(esp_lcd_new_panel_st7789(io,&pc,&panel));
    ESP_ERROR_CHECK(esp_lcd_panel_reset(panel)); /* R33 also resets touch */
    ESP_ERROR_CHECK(esp_lcd_panel_init(panel));
    ESP_ERROR_CHECK(esp_lcd_panel_invert_color(panel,true));
    /* Vendor 03_lvgl_example_v9/main/main.c:18,131-134,158 and
     * 01_factory/main/main.c:29,196-199,223: rotation 0, gap +20 rows. */
    ESP_ERROR_CHECK(esp_lcd_panel_set_gap(panel,0,20));
    ESP_ERROR_CHECK(esp_lcd_panel_swap_xy(panel,false));
    ESP_ERROR_CHECK(esp_lcd_panel_mirror(panel,false,false));
    ESP_ERROR_CHECK(esp_lcd_panel_disp_on_off(panel,true));
    ESP_ERROR_CHECK(gpio_set_level(6,1));
    vTaskDelay(pdMS_TO_TICKS(50));
    /* CST816T disables automatic sleep so held/up state remains readable. */
    if(write_reg(touch,0xfe,1)!=ESP_OK) ESP_LOGW("board","touch sleep-disable failed");
    uint32_t physical=0;
    const esp_partition_t *p=esp_partition_find_first(ESP_PARTITION_TYPE_DATA,0x40,"offline");
    esp_err_t fe=esp_flash_get_physical_size(NULL,&physical);
    ESP_LOGW("board","physical_flash_bytes=%lu; offline partition=%s",(unsigned long)physical,p?"found":"missing");
    if(fe || !p || !c6_storage_fits(physical,p->address,p->size)) info.capabilities&=~128u;
    ESP_ERROR_CHECK(mic_init()); /* allocate DMA + configure codec before task startup */
    ESP_LOGW("board","C6 ready: controls=%s; hw_mic_cut=0; amp CTRL hardwired VSYS, DAC muted",
        ioe?"TCA9554":"touch + BOOT PTT + PWR target");
    return ESP_OK;
}
esp_err_t board_flush(int x1,int y1,int x2,int y2,const void *pixels)
{
    esp_err_t e=esp_lcd_panel_draw_bitmap(panel,x1,y1,x2+1,y2+1,pixels);
    if(e) return e;
    bool done=xSemaphoreTake(dma_done,pdMS_TO_TICKS(1000))==pdTRUE;
    /* Small strips and a real blocked tick let lower priority work run as well.
     * Audio (22), BLE host (21), input (5) preempt every software drawing pass. */
    vTaskDelay(1);
    return done?ESP_OK:ESP_ERR_TIMEOUT;
}
void board_sample_inputs(uint32_t now)
{
    /* All I2C runs here outside remote_mutex. Audio reads only I2S DMA.
     * Polling INT avoids ISR storms; bounded 10 ms retry even for stuck-low INT. */
    if(ioe) {
        controls.irq_low=!gpio_get_level(17);
        if(c6_controls_due(&controls,now)) {
            uint8_t raw=0; bool ok=ioe_ready && read_reg(ioe,0,&raw,1)==ESP_OK;
            c6_controls_sample(&controls,ok,raw,!gpio_get_level(17),now);
        }
        c6_controls_stale(&controls,now);
    }
    if((uint32_t)(now-touch_at)<10) return;
    touch_at=now;
    uint8_t b[7];
    if(read_reg(touch,0,b,sizeof b)!=ESP_OK) { touch_state=BOARD_TOUCH_ERROR; return; }
    touch_x=((b[3]&15)<<8)|b[4]; touch_y=((b[5]&15)<<8)|b[6];
    touch_state=(b[2]==1 && ((b[3]>>6)==0 || (b[3]>>6)==2) && touch_x<240 && touch_y<280)?BOARD_TOUCH_DOWN:BOARD_TOUCH_UP;
}
bool board_physical_controls(uint8_t *capture,uint8_t *mode)
{
    static uint8_t previous_capture,previous_mode;
    if(!ioe || !controls.changed) return false;
    controls.changed=false;
    if(previous_capture==controls.value.capture && previous_mode==controls.value.mode) return false;
    *capture=previous_capture==controls.value.capture?UINT8_MAX:controls.value.capture;
    *mode=previous_mode==controls.value.mode?UINT8_MAX:controls.value.mode;
    previous_capture=controls.value.capture; previous_mode=controls.value.mode; return true;
}
board_touch_t board_touch(uint16_t *x,uint16_t *y)
{ *x=touch_x; *y=touch_y; return touch_state; }
bool board_button(unsigned b)
{
    if(ioe) return b==0?controls.value.ptt:b==1?controls.value.target:false;
    return b<2 && !gpio_get_level(b==0?9:18);
}
void board_haptic(uint32_t now) { (void)now; } /* no motor fitted */
void board_poll(uint32_t now) { (void)now; }

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
        .gpio_cfg={.mclk=19,.bclk=20,.ws=22,.dout=-1,.din=21},
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
{ return heap_caps_malloc(bytes,MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT); }
void *board_ui_alloc(size_t bytes) { (void)bytes; return NULL; }
unsigned board_ui_strip_rows(void) { return 8; }
