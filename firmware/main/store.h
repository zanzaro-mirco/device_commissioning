#ifndef STORE_H
#define STORE_H

#include <stdbool.h>

#include "dc_device.h"

/*
 * Lo stato della centralina su NVS. Una risposta OK vuol dire «è sulla flash»:
 * store_save deve essere tornato con successo prima che la risposta parta.
 */

/* Legge lo stato salvato. Se manca o non è valido, carica quello di fabbrica. */
void store_load(dc_device_state *state);

bool store_save(const dc_device_state *state);

#endif
