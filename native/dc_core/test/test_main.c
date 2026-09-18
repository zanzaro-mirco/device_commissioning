/*
 * Test di dc_core sul PC. Non contengono attese scritte a mano: eseguono i
 * vettori di protocol/vectors, gli stessi che esegue il pacchetto Dart. Il
 * percorso della cartella arriva come primo argomento.
 */

#include <stdio.h>
#include <string.h>

#include "dc_crc.h"
#include "dc_device.h"
#include "dc_frame.h"
#include "dc_messages.h"
#include "vec.h"

static int failures = 0;
static int checks = 0;
static const char *current_file = "";
static int current_line = 0;
static const char *current_case = "";

#define CHECK(condition, ...)                                                        \
    do {                                                                             \
        checks++;                                                                    \
        if (!(condition)) {                                                          \
            failures++;                                                              \
            printf("FALLITO %s:%d [%s] ", current_file, current_line, current_case); \
            printf(__VA_ARGS__);                                                     \
            printf("\n");                                                            \
        }                                                                            \
    } while (0)

static FILE *open_vectors(const char *dir, const char *name) {
    static char path[1024];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *file = fopen(path, "r");
    if (file == NULL) {
        printf("FALLITO: non riesco ad aprire %s\n", path);
        failures++;
    }
    current_file = name;
    return file;
}

static long long field(const vec_line *line, int first, int last, const char *key) {
    const char *value = vec_get(line, first, last, key);
    CHECK(value != NULL, "manca il campo %s", key);
    return value != NULL ? vec_number(value) : 0;
}

/* ---- CRC ---------------------------------------------------------------- */

static void test_crc(const char *dir) {
    FILE *file = open_vectors(dir, "crc.vec");
    if (file == NULL) return;
    vec_line line = {0};
    int cases = 0;
    while (vec_next(file, &line)) {
        current_line = line.line_number;
        current_case = vec_get(&line, 1, line.count, "input");
        uint8_t input[256];
        uint8_t expected[2];
        int len = vec_hex(vec_get(&line, 1, line.count, "input"), input, sizeof input);
        vec_hex(vec_get(&line, 1, line.count, "expected"), expected, sizeof expected);
        uint16_t want = (uint16_t)((expected[0] << 8) | expected[1]);
        uint16_t got = dc_crc16(input, (size_t)len);
        CHECK(got == want, "crc %04x, atteso %04x", got, want);
        cases++;
    }
    fclose(file);
    CHECK(cases >= 4, "letti solo %d vettori di CRC", cases);
}

/* ---- Trame -------------------------------------------------------------- */

static dc_frame_result result_named(const char *name) {
    if (strcmp(name, "ok") == 0) return DC_FRAME_OK;
    if (strcmp(name, "too_short") == 0) return DC_FRAME_TOO_SHORT;
    if (strcmp(name, "bad_length") == 0) return DC_FRAME_BAD_LENGTH;
    if (strcmp(name, "bad_crc") == 0) return DC_FRAME_BAD_CRC;
    if (strcmp(name, "unsupported_version") == 0) return DC_FRAME_UNSUPPORTED_VERSION;
    return (dc_frame_result)-1;
}

static void test_frames(const char *dir) {
    FILE *file = open_vectors(dir, "frames.vec");
    if (file == NULL) return;
    vec_line line = {0};
    while (vec_next(file, &line)) {
        current_line = line.line_number;
        current_case = vec_get(&line, 1, line.count, "name");
        uint8_t bytes[DC_FRAME_MAX_SIZE];
        int len = vec_hex(vec_get(&line, 1, line.count, "bytes"), bytes, sizeof bytes);
        dc_frame_result want = result_named(vec_get(&line, 1, line.count, "result"));

        dc_frame frame;
        dc_frame_result got = dc_frame_decode(bytes, (size_t)len, &frame);
        CHECK(got == want, "decodifica %d, atteso %d", got, want);
        if (want != DC_FRAME_OK || got != DC_FRAME_OK) continue;

        uint8_t type[1], seq[1], payload[DC_FRAME_MAX_PAYLOAD];
        vec_hex(vec_get(&line, 1, line.count, "type"), type, 1);
        vec_hex(vec_get(&line, 1, line.count, "seq"), seq, 1);
        int payload_len =
            vec_hex(vec_get(&line, 1, line.count, "payload"), payload, sizeof payload);
        CHECK(frame.type == type[0], "tipo %02x, atteso %02x", frame.type, type[0]);
        CHECK(frame.seq == seq[0], "sequenza %02x, attesa %02x", frame.seq, seq[0]);
        CHECK(frame.len == payload_len && memcmp(frame.payload, payload, frame.len) == 0,
              "contenuto diverso");

        // Andata e ritorno: codificare la trama letta deve ridare gli stessi byte.
        uint8_t encoded[DC_FRAME_MAX_SIZE];
        size_t encoded_len = 0;
        CHECK(dc_frame_encode(&frame, encoded, sizeof encoded, &encoded_len) == DC_FRAME_OK,
              "codifica fallita");
        CHECK(encoded_len == (size_t)len && memcmp(encoded, bytes, encoded_len) == 0,
              "la codifica non ridà gli stessi byte");
    }
    fclose(file);

    current_case = "buffer_too_small";
    dc_frame frame = {DC_MSG_GET_STATE, 1, 0, {0}};
    uint8_t small[DC_FRAME_OVERHEAD - 1];
    size_t written = 0;
    CHECK(dc_frame_encode(&frame, small, sizeof small, &written) == DC_FRAME_BUFFER_TOO_SMALL,
          "un buffer troppo piccolo va rifiutato");
}

