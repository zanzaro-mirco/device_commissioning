#ifndef DC_MESSAGES_H
#define DC_MESSAGES_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    DC_MSG_GET_STATE = 0x01,
    DC_MSG_SET_PARAMS = 0x02,
    DC_MSG_DEBUG_APPLY_THEN_REBOOT = 0x7F,
    DC_MSG_TELEMETRY = 0x40,
    DC_MSG_INFO = 0x41,
    DC_MSG_STATE = 0x81,
    DC_MSG_SET_RESULT = 0x82,
    DC_MSG_ERROR = 0xFF,
} dc_msg_type;

typedef enum {
    DC_STATUS_OK = 0,
    DC_STATUS_ALREADY_APPLIED = 1,
    DC_STATUS_CONFLICT = 2,
    DC_STATUS_OUT_OF_RANGE = 3,
    DC_STATUS_BAD_FRAME = 4,
    DC_STATUS_UNSUPPORTED_VERSION = 5,
    DC_STATUS_UNKNOWN_TYPE = 6,
    DC_STATUS_BAD_PAYLOAD = 7,
} dc_status;

typedef enum {
    DC_MODE_OFF = 0,
    DC_MODE_COMFORT = 1,
    DC_MODE_ECO = 2,
} dc_mode;

#define DC_SETPOINT_MIN 50  /* 5,0 °C */
#define DC_SETPOINT_MAX 300 /* 30,0 °C */

/* Temperature in decimi di grado: 215 vale 21,5 °C. */
typedef struct {
    int16_t setpoint;
    uint8_t mode;
} dc_params;

typedef struct {
    uint32_t expected_revision;
    dc_params params;
} dc_set_params;

typedef struct {
    uint8_t status;
    uint32_t revision;
    dc_params params;
} dc_state_msg;

typedef struct {
    uint8_t status;
    uint32_t revision;
} dc_set_result;

typedef struct {
    int16_t temperature;
    uint32_t uptime_s;
} dc_telemetry;

typedef struct {
    uint8_t protocol_version;
    uint8_t fw_major;
    uint8_t fw_minor;
    uint8_t fw_patch;
} dc_info;

#define DC_SET_PARAMS_SIZE 7
#define DC_STATE_SIZE 8
#define DC_SET_RESULT_SIZE 5
#define DC_TELEMETRY_SIZE 6
#define DC_INFO_SIZE 4
#define DC_ERROR_SIZE 1

/*
 * Ogni encode scrive esattamente la dimensione del messaggio e la restituisce.
 * Ogni decode vuole esattamente quella dimensione: un contenuto più lungo o più
 * corto non è «quasi giusto», è un errore del mittente.
 */
size_t dc_encode_set_params(const dc_set_params *msg, uint8_t *out);
bool dc_decode_set_params(const uint8_t *in, size_t len, dc_set_params *msg);

size_t dc_encode_state(const dc_state_msg *msg, uint8_t *out);
bool dc_decode_state(const uint8_t *in, size_t len, dc_state_msg *msg);

size_t dc_encode_set_result(const dc_set_result *msg, uint8_t *out);
bool dc_decode_set_result(const uint8_t *in, size_t len, dc_set_result *msg);

size_t dc_encode_telemetry(const dc_telemetry *msg, uint8_t *out);
bool dc_decode_telemetry(const uint8_t *in, size_t len, dc_telemetry *msg);

size_t dc_encode_info(const dc_info *msg, uint8_t *out);
bool dc_decode_info(const uint8_t *in, size_t len, dc_info *msg);

bool dc_params_in_range(const dc_params *params);
bool dc_params_equal(const dc_params *a, const dc_params *b);

#ifdef __cplusplus
}
#endif

#endif
