idf_component_register(
    SRCS main.c ble.c store.c
    PRIV_REQUIRES bt nvs_flash esp_timer dc_core
    INCLUDE_DIRS .)

# Come per dc_core sul PC: un avviso è un errore.
target_compile_options(${COMPONENT_LIB} PRIVATE -Wall -Wextra -Werror)
