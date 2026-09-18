#include "ble.h"

#include <stdio.h>
#include <string.h>

#include "esp_err.h"
#include "esp_log.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#include "dc_frame.h"

static const char *TAG = "ble";

/*
 * 4d5aXXXX-6d69-7263-6f7a-616e7a61726f. BLE_UUID128_INIT vuole i byte dal meno
 * significativo, cioè la stringa dell'UUID letta al contrario.
 */
#define DC_UUID(n)                                                                       \
    BLE_UUID128_INIT(0x6f, 0x72, 0x61, 0x7a, 0x6e, 0x61, 0x7a, 0x6f, 0x63, 0x72, 0x69,  \
                     0x6d, (n), 0x00, 0x5a, 0x4d)

static const ble_uuid128_t service_uuid = DC_UUID(0x01);
static const ble_uuid128_t info_uuid = DC_UUID(0x02);
static const ble_uuid128_t command_uuid = DC_UUID(0x03);
static const ble_uuid128_t response_uuid = DC_UUID(0x04);
static const ble_uuid128_t telemetry_uuid = DC_UUID(0x05);

static uint16_t info_handle;
static uint16_t command_handle;
static uint16_t response_handle;
static uint16_t telemetry_handle;

static const uint8_t *info_frame;
static size_t info_frame_len;
static ble_command_handler command_handler;

/*
 * Scritti dal task di NimBLE, letti dal task della centralina. Sono un valore di
 * 16 bit e un booleano: su questa CPU leggerli e scriverli è atomico, e un valore
 * vecchio di un istante costa al massimo una notifica scartata.
 */
static volatile uint16_t current_conn = BLE_HS_CONN_HANDLE_NONE;
static volatile bool telemetry_subscribed;

static uint8_t own_addr_type;

static int access_info(uint16_t conn_handle, uint16_t attr_handle,
                       struct ble_gatt_access_ctxt *ctxt, void *arg) {
    (void)conn_handle;
    (void)attr_handle;
    (void)arg;
    if (ctxt->op != BLE_GATT_ACCESS_OP_READ_CHR) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    int rc = os_mbuf_append(ctxt->om, info_frame, (uint16_t)info_frame_len);
    return rc == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
}

static int access_command(uint16_t conn_handle, uint16_t attr_handle,
                          struct ble_gatt_access_ctxt *ctxt, void *arg) {
    (void)attr_handle;
    (void)arg;
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    // Una scrittura più lunga della trama massima non è una trama rovinata: è
    // una scrittura che nessun client di questo protocollo fa. Si rifiuta a
    // livello ATT, e l'app sa che il comando non è partito.
    uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
    if (len > DC_FRAME_MAX_SIZE) {
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }
    uint8_t bytes[DC_FRAME_MAX_SIZE];
    uint16_t copied = 0;
    if (ble_hs_mbuf_to_flat(ctxt->om, bytes, sizeof(bytes), &copied) != 0) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    // La risposta ATT parte quando questa funzione torna, prima che il comando
    // sia eseguito: conferma solo che i byte sono arrivati. L'esito del comando
    // arriva dopo, come notifica sulle risposte.
    return command_handler(conn_handle, bytes, copied) ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
}

/* Le risposte e la telemetria si ricevono solo per notifica. */
static int access_notify_only(uint16_t conn_handle, uint16_t attr_handle,
                              struct ble_gatt_access_ctxt *ctxt, void *arg) {
    (void)conn_handle;
    (void)attr_handle;
    (void)ctxt;
    (void)arg;
    return BLE_ATT_ERR_READ_NOT_PERMITTED;
}

static const struct ble_gatt_svc_def services[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &service_uuid.u,
        .characteristics =
            (struct ble_gatt_chr_def[]){
                {
                    .uuid = &info_uuid.u,
                    .access_cb = access_info,
                    .flags = BLE_GATT_CHR_F_READ,
                    .val_handle = &info_handle,
                },
                {
                    .uuid = &command_uuid.u,
                    .access_cb = access_command,
                    .flags = BLE_GATT_CHR_F_WRITE,
                    .val_handle = &command_handle,
                },
                {
                    .uuid = &response_uuid.u,
                    .access_cb = access_notify_only,
                    .flags = BLE_GATT_CHR_F_NOTIFY,
                    .val_handle = &response_handle,
                },
                {
                    .uuid = &telemetry_uuid.u,
                    .access_cb = access_notify_only,
                    .flags = BLE_GATT_CHR_F_NOTIFY,
                    .val_handle = &telemetry_handle,
                },
                {0},
            },
    },
    {0},
};

static void start_advertising(void);

