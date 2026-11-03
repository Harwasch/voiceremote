idf_component_register(SRCS "protocol.c" "state.c" "main.c" "ui.c" "ble.c"
    "icons/sparkle.c" "fonts/lexend_24.c" "fonts/lexend_30.c" "fonts/lexend_42.c" "fonts/lexend_84.c"
    INCLUDE_DIRS "." REQUIRES ${REMOTE_BOARD} bt nvs_flash esp_timer lvgl__lvgl)
