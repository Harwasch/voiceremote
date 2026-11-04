idf_build_get_property(remote_test_hook REMOTE_TEST_HOOK)
idf_build_get_property(remote_board REMOTE_BOARD)
set(hook_requires)
if(remote_test_hook)
    list(APPEND hook_requires esp_driver_usb_serial_jtag)
endif()
idf_component_register(SRCS "offline_capture.c" "offline_store.c" "offline_runtime.c" "timing.c" "audio.c" "audio_runtime.c" "protocol.c" "state.c" "main.c" "ui.c" "ble.c"
    "icons/sparkle.c" "fonts/lexend_24.c" "fonts/lexend_30.c" "fonts/lexend_42.c" "fonts/lexend_84.c"
    INCLUDE_DIRS "." REQUIRES ${hook_requires} ${remote_board} bt esp_partition nvs_flash esp_timer esp_hw_support 78__esp-opus lvgl__lvgl)

target_compile_definitions(${COMPONENT_LIB} PRIVATE VR_TIMING=$<BOOL:${REMOTE_TIMING}>)

if(remote_test_hook)
    target_compile_definitions(${COMPONENT_LIB} PRIVATE REMOTE_TEST_HOOK=1)
endif()
