cmake_minimum_required(VERSION 3.16)

# Dentro ESP-IDF questa cartella è un componente del firmware; fuori è una
# libreria C qualunque, con i suoi test sul PC. Lo stesso codice, due modi di
# costruirlo.
if(ESP_PLATFORM)
    idf_component_register(
        SRCS src/dc_crc.c src/dc_frame.c src/dc_messages.c src/dc_device.c
        INCLUDE_DIRS include)
    return()
endif()

project(dc_core C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

add_library(dc_core STATIC
    src/dc_crc.c
    src/dc_frame.c
    src/dc_messages.c
    src/dc_device.c)
target_include_directories(dc_core PUBLIC include)

# Gli avvisi sono errori: un avviso ignorato oggi in un test sul PC è un difetto
# che domani gira sulla centralina.
if(MSVC)
    target_compile_options(dc_core PRIVATE /W4 /WX)
else()
    target_compile_options(dc_core PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Werror)
endif()

enable_testing()
add_executable(dc_core_tests test/test_main.c test/vec.c)
target_link_libraries(dc_core_tests PRIVATE dc_core)
if(MSVC)
    target_compile_definitions(dc_core_tests PRIVATE _CRT_SECURE_NO_WARNINGS)
endif()
add_test(NAME dc_core_tests
    COMMAND dc_core_tests ${CMAKE_CURRENT_SOURCE_DIR}/../../protocol/vectors)
