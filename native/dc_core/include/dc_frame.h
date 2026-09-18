#ifndef DC_FRAME_H
#define DC_FRAME_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DC_PROTOCOL_VERSION 1
#define DC_FRAME_HEADER_SIZE 4
#define DC_FRAME_CRC_SIZE 2
#define DC_FRAME_OVERHEAD (DC_FRAME_HEADER_SIZE + DC_FRAME_CRC_SIZE)
#define DC_FRAME_MAX_PAYLOAD 200
#define DC_FRAME_MAX_SIZE (DC_FRAME_OVERHEAD + DC_FRAME_MAX_PAYLOAD)

typedef struct {
    uint8_t type;
    uint8_t seq;
    uint8_t len;
    uint8_t payload[DC_FRAME_MAX_PAYLOAD];
} dc_frame;

typedef enum {
    DC_FRAME_OK = 0,
    DC_FRAME_TOO_SHORT,
    DC_FRAME_BAD_LENGTH,
    DC_FRAME_BAD_CRC,
    DC_FRAME_UNSUPPORTED_VERSION,
    DC_FRAME_PAYLOAD_TOO_LONG,
    DC_FRAME_BUFFER_TOO_SMALL,
} dc_frame_result;

/* Scrive la trama in out. Su successo, out_len contiene i byte scritti. */
dc_frame_result dc_frame_encode(const dc_frame *frame, uint8_t *out, size_t out_cap,
                                size_t *out_len);

/*
 * Legge una trama. L'ordine dei controlli è parte del contratto (vedi
 * protocol/PROTOCOL.md): lunghezza, poi CRC, poi versione.
 */
dc_frame_result dc_frame_decode(const uint8_t *in, size_t in_len, dc_frame *frame);

#ifdef __cplusplus
}
#endif

#endif
