idf_component_register(SRCS "board.c" INCLUDE_DIRS "../../app"
    REQUIRES esp_driver_gpio esp_driver_i2c esp_driver_spi esp_lcd esp_timer esp_lcd_co5300)
