cmake_minimum_required(VERSION 3.22.1)
project(dc_wire_jni C)

# Gli stessi sorgenti del firmware, presi dal loro posto e non copiati: una
# copia sarebbe una seconda implementazione che nessun test tiene allineata.
set(DC_CORE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../native/dc_core)

add_library(dc_wire_jni SHARED
    dc_wire_jni.c
    ${DC_CORE_DIR}/src/dc_crc.c
    ${DC_CORE_DIR}/src/dc_frame.c)
target_include_directories(dc_wire_jni PRIVATE ${DC_CORE_DIR}/include)
target_compile_options(dc_wire_jni PRIVATE -Wall -Wextra -Werror)
