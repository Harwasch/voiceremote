cmake_minimum_required(VERSION 3.16)
project(ui_preview C CXX)
# Purpose: compile the production UI against LVGL's native software renderer.
# Inputs: managed LVGL 9.5.0 + FW/app. Verification: run.sh + interaction checks.
get_filename_component(FW_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(LVGL_DIR "${FW_ROOT}/managed_components/lvgl__lvgl")
if(NOT EXISTS "${LVGL_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "LVGL missing: populate FW/managed_components/lvgl__lvgl using the FW/README.md IDF setup first (LVGL 9.5.0).")
endif()
set(LV_BUILD_CONF_PATH "${CMAKE_CURRENT_LIST_DIR}/lv_conf.h" CACHE PATH "" FORCE)
set(CONFIG_LV_BUILD_DEMOS OFF CACHE BOOL "" FORCE)
set(CONFIG_LV_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(CONFIG_LV_USE_THORVG_INTERNAL OFF CACHE BOOL "" FORCE)
add_subdirectory("${LVGL_DIR}" "lvgl")
target_compile_options(lvgl PRIVATE -O2)
set(PREVIEW_SOURCES main.c "${FW_ROOT}/app/timing.c" "${FW_ROOT}/app/ui.c" "${FW_ROOT}/app/state.c"
    "${FW_ROOT}/app/protocol.c" "${FW_ROOT}/app/icons/sparkle.c" "${FW_ROOT}/app/fonts/lexend_24.c"
    "${FW_ROOT}/app/fonts/lexend_30.c" "${FW_ROOT}/app/fonts/lexend_42.c"
    "${FW_ROOT}/app/fonts/lexend_84.c")
foreach(preview ui_preview ui_preview_hook)
add_executable(${preview} ${PREVIEW_SOURCES})
target_include_directories(${preview} PRIVATE . stubs "${FW_ROOT}/app")
target_compile_definitions(${preview} PRIVATE UI_PREVIEW=1 VR_TIMING=1)
target_compile_options(${preview} PRIVATE -O2 -Wall -Wextra -Werror -UNDEBUG)
target_link_libraries(${preview} PRIVATE lvgl::lvgl m)

endforeach()
target_compile_definitions(ui_preview_hook PRIVATE REMOTE_TEST_HOOK=1)
