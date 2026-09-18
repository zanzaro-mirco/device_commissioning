#include "dc_crc.h"

/*
 * Versione bit per bit, senza tabella. Le trame sono di una ventina di byte e la
 * tabella costerebbe 512 byte di flash sulla centralina per risparmiare
 * microsecondi che nessuno misurerebbe.
 */
uint16_t dc_crc16(const uint8_t *data, size_t len) {
    uint16_t crc = 0xFFFF;
    for (size_t i = 0; i < len; i++) {
        crc ^= (uint16_t)((uint16_t)data[i] << 8);
        for (int bit = 0; bit < 8; bit++) {
            if (crc & 0x8000) {
                crc = (uint16_t)((crc << 1) ^ 0x1021);
            } else {
                crc = (uint16_t)(crc << 1);
            }
        }
    }
    return crc;
}
