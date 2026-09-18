#ifndef VEC_H
#define VEC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

/*
 * Lettore dei file .vec di protocol/vectors: una riga è una parola iniziale
 * seguita da parole libere e coppie chiave=valore. Le righe vuote e quelle che
 * cominciano con # si saltano.
 */

#define VEC_MAX_TOKENS 32
#define VEC_MAX_LINE 512

typedef struct {
    char buffer[VEC_MAX_LINE];
    int count;
    char *tokens[VEC_MAX_TOKENS];
    int line_number;
} vec_line;

/* Legge la prossima riga utile. Restituisce false a fine file. */
bool vec_next(FILE *file, vec_line *line);

/* Il valore di chiave=valore fra i token da first a last esclusi, o NULL. */
const char *vec_get(const vec_line *line, int first, int last, const char *key);

/* L'indice del token "->", o count se manca. */
int vec_arrow(const vec_line *line);

/* Decodifica un esadecimale ("-" vale vuoto). Restituisce il numero di byte, o -1. */
int vec_hex(const char *text, uint8_t *out, size_t cap);

long long vec_number(const char *text);

#endif
