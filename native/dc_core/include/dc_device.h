#ifndef DC_DEVICE_H
#define DC_DEVICE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "dc_messages.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * La logica della centralina, senza Bluetooth e senza flash: riceve i byte di una
 * richiesta e produce i byte della risposta, più un'indicazione su cosa fare
 * prima di mandarla. Il firmware ci mette intorno NimBLE e NVS; i test la
 * eseguono sul PC con gli scenari di protocol/vectors/scenarios.vec.
 */

/*
 * Lo stato che sopravvive a un riavvio. Non serve ricordare l'ultima richiesta
 * applicata: l'ultima modifica è per costruzione quella che ha portato la
 * revisione da revision - 1 a revision, e i suoi valori sono i parametri
 * correnti.
 */
typedef struct {
    uint32_t revision;
    dc_params params;
} dc_device_state;

typedef struct {
    /* Solo il firmware di debug accetta DEBUG_APPLY_THEN_REBOOT. */
    bool debug_commands;
} dc_device_config;

typedef enum {
    /* Manda la risposta. */
    DC_ACTION_RESPOND,
    /* Salva lo stato, e solo dopo manda la risposta. */
    DC_ACTION_PERSIST_THEN_RESPOND,
    /* Salva lo stato e riavvia senza rispondere (solo per provare l'esito incerto). */
    DC_ACTION_PERSIST_THEN_REBOOT,
} dc_action;

void dc_device_factory_state(dc_device_state *state);

/*
 * Gestisce una trama di richiesta. Scrive in out la trama di risposta (out_len è 0
 * se non c'è risposta) e aggiorna state se la richiesta lo modifica. out deve
 * avere spazio per DC_FRAME_MAX_SIZE byte.
 */
dc_action dc_device_handle(dc_device_state *state, const dc_device_config *config,
                           const uint8_t *in, size_t in_len, uint8_t *out,
                           size_t *out_len);

/* La scrittura condizionata, esposta da sola perché è il cuore del protocollo. */
dc_status dc_device_apply_set(dc_device_state *state, const dc_set_params *request);

#ifdef __cplusplus
}
#endif

#endif
