cmake_minimum_required(VERSION 3.16)
project(remote_logic_tests C CXX)
enable_testing()
add_executable(remote_tests test.c ../app/protocol.c ../app/state.c)
target_include_directories(remote_tests PRIVATE ../app)
target_link_libraries(remote_tests PRIVATE m)
target_compile_features(remote_tests PRIVATE c_std_11)
target_compile_options(remote_tests PRIVATE -Wall -Wextra -Werror -UNDEBUG)
add_test(NAME remote_logic COMMAND remote_tests)
find_package(Python3 3.12 REQUIRED COMPONENTS Interpreter)
add_test(NAME ble_client_wire COMMAND ${Python3_EXECUTABLE} -m unittest discover
    -s ${CMAKE_CURRENT_SOURCE_DIR}/../tools/ble_client -p test_wire.py -v)

add_executable(audio_tests test_audio.c ../app/audio.c ../app/protocol.c ../app/state.c)
target_include_directories(audio_tests PRIVATE ../app)
target_compile_features(audio_tests PRIVATE c_std_11)
target_compile_options(audio_tests PRIVATE -Wall -Wextra -Werror -UNDEBUG)
add_test(NAME audio_transport COMMAND audio_tests)
add_test(NAME audio_client COMMAND ${Python3_EXECUTABLE} -m unittest discover
    -s ${CMAKE_CURRENT_SOURCE_DIR}/../tools/ble_client -p test_audio.py -v)
set_tests_properties(audio_client PROPERTIES ENVIRONMENT "VR_FRAMER=$<TARGET_FILE:audio_tests>")

add_test(NAME ble_client_offline COMMAND ${Python3_EXECUTABLE} -m unittest discover
    -s ${CMAKE_CURRENT_SOURCE_DIR}/../tools/ble_client -p test_offline.py -v)

add_executable(offline_capture_tests test_offline_capture.c ../app/offline_capture.c)
target_include_directories(offline_capture_tests PRIVATE ../app)
target_compile_features(offline_capture_tests PRIVATE c_std_11)
target_compile_options(offline_capture_tests PRIVATE -Wall -Wextra -Werror -UNDEBUG)
add_test(NAME offline_capture COMMAND offline_capture_tests)
add_test(NAME generated_partitions COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/check_partitions.py)

add_executable(offline_runtime_tests test_offline_runtime.c ../app/offline_store.c ../app/offline_capture.c ../app/protocol.c ../app/state.c)
target_include_directories(offline_runtime_tests PRIVATE offline_stubs ../app)
target_compile_features(offline_runtime_tests PRIVATE c_std_11)
target_compile_options(offline_runtime_tests PRIVATE -Wall -Wextra -Werror -UNDEBUG)
add_test(NAME offline_runtime COMMAND offline_runtime_tests)

add_executable(offline_store_tests test_offline_store.c ../app/offline_store.c)
target_include_directories(offline_store_tests PRIVATE ../app)
target_compile_features(offline_store_tests PRIVATE c_std_11)
target_compile_options(offline_store_tests PRIVATE -Wall -Wextra -Werror -UNDEBUG)
add_test(NAME offline_store COMMAND offline_store_tests)

add_executable(audio_runtime_tests test_audio_runtime.c ../app/audio.c ../app/protocol.c ../app/state.c)
target_include_directories(audio_runtime_tests PRIVATE offline_stubs ../app)
target_compile_features(audio_runtime_tests PRIVATE c_std_11)
target_compile_options(audio_runtime_tests PRIVATE -Wall -Wextra -Werror -UNDEBUG)
add_test(NAME audio_runtime COMMAND audio_runtime_tests)

add_executable(test_hook_tests test_hook.c)
target_include_directories(test_hook_tests PRIVATE ../app)
target_compile_options(test_hook_tests PRIVATE -Wall -Wextra -Werror -UNDEBUG)
add_test(NAME test_hook COMMAND test_hook_tests)
add_test(NAME hil_runner COMMAND ${Python3_EXECUTABLE} -m unittest discover
    -s ${CMAKE_CURRENT_SOURCE_DIR}/../tools/hil -p test_*.py -v)

# The real renderer/barrier must run here: pure state mocks missed slow hardware.
add_subdirectory(../tools/ui_preview ui-preview)
add_test(NAME phone_render_barrier COMMAND ui_preview --check)
add_test(NAME ui_hook_debounce COMMAND ui_preview_hook --check)
add_test(NAME ui_without_psram COMMAND ui_preview --check)
set_tests_properties(ui_without_psram PROPERTIES ENVIRONMENT "VR_UI_NO_CACHE=1")
add_test(NAME release_hook_guard COMMAND ${Python3_EXECUTABLE} -m unittest discover
    -s ${CMAKE_CURRENT_SOURCE_DIR} -p test_config.py -v)

add_executable(ble_tests test_ble.c ../app/protocol.c ../app/state.c)
target_include_directories(ble_tests PRIVATE . offline_stubs ../app)
target_compile_features(ble_tests PRIVATE c_std_11)
target_compile_options(ble_tests PRIVATE -Wall -Wextra -Werror -UNDEBUG)
add_test(NAME ble_security_handoff COMMAND ble_tests)
add_test(NAME offline_factory COMMAND offline_store_tests factory)
add_test(NAME offline_corruption COMMAND offline_store_tests corruption)
add_test(NAME offline_broken_mount COMMAND offline_runtime_tests mount)

add_test(NAME offline_header_body COMMAND offline_store_tests headers)
add_test(NAME offline_sparse_format COMMAND offline_store_tests sparse)
add_test(NAME ble_enrollment_scope COMMAND ble_tests enrollment)

add_executable(c6_controls_tests test_c6_controls.c ../boards/waveshare_c6_169/controls.c)
target_include_directories(c6_controls_tests PRIVATE ../boards/waveshare_c6_169)
target_compile_options(c6_controls_tests PRIVATE -Wall -Wextra -Werror -UNDEBUG)
add_test(NAME c6_controls COMMAND c6_controls_tests)

add_test(NAME c6_ui_touch COMMAND ui_preview --check-c6-touch)
add_test(NAME c6_ui_physical COMMAND ui_preview --check-c6-physical)

add_executable(audio_single_core_tests test_audio_runtime.c ../app/audio.c ../app/protocol.c ../app/state.c)
target_include_directories(audio_single_core_tests PRIVATE offline_stubs ../app)
target_compile_definitions(audio_single_core_tests PRIVATE CONFIG_FREERTOS_UNICORE=1)
target_compile_options(audio_single_core_tests PRIVATE -Wall -Wextra -Werror -UNDEBUG)
add_test(NAME audio_single_core COMMAND audio_single_core_tests)
