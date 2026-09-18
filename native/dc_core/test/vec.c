#include "vec.h"

#include <stdlib.h>
#include <string.h>

bool vec_next(FILE *file, vec_line *line) {
    while (fgets(line->buffer, sizeof line->buffer, file) != NULL) {
        line->line_number++;
        line->count = 0;
        char *cursor = line->buffer;
        while (*cursor != '\0' && line->count < VEC_MAX_TOKENS) {
            while (*cursor == ' ' || *cursor == '\t' || *cursor == '\r' || *cursor == '\n') {
                *cursor++ = '\0';
            }
            if (*cursor == '\0') {
                break;
            }
            line->tokens[line->count++] = cursor;
            while (*cursor != '\0' && *cursor != ' ' && *cursor != '\t' && *cursor != '\r' &&
                   *cursor != '\n') {
                cursor++;
            }
        }
        if (line->count > 0 && line->tokens[0][0] != '#') {
            return true;
        }
    }
    return false;
}

const char *vec_get(const vec_line *line, int first, int last, const char *key) {
    size_t key_len = strlen(key);
    for (int i = first; i < last && i < line->count; i++) {
        const char *token = line->tokens[i];
        if (strncmp(token, key, key_len) == 0 && token[key_len] == '=') {
            return token + key_len + 1;
        }
    }
    return NULL;
}

int vec_arrow(const vec_line *line) {
    for (int i = 0; i < line->count; i++) {
        if (strcmp(line->tokens[i], "->") == 0) {
            return i;
        }
    }
    return line->count;
}

static int hex_digit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

int vec_hex(const char *text, uint8_t *out, size_t cap) {
    if (strcmp(text, "-") == 0) {
        return 0;
    }
    size_t len = strlen(text);
    if (len % 2 != 0 || len / 2 > cap) {
        return -1;
    }
    for (size_t i = 0; i < len / 2; i++) {
        int high = hex_digit(text[2 * i]);
        int low = hex_digit(text[2 * i + 1]);
        if (high < 0 || low < 0) {
            return -1;
        }
        out[i] = (uint8_t)(high * 16 + low);
    }
    return (int)(len / 2);
}

long long vec_number(const char *text) {
    return strtoll(text, NULL, 10);
}
