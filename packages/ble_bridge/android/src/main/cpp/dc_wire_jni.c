/*
 * Il ponte fra Kotlin e native/dc_core: lo stesso codice della trama che gira
 * sulla centralina. Due funzioni sole, e senza oggetti Java costruiti dal C:
 * la decodifica restituisce un array di byte che Kotlin legge, così l'unica
 * cosa che attraversa JNI sono array di byte e interi.
 */

#include <jni.h>
#include <string.h>

#include "dc_frame.h"

/* Restituisce la trama codificata, o NULL se il contenuto è troppo lungo. */
JNIEXPORT jbyteArray JNICALL
Java_it_mircozanzaro_ble_1bridge_DcWire_nativeEncode(JNIEnv *env, jclass clazz, jint type,
                                                     jint seq, jbyteArray payload) {
    (void)clazz;
    jsize len = (*env)->GetArrayLength(env, payload);
    if (len < 0 || len > DC_FRAME_MAX_PAYLOAD) {
        return NULL;
    }
    dc_frame frame;
    frame.type = (uint8_t)type;
    frame.seq = (uint8_t)seq;
    frame.len = (uint8_t)len;
    (*env)->GetByteArrayRegion(env, payload, 0, len, (jbyte *)frame.payload);

    uint8_t out[DC_FRAME_MAX_SIZE];
    size_t out_len = 0;
    if (dc_frame_encode(&frame, out, sizeof out, &out_len) != DC_FRAME_OK) {
        return NULL;
    }
    jbyteArray result = (*env)->NewByteArray(env, (jsize)out_len);
    (*env)->SetByteArrayRegion(env, result, 0, (jsize)out_len, (const jbyte *)out);
    return result;
}

/*
 * Restituisce [esito, tipo, sequenza, contenuto...]. L'esito è un
 * dc_frame_result: 0 vuol dire trama valida, e solo allora gli altri byte
 * hanno senso.
 */
JNIEXPORT jbyteArray JNICALL
Java_it_mircozanzaro_ble_1bridge_DcWire_nativeDecode(JNIEnv *env, jclass clazz,
                                                     jbyteArray bytes) {
    (void)clazz;
    jsize len = (*env)->GetArrayLength(env, bytes);
    uint8_t in[DC_FRAME_MAX_SIZE];
    dc_frame frame;
    dc_frame_result result;
    if (len > (jsize)sizeof in) {
        result = DC_FRAME_BAD_LENGTH;
    } else {
        (*env)->GetByteArrayRegion(env, bytes, 0, len, (jbyte *)in);
        result = dc_frame_decode(in, (size_t)len, &frame);
    }

    jsize out_len = result == DC_FRAME_OK ? 3 + frame.len : 1;
    uint8_t out[3 + DC_FRAME_MAX_PAYLOAD];
    out[0] = (uint8_t)result;
    if (result == DC_FRAME_OK) {
        out[1] = frame.type;
        out[2] = frame.seq;
        memcpy(&out[3], frame.payload, frame.len);
    }
    jbyteArray array = (*env)->NewByteArray(env, out_len);
    (*env)->SetByteArrayRegion(env, array, 0, out_len, (const jbyte *)out);
    return array;
}
