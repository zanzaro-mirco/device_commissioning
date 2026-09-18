#include "store.h"

#include <stdint.h>

#include "esp_err.h"
#include "esp_log.h"
#include "nvs.h"

static const char *TAG = "store";

#define NAMESPACE "centralina"
#define KEY "state"

/*
 * Lo stato si salva in un formato fisso e non come struct: la disposizione in
 * memoria di una struct dipende dal compilatore, quella di questi byte no. Il
 * primo byte è la versione del formato, per poterlo cambiare domani senza
 * leggere come validi i byte di ieri.
 */
#define FORMAT_VERSION 1
#define RECORD_SIZE 8

static void encode(const dc_device_state *state, uint8_t *out) {
    uint16_t setpoint = (uint16_t)state->params.setpoint;
    out[0] = FORMAT_VERSION;
    out[1] = (uint8_t)state->revision;
    out[2] = (uint8_t)(state->revision >> 8);
    out[3] = (uint8_t)(state->revision >> 16);
    out[4] = (uint8_t)(state->revision >> 24);
    out[5] = (uint8_t)setpoint;
    out[6] = (uint8_t)(setpoint >> 8);
    out[7] = state->params.mode;
}

static bool decode(const uint8_t *in, dc_device_state *state) {
    if (in[0] != FORMAT_VERSION) {
        return false;
    }
    state->revision = (uint32_t)in[1] | (uint32_t)in[2] << 8 | (uint32_t)in[3] << 16 |
                      (uint32_t)in[4] << 24;
    state->params.setpoint = (int16_t)(uint16_t)(in[5] | in[6] << 8);
    state->params.mode = in[7];
    // Valori fuori dai limiti sulla flash vogliono dire flash rovinata o un
    // difetto: meglio ripartire dai valori di fabbrica che applicarli.
    return dc_params_in_range(&state->params);
}

void store_load(dc_device_state *state) {
    dc_device_factory_state(state);

    nvs_handle_t handle;
    esp_err_t err = nvs_open(NAMESPACE, NVS_READONLY, &handle);
    if (err == ESP_ERR_NVS_NOT_FOUND) {
        ESP_LOGI(TAG, "nessuno stato salvato: valori di fabbrica");
        return;
    }
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "apertura di NVS fallita: %s", esp_err_to_name(err));
        return;
    }

    uint8_t record[RECORD_SIZE];
    size_t length = sizeof(record);
    err = nvs_get_blob(handle, KEY, record, &length);
    nvs_close(handle);
    if (err != ESP_OK || length != RECORD_SIZE) {
        ESP_LOGI(TAG, "nessuno stato salvato: valori di fabbrica");
        return;
    }

    dc_device_state loaded;
    if (!decode(record, &loaded)) {
        ESP_LOGE(TAG, "stato salvato non valido: valori di fabbrica");
        return;
    }
    *state = loaded;
    ESP_LOGI(TAG, "stato caricato: revisione %lu", (unsigned long)state->revision);
}

bool store_save(const dc_device_state *state) {
    uint8_t record[RECORD_SIZE];
    encode(state, record);

    nvs_handle_t handle;
    esp_err_t err = nvs_open(NAMESPACE, NVS_READWRITE, &handle);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "apertura di NVS fallita: %s", esp_err_to_name(err));
        return false;
    }
    err = nvs_set_blob(handle, KEY, record, sizeof(record));
    // Senza il commit il valore può restare in memoria e non arrivare alla flash.
    if (err == ESP_OK) {
        err = nvs_commit(handle);
    }
    nvs_close(handle);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "salvataggio fallito: %s", esp_err_to_name(err));
        return false;
    }
    return true;
}
