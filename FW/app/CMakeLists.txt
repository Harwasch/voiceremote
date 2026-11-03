idf_component_register(SRCS "protocol.c" "state.c" "main.c" "ui.c" "ble.c"
    INCLUDE_DIRS "." REQUIRES ${REMOTE_BOARD} bt nvs_flash esp_timer lvgl__lvgl)
