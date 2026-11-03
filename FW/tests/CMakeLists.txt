cmake_minimum_required(VERSION 3.16)
project(remote_logic_tests C)
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