/* ---- Messaggi ----------------------------------------------------------- */

static void test_messages(const char *dir) {
    FILE *file = open_vectors(dir, "messages.vec");
    if (file == NULL) return;
    vec_line line = {0};
    while (vec_next(file, &line)) {
        current_line = line.line_number;
        current_case = vec_get(&line, 1, line.count, "name");
        int n = line.count;
        uint8_t type[1];
        vec_hex(vec_get(&line, 1, n, "type"), type, 1);
        uint8_t want[DC_FRAME_MAX_PAYLOAD];
        int want_len = vec_hex(vec_get(&line, 1, n, "payload"), want, sizeof want);
        uint8_t got[DC_FRAME_MAX_PAYLOAD];
        size_t got_len = 0;

        switch (type[0]) {
        case DC_MSG_GET_STATE:
            CHECK(want_len == 0, "GET_STATE non ha contenuto");
            continue;
        case DC_MSG_SET_PARAMS:
        case DC_MSG_DEBUG_APPLY_THEN_REBOOT: {
            dc_set_params msg = {(uint32_t)field(&line, 1, n, "expected_revision"),
                                 {(int16_t)field(&line, 1, n, "setpoint"),
                                  (uint8_t)field(&line, 1, n, "mode")}};
            got_len = dc_encode_set_params(&msg, got);
            dc_set_params back;
            CHECK(dc_decode_set_params(want, (size_t)want_len, &back) &&
                      back.expected_revision == msg.expected_revision &&
                      dc_params_equal(&back.params, &msg.params),
                  "decodifica diversa");
            break;
        }
        case DC_MSG_STATE: {
            dc_state_msg msg = {(uint8_t)field(&line, 1, n, "status"),
                                (uint32_t)field(&line, 1, n, "revision"),
                                {(int16_t)field(&line, 1, n, "setpoint"),
                                 (uint8_t)field(&line, 1, n, "mode")}};
            got_len = dc_encode_state(&msg, got);
            dc_state_msg back;
            CHECK(dc_decode_state(want, (size_t)want_len, &back) && back.status == msg.status &&
                      back.revision == msg.revision && dc_params_equal(&back.params, &msg.params),
                  "decodifica diversa");
            break;
        }
        case DC_MSG_SET_RESULT: {
            dc_set_result msg = {(uint8_t)field(&line, 1, n, "status"),
                                 (uint32_t)field(&line, 1, n, "revision")};
            got_len = dc_encode_set_result(&msg, got);
            dc_set_result back;
            CHECK(dc_decode_set_result(want, (size_t)want_len, &back) &&
                      back.status == msg.status && back.revision == msg.revision,
                  "decodifica diversa");
            break;
        }
        case DC_MSG_TELEMETRY: {
            dc_telemetry msg = {(int16_t)field(&line, 1, n, "temperature"),
                                (uint32_t)field(&line, 1, n, "uptime_s")};
            got_len = dc_encode_telemetry(&msg, got);
            dc_telemetry back;
            CHECK(dc_decode_telemetry(want, (size_t)want_len, &back) &&
                      back.temperature == msg.temperature && back.uptime_s == msg.uptime_s,
                  "decodifica diversa");
            break;
        }
        case DC_MSG_INFO: {
            dc_info msg = {(uint8_t)field(&line, 1, n, "protocol_version"),
                           (uint8_t)field(&line, 1, n, "fw_major"),
                           (uint8_t)field(&line, 1, n, "fw_minor"),
                           (uint8_t)field(&line, 1, n, "fw_patch")};
            got_len = dc_encode_info(&msg, got);
            break;
        }
        case DC_MSG_ERROR:
            got[0] = (uint8_t)field(&line, 1, n, "status");
            got_len = 1;
            break;
        default:
            CHECK(0, "tipo %02x senza test", type[0]);
            continue;
        }
        CHECK(got_len == (size_t)want_len && memcmp(got, want, got_len) == 0,
              "codifica diversa dal vettore");
    }
    fclose(file);

    current_case = "wrong_length";
    uint8_t seven[DC_SET_PARAMS_SIZE + 1] = {0};
    dc_set_params ignored;
    CHECK(!dc_decode_set_params(seven, DC_SET_PARAMS_SIZE + 1, &ignored),
          "un contenuto più lungo va rifiutato");
    CHECK(!dc_decode_set_params(seven, DC_SET_PARAMS_SIZE - 1, &ignored),
          "un contenuto più corto va rifiutato");
}

