#include "dc_device.h"

#include "dc_frame.h"

void dc_device_factory_state(dc_device_state *state) {
    state->revision = 0;
    state->params.setpoint = 200;
    state->params.mode = DC_MODE_COMFORT;
}

dc_status dc_device_apply_set(dc_device_state *state, const dc_set_params *request) {
    if (request->expected_revision == state->revision) {
        if (!dc_params_in_range(&request->params)) {
            return DC_STATUS_OUT_OF_RANGE;
        }
        state->params = request->params;
        state->revision++;
        return DC_STATUS_OK;
    }
    // Un nuovo tentativo della modifica che ha prodotto la revisione corrente:
    // stessa revisione di partenza, stessi valori. Si conferma senza rifare niente.
    // Il confronto usa revision - 1 e non expected + 1, perché expected arriva
    // dal filo e può valere 0xFFFFFFFF.
    if (state->revision > 0 && request->expected_revision == state->revision - 1 &&
        dc_params_equal(&request->params, &state->params)) {
        return DC_STATUS_ALREADY_APPLIED;
    }
    return DC_STATUS_CONFLICT;
}

static size_t respond(uint8_t type, uint8_t seq, const uint8_t *payload, uint8_t len,
                      uint8_t *out) {
    dc_frame frame;
    frame.type = type;
    frame.seq = seq;
    frame.len = len;
    for (uint8_t i = 0; i < len; i++) {
        frame.payload[i] = payload[i];
    }
    size_t written = 0;
    // Le risposte sono tutte più corte di DC_FRAME_MAX_SIZE: la codifica non può
    // fallire, e se fallisse la risposta vuota farebbe scadere l'attesa dell'app.
    dc_frame_encode(&frame, out, DC_FRAME_MAX_SIZE, &written);
    return written;
}

static size_t respond_error(uint8_t seq, dc_status status, uint8_t *out) {
    uint8_t payload[DC_ERROR_SIZE] = {(uint8_t)status};
    return respond(DC_MSG_ERROR, seq, payload, DC_ERROR_SIZE, out);
}

dc_action dc_device_handle(dc_device_state *state, const dc_device_config *config,
                           const uint8_t *in, size_t in_len, uint8_t *out,
                           size_t *out_len) {
    dc_frame request;
    dc_frame_result decoded = dc_frame_decode(in, in_len, &request);
    if (decoded != DC_FRAME_OK) {
        // La sequenza di una trama rovinata può essere rovinata anche lei: la si
        // ripete lo stesso, perché è l'unico modo che l'app ha per capire a quale
        // richiesta si riferisce l'errore. Se non corrisponde, all'app scade l'attesa.
        uint8_t seq = in_len > 2 ? in[2] : 0;
        dc_status status = decoded == DC_FRAME_UNSUPPORTED_VERSION
                               ? DC_STATUS_UNSUPPORTED_VERSION
                               : DC_STATUS_BAD_FRAME;
        *out_len = respond_error(seq, status, out);
        return DC_ACTION_RESPOND;
    }

    switch (request.type) {
    case DC_MSG_GET_STATE: {
        if (request.len != 0) {
            *out_len = respond_error(request.seq, DC_STATUS_BAD_PAYLOAD, out);
            return DC_ACTION_RESPOND;
        }
        dc_state_msg state_msg = {DC_STATUS_OK, state->revision, state->params};
        uint8_t payload[DC_STATE_SIZE];
        dc_encode_state(&state_msg, payload);
        *out_len = respond(DC_MSG_STATE, request.seq, payload, DC_STATE_SIZE, out);
        return DC_ACTION_RESPOND;
    }
    case DC_MSG_SET_PARAMS:
    case DC_MSG_DEBUG_APPLY_THEN_REBOOT: {
        bool debug = request.type == DC_MSG_DEBUG_APPLY_THEN_REBOOT;
        if (debug && !config->debug_commands) {
            *out_len = respond_error(request.seq, DC_STATUS_UNKNOWN_TYPE, out);
            return DC_ACTION_RESPOND;
        }
        dc_set_params set;
        if (!dc_decode_set_params(request.payload, request.len, &set)) {
            *out_len = respond_error(request.seq, DC_STATUS_BAD_PAYLOAD, out);
            return DC_ACTION_RESPOND;
        }
        dc_status status = dc_device_apply_set(state, &set);
        if (debug && status == DC_STATUS_OK) {
            *out_len = 0;
            return DC_ACTION_PERSIST_THEN_REBOOT;
        }
        dc_set_result result = {(uint8_t)status, state->revision};
        uint8_t payload[DC_SET_RESULT_SIZE];
        dc_encode_set_result(&result, payload);
        *out_len = respond(DC_MSG_SET_RESULT, request.seq, payload, DC_SET_RESULT_SIZE, out);
        return status == DC_STATUS_OK ? DC_ACTION_PERSIST_THEN_RESPOND : DC_ACTION_RESPOND;
    }
    default:
        *out_len = respond_error(request.seq, DC_STATUS_UNKNOWN_TYPE, out);
        return DC_ACTION_RESPOND;
    }
}
