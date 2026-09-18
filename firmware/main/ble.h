#ifndef BLE_H
#define BLE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * Il servizio GATT di protocol/PROTOCOL.md sopra NimBLE. Qui ci sono solo il
 * Bluetooth e il trasporto dei byte: che cosa vogliono dire lo decide dc_core.
 */

/*
 * Chiamata dal task di NimBLE quando arriva una scrittura sui comandi. Deve solo
 * accodare la trama e tornare subito: restituisce false se non può accettarla, e
 * in quel caso la scrittura fallisce a livello ATT e l'app sa che il comando non
 * è partito.
 */
typedef bool (*ble_command_handler)(uint16_t conn_handle, const uint8_t *bytes, size_t len);

/* info_frame è la trama INFO restituita a ogni lettura; deve restare valida. */
bool ble_start(const uint8_t *info_frame, size_t info_len, ble_command_handler on_command);

/* Manda una trama di risposta come notifica alla connessione che ha scritto. */
bool ble_send_response(uint16_t conn_handle, const uint8_t *frame, size_t len);

/* Manda una trama di telemetria, se qualcuno è collegato e si è iscritto. */
bool ble_send_telemetry(const uint8_t *frame, size_t len);

#endif
