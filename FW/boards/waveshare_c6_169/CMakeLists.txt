idf_component_register(SRCS "board.c" "controls.c" INCLUDE_DIRS "../../app"
    REQUIRES esp_driver_i2s esp_driver_gpio esp_driver_i2c esp_driver_spi esp_lcd esp_partition spi_flash)
