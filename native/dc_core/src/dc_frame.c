#include "dc_frame.h"

#include <string.h>

#include "dc_crc.h"

dc_frame_result dc_frame_encode(const dc_frame *frame, uint8_t *out, size_t out_cap,
                                size_t *out_len) {
    if (frame->len > DC_FRAME_MAX_PAYLOAD) {
        return DC_FRAME_PAYLOAD_TOO_LONG;
    }
    size_t total = (size_t)DC_FRAME_OVERHEAD + frame->len;
    if (out_cap < total) {
        return DC_FRAME_BUFFER_TOO_SMALL;
    }
    out[0] = DC_PROTOCOL_VERSION;
    out[1] = frame->type;
    out[2] = frame->seq;
    out[3] = frame->len;
    memcpy(&out[DC_FRAME_HEADER_SIZE], frame->payload, frame->len);
    size_t body = (size_t)DC_FRAME_HEADER_SIZE + frame->len;
    uint16_t crc = dc_crc16(out, body);
    out[body] = (uint8_t)(crc & 0xFF);
    out[body + 1] = (uint8_t)(crc >> 8);
    *out_len = total;
    return DC_FRAME_OK;
}

dc_frame_result dc_frame_decode(const uint8_t *in, size_t in_len, dc_frame *frame) {
    if (in_len < DC_FRAME_OVERHEAD) {
        return DC_FRAME_TOO_SHORT;
    }
    uint8_t len = in[3];
    if (len > DC_FRAME_MAX_PAYLOAD || in_len != (size_t)DC_FRAME_OVERHEAD + len) {
        return DC_FRAME_BAD_LENGTH;
    }
    size_t body = (size_t)DC_FRAME_HEADER_SIZE + len;
    uint16_t expected = (uint16_t)(in[body] | (in[body + 1] << 8));
    if (dc_crc16(in, body) != expected) {
        return DC_FRAME_BAD_CRC;
    }
    // La versione si guarda solo dopo il CRC: un byte di versione rovinato dal
    // trasporto è un errore di trasporto, non un'app da aggiornare.
    if (in[0] != DC_PROTOCOL_VERSION) {
        return DC_FRAME_UNSUPPORTED_VERSION;
    }
    frame->type = in[1];
    frame->seq = in[2];
    frame->len = len;
    memcpy(frame->payload, &in[DC_FRAME_HEADER_SIZE], len);
    return DC_FRAME_OK;
}
