#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "esp_err.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "nvs_flash.h"
#include "sdkconfig.h"

#include "ble.h"
#include "dc_device.h"
#include "dc_frame.h"
#include "dc_messages.h"
#include "store.h"

static const char *TAG = "centralina";

#define FW_MAJOR 0
#define FW_MINOR 1
#define FW_PATCH 0

/* Il comando di guasto esiste solo nel firmware costruito con sdkconfig.debug. */
#ifdef CONFIG_DC_DEBUG_COMMANDS
#define DEBUG_COMMANDS true
#else
#define DEBUG_COMMANDS false
#endif

#define TELEMETRY_PERIOD_MS 2000
#define COMMAND_QUEUE_LENGTH 4

typedef struct {
    uint16_t conn_handle;
    uint8_t len;
    uint8_t bytes[DC_FRAME_MAX_SIZE];
} command;

static QueueHandle_t commands;
static uint8_t info_frame[DC_FRAME_OVERHEAD + DC_INFO_SIZE];

/*
 * Chiamata dal task di NimBLE. Non esegue il comando: lo passa al task della
 * centralina, perché scrivere su NVS può richiedere decine di millisecondi e
 * nel frattempo lo stack Bluetooth deve continuare a girare.
 */
static bool enqueue_command(uint16_t conn_handle, const uint8_t *bytes, size_t len) {
    command item = {.conn_handle = conn_handle, .len = (uint8_t)len};
    memcpy(item.bytes, bytes, len);
    return xQueueSend(commands, &item, 0) == pdTRUE;
}

static void build_info_frame(void) {
    dc_info info = {DC_PROTOCOL_VERSION, FW_MAJOR, FW_MINOR, FW_PATCH};
    dc_frame frame = {.type = DC_MSG_INFO, .seq = 0, .len = DC_INFO_SIZE};
    dc_encode_info(&info, frame.payload);
    size_t written = 0;
    dc_frame_encode(&frame, info_frame, sizeof(info_frame), &written);
}

/*
 * La temperatura è simulata: si muove di un decimo di grado a ogni lettura verso
 * il setpoint in comfort, tre gradi sotto in economia, verso i 15 gradi da
 * spenta. Basta perché nell'app si veda che il setpoint cambia qualcosa.
 */
static int16_t simulate_temperature(int16_t current, const dc_params *params) {
    int16_t target;
    switch (params->mode) {
    case DC_MODE_COMFORT:
        target = params->setpoint;
        break;
    case DC_MODE_ECO:
        target = (int16_t)(params->setpoint - 30);
        break;
    default:
        target = 150;
        break;
    }
    if (current < target) {
        return (int16_t)(current + 1);
    }
    if (current > target) {
        return (int16_t)(current - 1);
    }
    return current;
}

static void send_telemetry(int16_t temperature) {
    dc_telemetry telemetry = {
        .temperature = temperature,
        .uptime_s = (uint32_t)(esp_timer_get_time() / 1000000),
    };
    dc_frame frame = {.type = DC_MSG_TELEMETRY, .seq = 0, .len = DC_TELEMETRY_SIZE};
    dc_encode_telemetry(&telemetry, frame.payload);
    uint8_t bytes[DC_FRAME_OVERHEAD + DC_TELEMETRY_SIZE];
    size_t written = 0;
    if (dc_frame_encode(&frame, bytes, sizeof(bytes), &written) == DC_FRAME_OK) {
        ble_send_telemetry(bytes, written);
    }
}

static void handle_command(dc_device_state *state, const dc_device_config *config,
                           const command *item) {
    dc_device_state before = *state;
    uint8_t response[DC_FRAME_MAX_SIZE];
    size_t response_len = 0;
    dc_action action =
        dc_device_handle(state, config, item->bytes, item->len, response, &response_len);

    switch (action) {
    case DC_ACTION_RESPOND:
        break;
    case DC_ACTION_PERSIST_THEN_RESPOND:
        if (!store_save(state)) {
            // Non si può rispondere OK per un valore che non è sulla flash. Si
            // torna allo stato di prima e non si risponde: l'app vede un esito
            // incerto, ripete la stessa richiesta e questa volta, se la flash
            // regge, riceve OK.
            *state = before;
            return;
        }
        break;
    case DC_ACTION_PERSIST_THEN_REBOOT:
        // Il comando di guasto: la modifica è sulla flash, la risposta non
        // partirà mai. Alla riconnessione l'app deve scoprire da sola che cosa è
        // successo, ed è il punto 4 della prova sull'hardware.
        if (store_save(state)) {
            ESP_LOGW(TAG, "modifica salvata, riavvio senza rispondere");
            esp_restart();
        }
        *state = before;
        return;
    }

    if (response_len > 0 && !ble_send_response(item->conn_handle, response, response_len)) {
        ESP_LOGW(TAG, "risposta non inviata: il client è andato via");
    }
}

/*
 * Il solo task che tocca lo stato della centralina: esegue i comandi in ordine e,
 * quando non ne arrivano, manda la telemetria. Così non servono lock.
 */
static void device_task(void *param) {
    (void)param;
    dc_device_state state;
    store_load(&state);
    dc_device_config config = {.debug_commands = DEBUG_COMMANDS};
    int16_t temperature = 180;
    TickType_t next_telemetry = xTaskGetTickCount() + pdMS_TO_TICKS(TELEMETRY_PERIOD_MS);

    for (;;) {
        // La differenza con segno regge anche quando il contatore dei tick torna
        // a zero.
        int32_t remaining = (int32_t)(next_telemetry - xTaskGetTickCount());
        TickType_t wait = remaining > 0 ? (TickType_t)remaining : 0;
        command item;
        if (xQueueReceive(commands, &item, wait) == pdTRUE) {
            handle_command(&state, &config, &item);
            continue;
        }
        temperature = simulate_temperature(temperature, &state.params);
        send_telemetry(temperature);
        next_telemetry = xTaskGetTickCount() + pdMS_TO_TICKS(TELEMETRY_PERIOD_MS);
    }
}

void app_main(void) {
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    ESP_LOGI(TAG, "firmware %d.%d.%d, comandi di debug %s", FW_MAJOR, FW_MINOR, FW_PATCH,
             DEBUG_COMMANDS ? "attivi" : "spenti");

    build_info_frame();
    commands = xQueueCreate(COMMAND_QUEUE_LENGTH, sizeof(command));
    if (commands == NULL ||
        xTaskCreate(device_task, "centralina", 4096, NULL, 5, NULL) != pdPASS) {
        ESP_LOGE(TAG, "task della centralina non avviato");
        return;
    }
    if (!ble_start(info_frame, sizeof(info_frame), enqueue_command)) {
        ESP_LOGE(TAG, "Bluetooth non avviato");
    }
}
