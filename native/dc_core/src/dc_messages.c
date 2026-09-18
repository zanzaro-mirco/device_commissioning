#include "dc_messages.h"

static void put_u16(uint8_t *out, uint16_t value) {
    out[0] = (uint8_t)(value & 0xFF);
    out[1] = (uint8_t)(value >> 8);
}

static void put_u32(uint8_t *out, uint32_t value) {
    out[0] = (uint8_t)(value & 0xFF);
    out[1] = (uint8_t)((value >> 8) & 0xFF);
    out[2] = (uint8_t)((value >> 16) & 0xFF);
    out[3] = (uint8_t)(value >> 24);
}

static uint16_t get_u16(const uint8_t *in) {
    return (uint16_t)(in[0] | (in[1] << 8));
}

static uint32_t get_u32(const uint8_t *in) {
    return (uint32_t)in[0] | ((uint32_t)in[1] << 8) | ((uint32_t)in[2] << 16) |
           ((uint32_t)in[3] << 24);
}

size_t dc_encode_set_params(const dc_set_params *msg, uint8_t *out) {
    put_u32(&out[0], msg->expected_revision);
    put_u16(&out[4], (uint16_t)msg->params.setpoint);
    out[6] = msg->params.mode;
    return DC_SET_PARAMS_SIZE;
}

bool dc_decode_set_params(const uint8_t *in, size_t len, dc_set_params *msg) {
    if (len != DC_SET_PARAMS_SIZE) {
        return false;
    }
    msg->expected_revision = get_u32(&in[0]);
    msg->params.setpoint = (int16_t)get_u16(&in[4]);
    msg->params.mode = in[6];
    return true;
}

size_t dc_encode_state(const dc_state_msg *msg, uint8_t *out) {
    out[0] = msg->status;
    put_u32(&out[1], msg->revision);
    put_u16(&out[5], (uint16_t)msg->params.setpoint);
    out[7] = msg->params.mode;
    return DC_STATE_SIZE;
}

bool dc_decode_state(const uint8_t *in, size_t len, dc_state_msg *msg) {
    if (len != DC_STATE_SIZE) {
        return false;
    }
    msg->status = in[0];
    msg->revision = get_u32(&in[1]);
    msg->params.setpoint = (int16_t)get_u16(&in[5]);
    msg->params.mode = in[7];
    return true;
}

size_t dc_encode_set_result(const dc_set_result *msg, uint8_t *out) {
    out[0] = msg->status;
    put_u32(&out[1], msg->revision);
    return DC_SET_RESULT_SIZE;
}

bool dc_decode_set_result(const uint8_t *in, size_t len, dc_set_result *msg) {
    if (len != DC_SET_RESULT_SIZE) {
        return false;
    }
    msg->status = in[0];
    msg->revision = get_u32(&in[1]);
    return true;
}

size_t dc_encode_telemetry(const dc_telemetry *msg, uint8_t *out) {
    put_u16(&out[0], (uint16_t)msg->temperature);
    put_u32(&out[2], msg->uptime_s);
    return DC_TELEMETRY_SIZE;
}

bool dc_decode_telemetry(const uint8_t *in, size_t len, dc_telemetry *msg) {
    if (len != DC_TELEMETRY_SIZE) {
        return false;
    }
    msg->temperature = (int16_t)get_u16(&in[0]);
    msg->uptime_s = get_u32(&in[2]);
    return true;
}

size_t dc_encode_info(const dc_info *msg, uint8_t *out) {
    out[0] = msg->protocol_version;
    out[1] = msg->fw_major;
    out[2] = msg->fw_minor;
    out[3] = msg->fw_patch;
    return DC_INFO_SIZE;
}

bool dc_decode_info(const uint8_t *in, size_t len, dc_info *msg) {
    if (len != DC_INFO_SIZE) {
        return false;
    }
    msg->protocol_version = in[0];
    msg->fw_major = in[1];
    msg->fw_minor = in[2];
    msg->fw_patch = in[3];
    return true;
}

bool dc_params_in_range(const dc_params *params) {
    return params->setpoint >= DC_SETPOINT_MIN && params->setpoint <= DC_SETPOINT_MAX &&
           params->mode <= DC_MODE_ECO;
}

bool dc_params_equal(const dc_params *a, const dc_params *b) {
    return a->setpoint == b->setpoint && a->mode == b->mode;
}