/* ---- Scenari ------------------------------------------------------------ */

static int request_type_named(const char *name) {
    if (strcmp(name, "GET_STATE") == 0) return DC_MSG_GET_STATE;
    if (strcmp(name, "SET_PARAMS") == 0) return DC_MSG_SET_PARAMS;
    if (strcmp(name, "DEBUG_APPLY_THEN_REBOOT") == 0) return DC_MSG_DEBUG_APPLY_THEN_REBOOT;
    return -1;
}

static int response_type_named(const char *name) {
    if (strcmp(name, "STATE") == 0) return DC_MSG_STATE;
    if (strcmp(name, "SET_RESULT") == 0) return DC_MSG_SET_RESULT;
    if (strcmp(name, "ERROR") == 0) return DC_MSG_ERROR;
    return -1;
}

static int status_named(const char *name) {
    static const char *names[] = {"OK",       "ALREADY_APPLIED",     "CONFLICT",
                                  "OUT_OF_RANGE", "BAD_FRAME",       "UNSUPPORTED_VERSION",
                                  "UNKNOWN_TYPE", "BAD_PAYLOAD"};
    for (int i = 0; i < (int)(sizeof names / sizeof names[0]); i++) {
        if (strcmp(name, names[i]) == 0) return i;
    }
    return -1;
}

static bool same_state(const dc_device_state *a, const dc_device_state *b) {
    return a->revision == b->revision && dc_params_equal(&a->params, &b->params);
}

/* Esegue un passo con una richiesta e confronta la risposta con l'attesa. */
static void run_exchange(const vec_line *line, dc_device_state *state,
                         dc_device_state *persisted, const dc_device_config *config,
                         const uint8_t *request, size_t request_len) {
    int arrow = vec_arrow(line);
    const char *expected_name = arrow + 1 < line->count ? line->tokens[arrow + 1] : "";
    uint8_t expected_seq = request_len > 2 ? request[2] : 0;

    dc_device_state before = *state;
    uint8_t out[DC_FRAME_MAX_SIZE];
    size_t out_len = 0;
    dc_action action = dc_device_handle(state, config, request, request_len, out, &out_len);

    if (action == DC_ACTION_RESPOND) {
        CHECK(same_state(&before, state),
              "lo stato è cambiato ma la centralina non ha chiesto di salvarlo");
    } else {
        *persisted = *state;
    }

    if (strcmp(expected_name, "REBOOT") == 0) {
        CHECK(action == DC_ACTION_PERSIST_THEN_REBOOT, "attesi salvataggio e riavvio");
        CHECK(out_len == 0, "prima del riavvio non deve partire nessuna risposta");
        return;
    }
    CHECK(action != DC_ACTION_PERSIST_THEN_REBOOT, "riavvio non atteso");

    dc_frame response;
    CHECK(dc_frame_decode(out, out_len, &response) == DC_FRAME_OK,
          "la risposta non è una trama valida");
    CHECK(response.seq == expected_seq, "sequenza %d, attesa %d", response.seq, expected_seq);
    int want_type = response_type_named(expected_name);
    CHECK(response.type == want_type, "risposta %02x, attesa %s", response.type, expected_name);

    int first = arrow + 2;
    int last = line->count;
    const char *status = vec_get(line, first, last, "status");
    uint8_t got_status = response.len > 0 ? response.payload[0] : 0xFF;
    if (status != NULL) {
        CHECK(got_status == status_named(status), "stato %d, atteso %s", got_status, status);
    }
    if (response.type == DC_MSG_STATE) {
        dc_state_msg msg;
        CHECK(dc_decode_state(response.payload, response.len, &msg), "STATE illeggibile");
        CHECK(msg.revision == (uint32_t)field(line, first, last, "revision"),
              "revisione %u", (unsigned)msg.revision);
        CHECK(msg.params.setpoint == field(line, first, last, "setpoint"), "setpoint %d",
              msg.params.setpoint);
        CHECK(msg.params.mode == field(line, first, last, "mode"), "modo %d", msg.params.mode);
    } else if (response.type == DC_MSG_SET_RESULT) {
        dc_set_result msg;
        CHECK(dc_decode_set_result(response.payload, response.len, &msg),
              "SET_RESULT illeggibile");
        CHECK(msg.revision == (uint32_t)field(line, first, last, "revision"),
              "revisione %u", (unsigned)msg.revision);
    }
}

