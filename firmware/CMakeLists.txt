cmake_minimum_required(VERSION 3.22)

# Il nucleo del protocollo non si copia: è lo stesso native/dc_core dei test sul
# PC e del plugin Android, qui costruito come componente di ESP-IDF.
set(EXTRA_COMPONENT_DIRS ../native/dc_core)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
idf_build_set_property(MINIMAL_BUILD ON)
project(centralina)