static int on_gap_event(struct ble_gap_event *event, void *arg) {
    (void)arg;
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        ESP_LOGI(TAG, "connessione: stato %d", event->connect.status);
        if (event->connect.status == 0) {
            current_conn = event->connect.conn_handle;
        } else {
            start_advertising();
        }
        return 0;
    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "disconnessione: motivo %d", event->disconnect.reason);
        current_conn = BLE_HS_CONN_HANDLE_NONE;
        telemetry_subscribed = false;
        start_advertising();
        return 0;
    case BLE_GAP_EVENT_ADV_COMPLETE:
        start_advertising();
        return 0;
    case BLE_GAP_EVENT_SUBSCRIBE:
        if (event->subscribe.attr_handle == telemetry_handle) {
            telemetry_subscribed = event->subscribe.cur_notify;
        }
        return 0;
    default:
        return 0;
    }
}

static void start_advertising(void) {
    // Nel pacchetto di advertising va il servizio, su cui filtra la scansione
    // dell'app. Il nome non ci starebbe, e va nella risposta alla scansione.
    struct ble_hs_adv_fields fields = {0};
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids128 = &service_uuid;
    fields.num_uuids128 = 1;
    fields.uuids128_is_complete = 1;
    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "dati di advertising non validi: %d", rc);
        return;
    }

    struct ble_hs_adv_fields response = {0};
    const char *name = ble_svc_gap_device_name();
    response.name = (const uint8_t *)name;
    response.name_len = (uint8_t)strlen(name);
    response.name_is_complete = 1;
    rc = ble_gap_adv_rsp_set_fields(&response);
    if (rc != 0) {
        ESP_LOGE(TAG, "risposta alla scansione non valida: %d", rc);
        return;
    }

    struct ble_gap_adv_params params = {0};
    params.conn_mode = BLE_GAP_CONN_MODE_UND;
    params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    rc = ble_gap_adv_start(own_addr_type, NULL, BLE_HS_FOREVER, &params, on_gap_event, NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "advertising non avviato: %d", rc);
        return;
    }
    ESP_LOGI(TAG, "advertising come %s", name);
}

static void on_sync(void) {
    if (ble_hs_util_ensure_addr(0) != 0 || ble_hs_id_infer_auto(0, &own_addr_type) != 0) {
        ESP_LOGE(TAG, "nessun indirizzo Bluetooth utilizzabile");
        return;
    }
    // Il nome porta le ultime cifre dell'indirizzo, perché due centraline nella
    // stessa stanza si distinguano nell'elenco dell'app.
    uint8_t addr[6] = {0};
    ble_hs_id_copy_addr(own_addr_type, addr, NULL);
    char name[16];
    snprintf(name, sizeof(name), "DC-%02X%02X", addr[1], addr[0]);
    ble_svc_gap_device_name_set(name);
    start_advertising();
}

static void on_reset(int reason) {
    ESP_LOGE(TAG, "stack Bluetooth riavviato: motivo %d", reason);
}

static void host_task(void *param) {
    (void)param;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

bool ble_start(const uint8_t *info, size_t info_len, ble_command_handler on_command) {
    info_frame = info;
    info_frame_len = info_len;
    command_handler = on_command;

    esp_err_t err = nimble_port_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "NimBLE non inizializzato: %s", esp_err_to_name(err));
        return false;
    }
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.reset_cb = on_reset;

    ble_svc_gap_init();
    ble_svc_gatt_init();
    int rc = ble_gatts_count_cfg(services);
    if (rc == 0) {
        rc = ble_gatts_add_svcs(services);
    }
    if (rc != 0) {
        ESP_LOGE(TAG, "servizio GATT non registrato: %d", rc);
        return false;
    }

    nimble_port_freertos_init(host_task);
    return true;
}

static bool notify(uint16_t conn_handle, uint16_t attr_handle, const uint8_t *frame,
                   size_t len) {
    struct os_mbuf *om = ble_hs_mbuf_from_flat(frame, (uint16_t)len);
    if (om == NULL) {
        return false;
    }
    // ble_gatts_notify_custom consuma il buffer anche quando fallisce.
    return ble_gatts_notify_custom(conn_handle, attr_handle, om) == 0;
}

bool ble_send_response(uint16_t conn_handle, const uint8_t *frame, size_t len) {
    return notify(conn_handle, response_handle, frame, len);
}

bool ble_send_telemetry(const uint8_t *frame, size_t len) {
    uint16_t conn = current_conn;
    if (conn == BLE_HS_CONN_HANDLE_NONE || !telemetry_subscribed) {
        return false;
    }
    return notify(conn, telemetry_handle, frame, len);
}