static void test_scenarios(const char *dir) {
    FILE *file = open_vectors(dir, "scenarios.vec");
    if (file == NULL) return;
    static char name[128];
    vec_line line = {0};
    dc_device_state state, persisted;
    dc_device_config config = {true};
    uint8_t seq = 0;
    int scenarios = 0;

    while (vec_next(file, &line)) {
        current_line = line.line_number;
        const char *step = line.tokens[0];
        int arrow = vec_arrow(&line);

        if (strcmp(step, "scenario") == 0) {
            snprintf(name, sizeof name, "%s", vec_get(&line, 1, line.count, "name"));
            current_case = name;
            scenarios++;
        } else if (strcmp(step, "factory") == 0) {
            dc_device_factory_state(&state);
            persisted = state;
            config.debug_commands = true;
        } else if (strcmp(step, "config") == 0) {
            config.debug_commands = strcmp(vec_get(&line, 1, line.count, "debug"), "on") == 0;
        } else if (strcmp(step, "reboot") == 0) {
            state = persisted;
        } else if (strcmp(step, "request") == 0) {
            int type = request_type_named(line.tokens[1]);
            CHECK(type >= 0, "richiesta sconosciuta %s", line.tokens[1]);
            dc_frame frame = {(uint8_t)type, ++seq, 0, {0}};
            if (type != DC_MSG_GET_STATE) {
                dc_set_params set = {(uint32_t)field(&line, 2, arrow, "expected_revision"),
                                     {(int16_t)field(&line, 2, arrow, "setpoint"),
                                      (uint8_t)field(&line, 2, arrow, "mode")}};
                frame.len = (uint8_t)dc_encode_set_params(&set, frame.payload);
            }
            uint8_t bytes[DC_FRAME_MAX_SIZE];
            size_t len = 0;
            dc_frame_encode(&frame, bytes, sizeof bytes, &len);
            run_exchange(&line, &state, &persisted, &config, bytes, len);
        } else if (strcmp(step, "send") == 0) {
            uint8_t type[1];
            vec_hex(vec_get(&line, 1, arrow, "type"), type, 1);
            dc_frame frame = {type[0], ++seq, 0, {0}};
            frame.len = (uint8_t)vec_hex(vec_get(&line, 1, arrow, "payload"), frame.payload,
                                         sizeof frame.payload);
            uint8_t bytes[DC_FRAME_MAX_SIZE];
            size_t len = 0;
            dc_frame_encode(&frame, bytes, sizeof bytes, &len);
            run_exchange(&line, &state, &persisted, &config, bytes, len);
        } else if (strcmp(step, "raw") == 0) {
            uint8_t bytes[DC_FRAME_MAX_SIZE];
            int len = vec_hex(vec_get(&line, 1, arrow, "bytes"), bytes, sizeof bytes);
            run_exchange(&line, &state, &persisted, &config, bytes, (size_t)len);
        } else if (strcmp(step, "end") == 0) {
            current_case = "";
        } else {
            CHECK(0, "passo sconosciuto %s", step);
        }
    }
    fclose(file);
    CHECK(scenarios >= 10, "letti solo %d scenari", scenarios);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        printf("uso: dc_core_tests <cartella dei vettori>\n");
        return 2;
    }
    test_crc(argv[1]);
    test_frames(argv[1]);
    test_messages(argv[1]);
    test_scenarios(argv[1]);
    printf("%d controlli, %d falliti\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
