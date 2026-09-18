#ifndef DC_CRC_H
#define DC_CRC_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * CRC-16/IBM-3740 (detto anche CCITT-FALSE): polinomio 0x1021, valore iniziale
 * 0xFFFF, nessuna riflessione, nessuno xor finale. Su "123456789" vale 0x29B1.
 */
uint16_t dc_crc16(const uint8_t *data, size_t len);

#ifdef __cplusplus
}
#endif

#endif
